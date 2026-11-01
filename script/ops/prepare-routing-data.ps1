param(
  [Parameter(Mandatory = $true)][string]$PbfPath,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$PythonPath
)

# Run on the build workstation, not the production host. PythonPath must point
# to a virtual environment containing the pinned osmium==4.3.2 package.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$image = 'ghcr.io/project-osrm/osrm-backend@sha256:e1929ae2818226284d7ef007329098a30851c11528ab3712bc9c8d68da78278b'
$workspaceCandidate = if ($PSScriptRoot) { Join-Path $PSScriptRoot '../..' } else { (Get-Location).Path }
$workspace = (Resolve-Path $workspaceCandidate).Path
$opsDirectory = Join-Path $workspace 'script/ops'
if (-not (Test-Path -LiteralPath (Join-Path $workspace 'config/courts.be.json') -PathType Leaf)) {
  throw 'Run from the LawRelay checkout or invoke the script by its file path.'
}
$source = (Resolve-Path -LiteralPath $PbfPath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$destination = (Resolve-Path -LiteralPath $OutputDirectory).Path
if (Get-ChildItem -LiteralPath $destination -Force | Select-Object -First 1) {
  throw 'Output directory must be empty; existing routing data will not be overwritten.'
}
Copy-Item -LiteralPath $source -Destination (Join-Path $destination 'belgium-latest.osm.pbf')

foreach ($command in @(
  @('osrm-extract', '--threads', '4', '-p', '/opt/car.lua', '/data/belgium-latest.osm.pbf'),
  @('osrm-partition', '--threads', '4', '/data/belgium-latest.osrm'),
  @('osrm-customize', '--threads', '4', '/data/belgium-latest.osrm')
)) {
  & docker run --rm --network none --memory=12g --cpus=4 --mount "type=bind,source=$destination,target=/data" $image @command
  if ($LASTEXITCODE -ne 0) { throw "Routing preparation failed: $($command[0]). Partial files were retained for diagnosis." }
}
& $PythonPath (Join-Path $opsDirectory 'build-osm-address-index.py') (Join-Path $destination 'belgium-latest.osm.pbf') (Join-Path $destination 'addresses.sqlite3') --places (Join-Path $workspace 'config/courts.be.json')
if ($LASTEXITCODE -ne 0) { throw 'Local address-index preparation failed.' }

Get-ChildItem -LiteralPath $destination -File | ForEach-Object { Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName } |
  Select-Object Hash,Path | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'checksums.json') -Encoding utf8
Write-Host 'Routing data prepared. Measure the bounded runtime and court/address coverage before deploying it.'
