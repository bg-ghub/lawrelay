[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string]$ProductionEnvPath,

  [string]$Server = '178.105.52.108',

  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string]$SshKeyPath = 'C:\Users\Nobody\.ssh\id_ed25519_lawrelay',

  # By default the two analytics env files sit beside production.env, but they
  # remain separate so application deploys never load their credentials.
  [string]$AnalyticsEnvDirectory,

  [string]$RemotePath = '/home/deploy/lawrelay',

  [switch]$SkipLocalPreflight
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
  param([Parameter(Mandatory = $true)][scriptblock]$Command, [Parameter(Mandatory = $true)][string]$FailureMessage)
  & $Command
  if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Get-EnvNames {
  param([Parameter(Mandatory = $true)][string]$Path)
  $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*([A-Z][A-Z0-9_]*)=(.*)$') {
      $names.Add($Matches[1]) | Out-Null
      $values[$Matches[1]] = $Matches[2]
    }
  }
  return @{ Names = $names; Values = $values }
}

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$composePath = Join-Path $workspace 'compose.production.yml'
$caddyPath = Join-Path $workspace 'config/Caddyfile'
$versionPath = Join-Path $workspace 'VERSION'

foreach ($path in @($composePath, $caddyPath, $versionPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required deployment file is missing: $path" }
}

$requiredEnv = @(
  'APP_HOST', 'ADMIN_HOST', 'APP_PROTOCOL', 'ADDITIONAL_HOSTS', 'RAILS_ENV', 'RAILS_MASTER_KEY', 'SECRET_KEY_BASE',
  'SMTP_ADDRESS', 'SMTP_PORT', 'SMTP_DOMAIN', 'SMTP_USERNAME', 'SMTP_PASSWORD', 'SMTP_AUTHENTICATION',
  'SMTP_SSL', 'SMTP_STARTTLS', 'MAIL_FROM', 'SOLID_QUEUE_IN_PUMA', 'ACTIVE_STORAGE_SERVICE',
  'ASSUME_SSL', 'FORCE_SSL', 'LAWRELAY_BILLING_ENFORCED', 'LAWRELAY_RELEASE_MODE'
)
$resolvedProductionEnvPath = (Resolve-Path -LiteralPath $ProductionEnvPath).Path
$environment = Get-EnvNames -Path $resolvedProductionEnvPath
$missing = @($requiredEnv | Where-Object { -not $environment.Names.Contains($_) -or [string]::IsNullOrWhiteSpace($environment.Values[$_]) })
if ($missing.Count -gt 0) { throw "Production environment is incomplete: $($missing -join ', '). Values were not displayed." }

if ($environment.Values['APP_HOST'] -ne 'lawrelay.be' -or $environment.Values['ADMIN_HOST'] -ne 'admin.lawrelay.be' -or $environment.Values['LAWRELAY_RELEASE_MODE'] -ne 'beta' -or $environment.Values['LAWRELAY_BILLING_ENFORCED'] -ne 'true') {
  throw 'Production environment must target lawrelay.be and enforce the free founding beta release mode.'
}

if ([string]::IsNullOrWhiteSpace($AnalyticsEnvDirectory)) {
  $AnalyticsEnvDirectory = Split-Path -Parent $resolvedProductionEnvPath
}
if (-not (Test-Path -LiteralPath $AnalyticsEnvDirectory -PathType Container)) {
  throw 'Analytics environment directory does not exist.'
}
$resolvedAnalyticsEnvDirectory = (Resolve-Path -LiteralPath $AnalyticsEnvDirectory).Path
$umamiEnvPath = Join-Path $resolvedAnalyticsEnvDirectory 'umami.env'
$umamiDbEnvPath = Join-Path $resolvedAnalyticsEnvDirectory 'umami-db.env'
foreach ($analyticsEnvPath in @($umamiEnvPath, $umamiDbEnvPath)) {
  if (-not (Test-Path -LiteralPath $analyticsEnvPath -PathType Leaf)) {
    throw "Required analytics environment file is missing: $analyticsEnvPath"
  }
}

function Assert-CompleteEnvironment {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$RequiredNames,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $parsed = Get-EnvNames -Path $Path
  $missingNames = @($RequiredNames | Where-Object {
    -not $parsed.Names.Contains($_) -or [string]::IsNullOrWhiteSpace($parsed.Values[$_])
  })
  if ($missingNames.Count -gt 0) {
    throw "$Label is incomplete: $($missingNames -join ', '). Values were not displayed."
  }
}

Assert-CompleteEnvironment -Path $umamiEnvPath -RequiredNames @('DATABASE_URL', 'APP_SECRET', 'TWO_FACTOR_ENCRYPTION_KEY', 'DISABLE_TELEMETRY') -Label 'Umami environment'
Assert-CompleteEnvironment -Path $umamiDbEnvPath -RequiredNames @('POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD') -Label 'Umami database environment'

Push-Location $workspace
try {
  Invoke-Checked { git diff --quiet } 'Refusing to deploy with unstaged changes. Commit or stash the intended release first.'
  Invoke-Checked { git diff --cached --quiet } 'Refusing to deploy with staged but uncommitted changes.'
  $untrackedFiles = & git ls-files --others --exclude-standard
  if ($untrackedFiles) { throw 'Refusing to deploy with untracked source files. Commit the intended release first.' }
  Invoke-Checked { git rev-parse --verify HEAD } 'A committed Git revision is required for an immutable image tag.'
  Invoke-Checked { docker version --format '{{.Server.Version}}' } 'Docker must be available locally.'

  $version = (Get-Content -Raw -LiteralPath $versionPath).Trim()
  if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw "VERSION is not valid SemVer: $version" }
  $revision = (& git rev-parse --short=12 HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the release revision.' }
  $image = "lawrelay:$version-$revision"

  Write-Host "Building immutable image $image..."
  Invoke-Checked { docker build --tag $image . } 'Docker image build failed.'

  if (-not $SkipLocalPreflight) {
    Write-Host 'Running release preflight in the candidate image...'
    Invoke-Checked { docker run --rm --env-file $ProductionEnvPath $image bundle exec rails release:preflight } 'Candidate image did not pass the release preflight.'
  }

  $archiveDirectory = Join-Path $workspace 'tmp/deploy'
  New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
  $archivePath = Join-Path $archiveDirectory ("$($image.Replace(':', '-')).tar")
  Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
  try {
    Write-Host 'Saving image archive for the private server transfer...'
    Invoke-Checked { docker save --output $archivePath $image } 'Could not save the candidate image.'

    $sshArguments = @('-F', 'NUL', '-i', $SshKeyPath, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new')
    $remote = "deploy@$Server"
    Invoke-Checked { & ssh @sshArguments $remote "mkdir -p $RemotePath && chmod 700 $RemotePath && docker compose version >/dev/null" } 'Remote preflight failed. Confirm Docker Compose v2 is installed for deploy.'
    Invoke-Checked { & scp @sshArguments $composePath $caddyPath $archivePath "${remote}:$RemotePath/" } 'Secure copy of deployment assets to the server failed.'
    Invoke-Checked { & scp @sshArguments $resolvedProductionEnvPath "${remote}:$RemotePath/production.env" } 'Secure copy of the production environment failed.'
    Invoke-Checked { & scp @sshArguments $umamiEnvPath $umamiDbEnvPath "${remote}:$RemotePath/" } 'Secure copy of the analytics environment failed.'

    $remoteArchive = "$RemotePath/$([IO.Path]::GetFileName($archivePath))"
    $remoteCommand = @"
set -eu
cd $RemotePath
chmod 600 production.env umami.env umami-db.env
printf '%s\n' 'LAWRELAY_IMAGE=$image' > release.env
docker volume inspect lawrelay_storage >/dev/null 2>&1 || docker volume create lawrelay_storage >/dev/null
docker volume inspect lawrelay_umami_db >/dev/null 2>&1 || docker volume create lawrelay_umami_db >/dev/null
docker load --input '$remoteArchive' >/dev/null
docker compose --env-file release.env -f compose.production.yml up --detach --remove-orphans
for container in lawrelay-umami-db lawrelay-umami lawrelay-app; do
  status=starting
  for attempt in `$(seq 1 24); do
    status=`$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "`$container" 2>/dev/null || true)
    [ "`$status" = healthy ] && break
    sleep 5
  done
  [ "`$status" = healthy ]
done
docker compose --env-file release.env -f compose.production.yml exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
rm -f '$remoteArchive'
"@
    $encodedRemoteCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteCommand))
    Write-Host "Deploying $image to $Server..."
    Invoke-Checked { & ssh @sshArguments $remote "echo $encodedRemoteCommand | base64 -d | sh" } 'Remote deploy or application health check failed. The image archive was retained on the host for investigation.'
    Write-Host "Deployment completed: $image"
  } finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
  }
} finally {
  Pop-Location
}
