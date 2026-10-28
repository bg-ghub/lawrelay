param([switch]$BackupOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$secretDirectory = Join-Path $env:LOCALAPPDATA 'LawRelay'
$statePath = Join-Path $secretDirectory 'production-secrets.dpapi'
$outputDirectory = Join-Path $workspace 'tmp/production-secrets'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($directory in @($secretDirectory, $outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  & icacls $directory /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' | Out-Null
}

function New-RandomSecret {
  [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(64))
}

if (Test-Path -LiteralPath $statePath) {
  $encrypted = Get-Content -Raw -LiteralPath $statePath | ConvertTo-SecureString
  $state = ([System.Net.NetworkCredential]::new('', $encrypted).Password | ConvertFrom-Json -AsHashtable)
} else {
  $keyResult = & aws iam create-access-key --profile payer --user-name lawrelay-backup-prod --output json
  if ($LASTEXITCODE -ne 0) { throw 'Could not create the dedicated backup credential.' }
  $accessKey = ($keyResult | ConvertFrom-Json).AccessKey
  $state = @{
    AWS_ACCESS_KEY_ID = $accessKey.AccessKeyId
    AWS_SECRET_ACCESS_KEY = $accessKey.SecretAccessKey
    RESTIC_PASSWORD = New-RandomSecret
    SECRET_KEY_BASE = New-RandomSecret
  }
  $protected = ConvertTo-SecureString ($state | ConvertTo-Json -Compress) -AsPlainText -Force | ConvertFrom-SecureString
  [IO.File]::WriteAllText($statePath, $protected, [Text.UTF8Encoding]::new($false))
  & icacls $statePath /inheritance:r /grant:r "${identity}:(F)" 'SYSTEM:(F)' | Out-Null
}

$backupLines = @(
  'RESTIC_REPOSITORY=s3:s3.eu-central-1.amazonaws.com/lawrelay-prod-backups-233427601863',
  'RESTIC_PASSWORD_FILE=/etc/lawrelay/restic-password',
  'AWS_DEFAULT_REGION=eu-central-1',
  "AWS_ACCESS_KEY_ID=$($state.AWS_ACCESS_KEY_ID)",
  "AWS_SECRET_ACCESS_KEY=$($state.AWS_SECRET_ACCESS_KEY)",
  'LAWRELAY_BASE_URL=https://lawrelay.be',
  'LAWRELAY_DOCKER_CONTAINER=lawrelay-app'
)
[IO.File]::WriteAllText((Join-Path $outputDirectory 'backup.env'), ($backupLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $outputDirectory 'restic-password'), $state.RESTIC_PASSWORD + "`n", [Text.UTF8Encoding]::new($false))

if (-not $BackupOnly) {
  $localConfig = @{}
  foreach ($line in (Get-Content -LiteralPath (Join-Path $workspace '.env.production.local'))) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $localConfig[$Matches[1]] = $Matches[2] }
  }
  if ([string]::IsNullOrWhiteSpace($localConfig['SMTP_PASSWORD'])) {
    throw 'Fill SMTP_PASSWORD in the ignored .env.production.local file before deployment. Backup recovery credentials are saved securely.'
  }
  $appLines = @(
    'RAILS_ENV=production', 'APP_HOST=lawrelay.be', 'APP_PROTOCOL=https', 'ADDITIONAL_HOSTS=www.lawrelay.be',
    'ASSUME_SSL=true', 'FORCE_SSL=true', 'ACTIVE_STORAGE_SERVICE=local',
    'SOLID_QUEUE_IN_PUMA=true', 'LAWRELAY_BILLING_ENFORCED=true', 'LAWRELAY_RELEASE_MODE=beta',
    'SMTP_ADDRESS=smtp.migadu.com', 'SMTP_PORT=587', 'SMTP_DOMAIN=lawrelay.be',
    'SMTP_AUTHENTICATION=plain', 'SMTP_SSL=false', 'SMTP_STARTTLS=true',
    "SMTP_USERNAME=$($localConfig['SMTP_USERNAME'])", "SMTP_PASSWORD=$($localConfig['SMTP_PASSWORD'])",
    'MAIL_FROM=LawRelay <no-reply@lawrelay.be>',
    "SECRET_KEY_BASE=$($state.SECRET_KEY_BASE)",
    "RAILS_MASTER_KEY=$((Get-Content -Raw -LiteralPath (Join-Path $workspace 'config/master.key')).Trim())"
  )
  [IO.File]::WriteAllText((Join-Path $outputDirectory 'production.env'), ($appLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
Write-Output "Prepared private deployment files in $outputDirectory. Recovery state is protected with Windows DPAPI in $statePath. No secret values were printed."
