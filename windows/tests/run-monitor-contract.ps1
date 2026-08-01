#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ScriptMarketRoot,

    [string] $NodePath = 'node'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Contract = Join-Path (Join-Path $RepositoryRoot 'tests') `
    'script-runtime/script-runtime-contract.mjs'
$ResolvedMarket = if ([IO.Path]::IsPathRooted($ScriptMarketRoot)) {
    [IO.Path]::GetFullPath($ScriptMarketRoot)
} else {
    [IO.Path]::GetFullPath(
        (Join-Path (Get-Location).Path $ScriptMarketRoot))
}

if (-not (Test-Path -LiteralPath $ResolvedMarket -PathType Container)) {
    throw "run-monitor-contract: script market does not exist: $ResolvedMarket"
}
if (-not (Test-Path -LiteralPath $Contract -PathType Leaf)) {
    throw "run-monitor-contract: shared contract does not exist: $Contract"
}

& $NodePath $Contract '--script-market-root' $ResolvedMarket
if ($LASTEXITCODE -ne 0) {
    throw "run-monitor-contract: node contract failed with exit code $LASTEXITCODE"
}
