#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CandidateExe,
    [Parameter(Mandatory)] [string] $PayloadRoot,
    [Parameter(Mandatory)] [string] $TestResultsRoot,
    [switch] $FixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$CoreTests = Join-Path $PSScriptRoot `
    'CodexOneClick.Core.Tests/CodexOneClick.Core.Tests.csproj'
$Candidate = [IO.Path]::GetFullPath($CandidateExe)
$Payload = [IO.Path]::GetFullPath($PayloadRoot)
$Results = [IO.Path]::GetFullPath($TestResultsRoot)
$Profile = Join-Path $Results 'isolated-profile'
$InnerSmokeReport = Join-Path $Results 'outer-ci-smoke.json'
$FixtureEndpoint = 'http://127.0.0.1:1/v1'

function Fail([string] $Message) { throw "run-install-smoke: $Message" }
function Write-Utf8NoBom([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    Fail "candidate EXE is missing: $Candidate"
}
if (-not (Test-Path -LiteralPath $Payload -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $Payload 'payload-manifest.json') -PathType Leaf)) {
    Fail 'offline payload or manifest is missing'
}
if (-not $FixtureMode -and $env:OS -ne 'Windows_NT') {
    Fail 'candidate install smoke is Windows-only'
}
New-Item -ItemType Directory -Path $Results, $Profile -Force | Out-Null

$savedEnvironment = @{}
$isolatedVariables = @('TEMP', 'TMP', 'LOCALAPPDATA', 'USERPROFILE')
$controlVariables = @('CODEX_ALLOW_CI_SMOKE', 'CODEX_FIXTURE_API_ENDPOINT')
$secretVariables = @(
    'OPENAI_API_KEY', 'DEEPSEEK_API_KEY', 'KIMI_API_KEY', 'ZHIPU_API_KEY',
    'DASHSCOPE_API_KEY', 'QWEN_API_KEY', 'XIAOMI_MIMO_API_KEY'
)
foreach ($name in @($isolatedVariables + $controlVariables + $secretVariables)) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    foreach ($name in $isolatedVariables) {
        $value = Join-Path $Profile $name.ToLowerInvariant()
        New-Item -ItemType Directory -Path $value -Force | Out-Null
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
    foreach ($name in $secretVariables) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable(
        'CODEX_FIXTURE_API_ENDPOINT',
        $FixtureEndpoint,
        'Process')
    [Environment]::SetEnvironmentVariable(
        'CODEX_ALLOW_CI_SMOKE',
        '1',
        'Process')

    $engineEvidence = if ($FixtureMode) {
        'fixtureContractOnly'
    } else {
        $trxRoot = Join-Path $Results 'installer-engine'
        New-Item -ItemType Directory -Path $trxRoot -Force | Out-Null
        dotnet test $CoreTests -c Release --no-restore `
            --filter 'FullyQualifiedName~End_to_end_fixture_preserves_healthy_codex_and_installs_full_offline_bundle' `
            --logger 'trx;LogFileName=installer-engine-smoke.trx' `
            --results-directory $trxRoot
        if ($LASTEXITCODE -ne 0) {
            Fail "InstallerEngine fixture E2E failed with exit code $LASTEXITCODE"
        }
        'passed'
    }

    $candidateLength = (Get-Item -LiteralPath $Candidate).Length
    if ($candidateLength -le 0) { Fail 'candidate EXE is empty' }
    if (-not $FixtureMode) {
        $stream = [IO.File]::OpenRead($Candidate)
        try {
            if ($stream.ReadByte() -ne 0x4d -or $stream.ReadByte() -ne 0x5a) {
                Fail 'candidate EXE does not have a PE MZ header'
            }
        } finally {
            $stream.Dispose()
        }
    }
    $candidateProcess = if ($FixtureMode) {
        [ordered]@{
            status = 'manualRequired'
            reason = 'Fixture mode validates the contract without executing the candidate'
        }
    } else {
        $manifestPath = Join-Path $Payload 'payload-manifest.json'
        $expectedManifestSha256 = (
            Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if (Test-Path -LiteralPath $InnerSmokeReport) {
            Remove-Item -LiteralPath $InnerSmokeReport -Force
        }
        $smokeArgument = '/CODEXSMOKEREPORT="' + $InnerSmokeReport + '"'
        $process = Start-Process -FilePath $Candidate -Wait -PassThru `
            -ArgumentList @(
                '/VERYSILENT',
                '/SUPPRESSMSGBOXES',
                '/NORESTART',
                $smokeArgument
            )
        if ($process.ExitCode -ne 0) {
            Fail "candidate CI smoke exited with code $($process.ExitCode)"
        }
        if (-not (Test-Path -LiteralPath $InnerSmokeReport -PathType Leaf)) {
            Fail 'candidate did not produce the inner WPF smoke report'
        }
        $innerEvidence = Get-Content -LiteralPath $InnerSmokeReport -Raw |
            ConvertFrom-Json
        if ($innerEvidence.status -cne 'pass' -or
            $innerEvidence.payloadManifest -cne 'validated' -or
            $innerEvidence.modelCatalog -cne 'validated' -or
            $innerEvidence.containsSecrets -ne $false -or
            $innerEvidence.payloadManifestSha256 -cne $expectedManifestSha256) {
            Fail 'inner WPF smoke evidence did not match the active payload manifest'
        }
        [ordered]@{
            status = 'passed'
            exitCode = 0
            evidence = 'outer-ci-smoke.json'
            payloadManifestSha256Matched = $true
        }
    }
    $report = [ordered]@{
        schemaVersion = 1
        status = if ($FixtureMode) { 'fixturePass' } else { 'automatedEvidencePass' }
        fixtureApiEndpoint = $FixtureEndpoint
        isolation = [ordered]@{
            profileRoot = 'isolated-profile'
            userProfile = 'isolated'
            localAppData = 'isolated'
            temp = 'isolated'
            realApiCredentialsUsed = $false
        }
        automated = [ordered]@{
            candidateStructure = 'presentAndNonEmpty'
            payloadManifest = 'present'
            installerEngineFixtureE2E = $engineEvidence
            outerExeInnerHost = if ($FixtureMode) { 'manualRequired' } else { 'passed' }
        }
        candidateProcess = $candidateProcess
        manualRequired = @(
            [ordered]@{ id = 'smartscreen'; status = 'manualRequired' },
            [ordered]@{ id = 'oauth-browser'; status = 'manualRequired' },
            [ordered]@{ id = 'uac-ui'; status = 'manualRequired' },
            [ordered]@{ id = 'wpf-interactive-flow'; status = 'manualRequired' }
        )
    }
    Write-Utf8NoBom (Join-Path $Results 'install-smoke.json') (
        ($report | ConvertTo-Json -Depth 8) + "`n")
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $savedEnvironment[$name],
            'Process')
    }
}

Write-Host "run-install-smoke: PASS -> $Results"
