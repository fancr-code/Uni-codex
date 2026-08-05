[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $CodexPlusPlusSetup,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [Parameter(Mandatory)] [string] $IsccPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:UNICODEX_VERSION = $Version.TrimStart('v')
$env:UNICODEX_OUTPUT = [IO.Path]::GetFullPath($OutputDirectory)
$env:UNICODEX_CODEX_PLUS_SETUP = [IO.Path]::GetFullPath($CodexPlusPlusSetup)
New-Item -ItemType Directory -Path $env:UNICODEX_OUTPUT -Force | Out-Null
& $IsccPath (Join-Path $root 'UniCodexOnline.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
$artifact = Join-Path $env:UNICODEX_OUTPUT 'Uni-codex-Windows-x64-Online-Setup.exe'
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw 'Windows artifact was not created' }
Get-FileHash -LiteralPath $artifact -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($artifact))" } |
    Set-Content -LiteralPath (Join-Path $env:UNICODEX_OUTPUT 'SHA256SUMS-Windows.txt') -Encoding ascii

