#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot

function Assert-Contains([string] $Text, [string] $Value, [string] $Description) {
    if (-not $Text.Contains($Value)) {
        throw "WorkflowContract.Tests: $Description omitted '$Value'"
    }
}
function Read-Required([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "WorkflowContract.Tests: missing $Path"
    }
    return Get-Content -LiteralPath $Path -Raw
}

$ci = Read-Required (Join-Path $RepositoryRoot '.github/workflows/windows-ci.yml')
$release = Read-Required (Join-Path $RepositoryRoot '.github/workflows/windows-release.yml')
$attributes = Read-Required (Join-Path $RepositoryRoot '.gitattributes')
$all = Read-Required (Join-Path $PSScriptRoot 'run-all-tests.ps1')
$smoke = Read-Required (Join-Path $PSScriptRoot 'run-install-smoke.ps1')
$buildInstaller = Read-Required (Join-Path $WindowsRoot 'scripts/build-installer.ps1')
$releaseArtifact = Read-Required (Join-Path $PSScriptRoot 'ReleaseArtifact.Tests.ps1')
$releaseVerifier = Read-Required (Join-Path $PSScriptRoot 'verify-release-artifact.ps1')
$coreAssemblyPolicy = Read-Required (Join-Path $PSScriptRoot `
    'CodexOneClick.Core.Tests/AssemblyInfo.cs')
$guiAssemblyPolicy = Read-Required (Join-Path $PSScriptRoot `
    'CodexOneClick.Gui.Tests/AssemblyInfo.cs')

Assert-Contains $buildInstaller '-StagedGeneration' `
    'production installer build must validate the resolved active generation'
Assert-Contains $releaseVerifier '-StagedGeneration' `
    'release verifier must validate the extracted active generation'

foreach ($value in @(
    'windows/tests/fixtures/payload-root/** -text',
    'windows/tests/fixtures/payload-manifest.*.json -text',
    'windows/tests/fixtures/end-to-end/script-market/** -text',
    'patches/CodexPlusPlus/*.patch -text'
)) { Assert-Contains $attributes $value 'byte-stable fixture attributes' }

foreach ($value in @(
    'README.md', 'windows/**', 'Resources/**', 'patches/**',
    'tests/script-runtime/**',
    '.github/workflows/windows-*.yml',
    'actions/checkout@v6', 'actions/setup-dotnet@v5', 'actions/setup-node@v6',
    'actions/upload-artifact@v7', 'windows-latest', 'timeout-minutes:',
    'ReleaseArtifact.Tests.ps1', '-RequireRealInno', '-EvidenceOutput',
    'WorkflowContract.Tests.ps1', 'DocumentationTests.ps1',
    'CODEX_LAYOUT_SCREENSHOT_DIR', 'screenshots/*.png', 'test-results/inno/**',
    'StartupContractTests', 'ViewModelTests'
)) { Assert-Contains $ci $value 'PR workflow' }
foreach ($workflow in @(
    @{ Name = 'PR'; Text = $ci },
    @{ Name = 'release'; Text = $release }
)) {
    foreach ($value in @(
        'Microsoft Store delivery contract',
        'StoreDelivery.Tests.ps1',
        '-ResolveLive'
    )) { Assert-Contains $workflow.Text $value "$($workflow.Name) Store delivery gate" }
    foreach ($value in @(
        'Install verified NSIS 3.12',
        'https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12-setup.exe',
        '3bc2b06253a7e4957111be152ac6a536e0c7478a706e19da814038db5d706495',
        'makensis.exe',
        '/VERSION',
        'v3.12',
        'curl.exe',
        '--location',
        '--fail',
        '--retry 3'
    )) { Assert-Contains $workflow.Text $value "$($workflow.Name) workflow NSIS gate" }
    $nsisBlock = [regex]::Match(
        $workflow.Text,
        '(?s)- name: Install verified NSIS 3\.12.*?(?=\s+- name:|\z)')
    if (-not $nsisBlock.Success -or $nsisBlock.Value.Contains('Invoke-WebRequest')) {
        throw "WorkflowContract.Tests: $($workflow.Name) workflow NSIS gate must not use Invoke-WebRequest"
    }
}
if ($release.IndexOf('Microsoft Store delivery contract', [StringComparison]::Ordinal) -gt
    $release.IndexOf('Build Codex++ compatibility payload', [StringComparison]::Ordinal)) {
    throw 'WorkflowContract.Tests: release resolves Store payload after the expensive Codex++ build'
}
if ($ci -notmatch '(?m)^\s*-\s+"README\.md"\s*$') {
    throw 'WorkflowContract.Tests: PR workflow omits exact root README.md path'
}
if ($ci.Contains('windows/tests/fixtures/payload-root/**')) {
    throw 'WorkflowContract.Tests: PR workflow uploads input fixture payload as evidence'
}
foreach ($value in @(
    'workflow_dispatch:', 'release_tag:', 'contents: write', 'run-all-tests.ps1',
    'build-installer.ps1', 'run-install-smoke.ps1', 'verify-release-artifact.ps1',
    'gh release', 'actions/upload-artifact@v7', 'git rev-parse origin/main',
    'Copy release test evidence into dist', 'windows-tests.trx', 'monitor-smoke.json',
    'Expected exactly one release evidence file'
)) { Assert-Contains $release $value 'release workflow' }
foreach ($value in @(
    'redistribution_authorized:', 'CODEX_REDISTRIBUTION_AUTHORIZED',
    'Verify redistribution authorization'
)) { Assert-Contains $release $value 'release compliance gate' }
if ([regex]::Matches($release, 'git fetch origin main').Count -lt 2) {
    throw 'WorkflowContract.Tests: release workflow does not refetch final main before publishing'
}
foreach ($workflow in @(
    @{ Name = 'PR'; Text = $ci },
    @{ Name = 'release'; Text = $release }
)) {
    if ($workflow.Text.Contains('7z extractor missing')) {
        throw "WorkflowContract.Tests: $($workflow.Name) workflow retains obsolete 7z prerequisite"
    }
}
foreach ($value in @(
    'dotnet restore', '--locked-mode', 'dotnet test', 'CodexOneClickInstaller.sln',
    'run-monitor-contract.ps1', 'CodexPlusCompatibility.Tests.ps1',
    'run-codex-plus-monitor-smoke.ps1', 'Language.Parser',
    '-m:1', '-p:TestTfmsInParallel=false'
)) { Assert-Contains $all $value 'full test entry point' }
foreach ($policy in @($coreAssemblyPolicy, $guiAssemblyPolicy)) {
    Assert-Contains $policy 'CollectionBehavior' 'xUnit serialization policy'
    Assert-Contains $policy 'DisableTestParallelization = true' `
        'xUnit serialization policy'
}
foreach ($value in @(
    'Core full serialized tests',
    '-m:1',
    '-p:TestTfmsInParallel=false'
)) { Assert-Contains $ci $value 'PR serialized Core gate' }
if ($ci.Contains(
        'FullyQualifiedName~DomainTests|FullyQualifiedName~ConfigurationTests|' +
        'FullyQualifiedName~PayloadCatalogTests')) {
    throw 'WorkflowContract.Tests: PR Core gate still runs only a filtered subset'
}
foreach ($forbidden in @(
    'macOSVersion', 'installer-core.ps1', 'ReleaseArtifact.Tests.ps1',
    'run-install-smoke.ps1', 'verify-release-artifact.ps1'
)) {
    if ($all.Contains($forbidden)) {
        throw "WorkflowContract.Tests: full test entry retains forbidden legacy field '$forbidden'"
    }
}
foreach ($value in @(
    'manualRequired', 'USERPROFILE', 'LOCALAPPDATA', 'fixtureApiEndpoint',
    'End_to_end_fixture_preserves_healthy_codex_and_installs_full_offline_bundle',
    'Start-Process', '/CODEXSMOKEREPORT=', 'outer-ci-smoke.json',
    'payloadManifestSha256'
)) { Assert-Contains $smoke $value 'install smoke' }

foreach ($script in @(
    @{ Name = 'build-installer'; Text = $buildInstaller },
    @{ Name = 'ReleaseArtifact.Tests'; Text = $releaseArtifact }
)) {
    if ($script.Text.Contains('.VersionInfo.ProductVersion')) {
        throw "WorkflowContract.Tests: $($script.Name) reads PE ProductVersion instead of compiler runtime output"
    }
    Assert-Contains $script.Text 'Compiler engine version: Inno Setup 7.0.2' "$($script.Name) runtime Inno version attestation"
}
foreach ($value in @(
    '[switch] $VerifyInnoRuntimeVersion',
    '(-not $FixtureMode -or $VerifyInnoRuntimeVersion)',
    '[string] $_ -ceq $ExpectedInnoRuntimeBanner',
    '$innoExitCode = $LASTEXITCODE',
    'if ($innoExitCode -ne 0)'
)) { Assert-Contains $buildInstaller $value 'build-installer runtime Inno gate' }
foreach ($value in @(
    '-VerifyInnoRuntimeVersion',
    '[string] $_ -ceq $ExpectedInnoRuntimeBanner',
    '$realInnoBuildExitCode = $LASTEXITCODE',
    'Assert-True ($realInnoBuildExitCode -eq 0)'
)) { Assert-Contains $releaseArtifact $value 'ReleaseArtifact real Inno gate' }
foreach ($value in @(
    'CODEXEXTRACTROOT',
    'GetContentDestination',
    "extractor = 'installer-native'"
)) { Assert-Contains $releaseArtifact $value 'ReleaseArtifact native extraction contract' }
foreach ($value in @(
    'CODEXEXTRACTROOT',
    'Diagnostics.ProcessStartInfo',
    '$startInfo.Arguments',
    'validate-offline-payloads.ps1',
    '-FixtureMode',
    '-StrictSignatures'
)) { Assert-Contains $releaseVerifier $value 'release verifier native extraction contract' }
if ($releaseVerifier.Contains('ArgumentList')) {
    throw 'WorkflowContract.Tests: release verifier requires PowerShell 7-only ArgumentList'
}
if ($releaseArtifact.Contains('Get-Command 7z, 7zz, innounp')) {
    throw 'WorkflowContract.Tests: ReleaseArtifact real gate still requires an external extractor'
}

Write-Host 'WorkflowContract.Tests: PASS'
