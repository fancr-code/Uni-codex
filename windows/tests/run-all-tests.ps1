#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PayloadRoot,
    [Parameter(Mandatory)] [string] $BuiltRoot,
    [Parameter(Mandatory)] [string] $TestResultsRoot,
    [string] $NodePath = 'node'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$Solution = Join-Path $WindowsRoot 'CodexOneClickInstaller.sln'
$Results = [IO.Path]::GetFullPath($TestResultsRoot)

function Invoke-Checked([string] $Description, [scriptblock] $Operation) {
    $global:LASTEXITCODE = 0
    & $Operation
    if (-not $? -or $LASTEXITCODE -ne 0) {
        throw "run-all-tests: $Description failed with exit code $LASTEXITCODE"
    }
}

New-Item -ItemType Directory -Path $Results -Force | Out-Null
foreach ($script in @(
    Get-ChildItem -LiteralPath (Join-Path $WindowsRoot 'scripts') -Filter '*.ps1' -File
) + @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File
)) {
    $tokens = $null
    $errors = $null
    [void] [Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref] $tokens,
        [ref] $errors)
    if ($errors.Count -ne 0) {
        throw "run-all-tests: PowerShell 5.1 syntax failed for $($script.FullName)"
    }
}
Invoke-Checked 'locked restore' {
    dotnet restore $Solution --locked-mode
}
Invoke-Checked 'Microsoft Store delivery contract' {
    & (Join-Path $PSScriptRoot 'StoreDelivery.Tests.ps1')
}
Invoke-Checked 'Release solution tests' {
    dotnet test $Solution -c Release --no-restore `
        -m:1 -p:TestTfmsInParallel=false `
        --logger 'trx;LogFileName=windows-tests.trx' `
        --results-directory (Join-Path $Results 'dotnet')
}
Invoke-Checked 'shared script monitor contract' {
    & (Join-Path $PSScriptRoot 'run-monitor-contract.ps1') `
        -ScriptMarketRoot (Join-Path $PayloadRoot 'script-market') `
        -NodePath $NodePath
}
Invoke-Checked 'built Codex++ compatibility inspection' {
    & (Join-Path $PSScriptRoot 'CodexPlusCompatibility.Tests.ps1') `
        -BuiltRoot $BuiltRoot
}
Invoke-Checked 'shared dual-monitor runtime smoke' {
    & (Join-Path $PSScriptRoot 'run-codex-plus-monitor-smoke.ps1') `
        -FixtureRoot (Join-Path $PSScriptRoot 'fixtures/monitor-smoke') `
        -ReportPath (Join-Path $Results 'monitor-smoke.json') `
        -NodePath $NodePath
}
Write-Host "run-all-tests: PASS -> $Results"
