#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $RealIsccPath = '',
    [switch] $RequireRealInno,
    [string] $EvidenceOutput = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $TestRoot
$BuildScript = Join-Path $WindowsRoot 'scripts/build-installer.ps1'
$VerifyScript = Join-Path $TestRoot 'verify-release-artifact.ps1'
$IssPath = Join-Path $WindowsRoot 'installer/CodexOneClick.iss'
$FixturePayload = Join-Path $TestRoot 'fixtures/payload-root'
$ExpectedInnoRuntimeBanner = 'Compiler engine version: Inno Setup 7.0.2'
$TemporaryBase = if ($env:OS -eq 'Windows_NT') {
    [IO.Path]::GetTempPath()
} elseif (Test-Path -LiteralPath '/private/tmp' -PathType Container) {
    '/private/tmp'
} else {
    '/tmp'
}
$Temporary = Join-Path $TemporaryBase (
    'codex-release-artifact-tests-' + [Guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ReleaseArtifact.Tests: $Message" }
}
function Write-Utf8NoBom([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Get-PeMachine([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        Assert-True ($stream.Length -ge 0x40) "not a PE file: $Path"
        Assert-True ($reader.ReadUInt16() -eq 0x5a4d) "not a PE file: $Path"
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        Assert-True (($peOffset -le ($stream.Length - 6)) -and ($peOffset -ge 0x40)) `
            "PE header offset is out of bounds: $Path"
        $stream.Position = $peOffset
        Assert-True ($reader.ReadUInt32() -eq 0x00004550) "invalid PE signature: $Path"
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$runRealInno = $env:OS -eq 'Windows_NT' -or
    $RequireRealInno -or
    -not [string]::IsNullOrWhiteSpace($RealIsccPath)
$realCompilerVersion = $null
if (-not [string]::IsNullOrWhiteSpace($EvidenceOutput) -and -not $runRealInno) {
    throw 'ReleaseArtifact.Tests: EvidenceOutput requires a real Inno run'
}
if ($runRealInno) {
    if ($env:OS -ne 'Windows_NT') {
        throw 'ReleaseArtifact.Tests: RequireRealInno is Windows-only and cannot be skipped'
    }
    if ([string]::IsNullOrWhiteSpace($RealIsccPath)) {
        $isccCommand = Get-Command ISCC.exe, iscc -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $isccCommand) {
            $RealIsccPath = $isccCommand.Source
        }
    }
    if ([string]::IsNullOrWhiteSpace($RealIsccPath) -or
        -not (Test-Path -LiteralPath $RealIsccPath -PathType Leaf)) {
        throw 'ReleaseArtifact.Tests: Windows requires real Inno 7.0.2 via RealIsccPath or PATH'
    }
} else {
    $missingRealRejected = $false
    try {
        & $MyInvocation.MyCommand.Path -RequireRealInno
    } catch {
        $missingRealRejected = $_.Exception.Message.Contains(
            'RequireRealInno is Windows-only') -or
            $_.Exception.Message.Contains('requires an existing RealIsccPath')
    }
    Assert-True $missingRealRejected 'RequireRealInno silently skipped missing real tools'
}

New-Item -ItemType Directory -Path $Temporary | Out-Null
try {
    $publish = Join-Path $Temporary 'publish'
    $fakeState = Join-Path $Temporary 'fake-iscc-state'
    $dist = Join-Path $Temporary 'dist'
    New-Item -ItemType Directory -Path $publish, $fakeState | Out-Null
    Write-Utf8NoBom (Join-Path $publish 'CodexOneClickInstaller.exe') 'fixture WPF executable'
    Write-Utf8NoBom (Join-Path $publish 'CodexOneClickInstaller.dll') 'fixture self-contained publish'

    $fakeIscc = Join-Path $Temporary 'fake-iscc.ps1'
    $fakeScript = @'
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
$ErrorActionPreference = 'Stop'
$stage = ($Arguments | Where-Object { $_ -like '/DStageRoot=*' }).Substring(12)
$output = ($Arguments | Where-Object { $_ -like '/DOutputDir=*' }).Substring(12)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$extracted = Join-Path $env:CODEX_FAKE_ISCC_STATE 'extracted'
New-Item -ItemType Directory -Path $extracted -Force | Out-Null
Copy-Item -Path (Join-Path $stage '*') -Destination $extracted -Recurse -Force
$fixturePe = Join-Path $env:CODEX_FAKE_ISCC_STATE 'unsigned-x64-fixture.exe'
if (-not (Test-Path -LiteralPath $fixturePe -PathType Leaf)) {
    $fixtureSource = @"
public static class CodexFixtureUnsignedPeMarker_20260730
{
    public static int Marker => 1;
}
"@
    Add-Type -TypeDefinition $fixtureSource -OutputAssembly $fixturePe `
        -OutputType Library -CompilerOptions '/platform:x64'
}
Copy-Item -LiteralPath $fixturePe -Destination (Join-Path $output 'Codex-One-Click-Windows-x64-Offline-Setup.exe') -Force
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_FAKE_ISCC_RUNTIME_BANNER)) {
    Write-Output $env:CODEX_FAKE_ISCC_RUNTIME_BANNER
}
'@
    Write-Utf8NoBom $fakeIscc $fakeScript
    $previousState = $env:CODEX_FAKE_ISCC_STATE
    $env:CODEX_FAKE_ISCC_STATE = $fakeState
    try {
        & $BuildScript -PayloadRoot $FixturePayload -OutputDir $dist `
            -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode
        Assert-True ($LASTEXITCODE -eq 0) 'fixture build failed'
    } finally {
        $env:CODEX_FAKE_ISCC_STATE = $previousState
    }
    $fixtureSetup = Join-Path $dist 'Codex-One-Click-Windows-x64-Offline-Setup.exe'
    Assert-True ((Get-PeMachine $fixtureSetup) -eq 0x8664) `
        'fake ISCC fixture setup is not a valid x64 PE'
    foreach ($invalidRuntimeBanner in @('', 'Compiler engine version: Inno Setup 7.0.2.1')) {
        $previousAttestationState = $env:CODEX_FAKE_ISCC_STATE
        $previousRuntimeBanner = $env:CODEX_FAKE_ISCC_RUNTIME_BANNER
        $env:CODEX_FAKE_ISCC_STATE = $fakeState
        $env:CODEX_FAKE_ISCC_RUNTIME_BANNER = $invalidRuntimeBanner
        $runtimeAttestationRejected = $false
        try {
            & $BuildScript -PayloadRoot $FixturePayload `
                -OutputDir (Join-Path $Temporary ('runtime-attestation-' + [Guid]::NewGuid().ToString('N'))) `
                -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode -VerifyInnoRuntimeVersion
        } catch {
            $runtimeAttestationRejected = $_.Exception.Message.Contains(
                'ISCC must report exact runtime banner')
        } finally {
            $env:CODEX_FAKE_ISCC_STATE = $previousAttestationState
            $env:CODEX_FAKE_ISCC_RUNTIME_BANNER = $previousRuntimeBanner
        }
        Assert-True $runtimeAttestationRejected `
            "build accepted invalid exact runtime banner '$invalidRuntimeBanner'"
    }
    & $VerifyScript -DistRoot $dist -ExpectUnsigned -FixtureMode `
        -ExtractedRoot (Join-Path $fakeState 'extracted')
    Assert-True ($LASTEXITCODE -eq 0) 'fixture release verification failed'
    $tamperedExtraction = Join-Path $Temporary 'tampered-extraction'
    Copy-Item -LiteralPath (Join-Path $fakeState 'extracted') `
        -Destination $tamperedExtraction -Recurse
    [IO.File]::AppendAllText(
        (Join-Path $tamperedExtraction 'offline-payloads/apps/CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe'),
        'tampered')
    $tamperedExtractionRejected = $false
    try {
        & $VerifyScript -DistRoot $dist -ExpectUnsigned -FixtureMode `
            -ExtractedRoot $tamperedExtraction
    } catch {
        $tamperedExtractionRejected = $_.Exception.Message.Contains(
            'extracted payload validation failed')
    }
    Assert-True $tamperedExtractionRejected `
        'release verification accepted a tampered extracted manifest payload'

    $topNames = @(Get-ChildItem -LiteralPath $dist -Force | ForEach-Object Name)
    Assert-True (@($topNames | Where-Object { $_ -like '*.zip' }).Count -eq 0) `
        'fixture generated a ZIP'
    Assert-True (@($topNames | Where-Object { $_ -like '*.exe' }).Count -eq 1) `
        'fixture release does not contain exactly one EXE'
    $iss = Get-Content -LiteralPath $IssPath -Raw
    foreach ($required in @(
        'SetupArchitecture=x64',
        'ArchitecturesAllowed=x64compatible',
        'MinVersion=10.0.17763',
        'PrivilegesRequired=lowest',
        'Uninstallable=no',
        'GetCustomSetupExitCode',
        'ewWaitUntilTerminated',
        '--payload-root',
        'CODEXSMOKEREPORT',
        'CODEXEXTRACTROOT',
        'GetContentDestination',
        '--ci-smoke-report'
    )) {
        Assert-True $iss.Contains($required) "Inno source omitted: $required"
    }
    Assert-True (-not $iss.Contains('[Run]')) 'Inno source must launch WPF only from checked [Code]'
    $verifierText = Get-Content -LiteralPath $VerifyScript -Raw
    Assert-True $verifierText.Contains('CODEXEXTRACTROOT') `
        'release verifier does not request installer-native extraction'
    Assert-True $verifierText.Contains('Diagnostics.ProcessStartInfo') `
        'release verifier does not start the installer natively'
    $buildText = Get-Content -LiteralPath $BuildScript -Raw
    foreach ($required in @(
        '--self-contained true',
        '-r win-x64',
        '-p:PublishTrimmed=false',
        '-StrictSignatures',
        '5ad54ca3def786f8f4212552e54cc6d8d61329e2d24a1cfee0571d42c2684ff1'
    )) {
        Assert-True $buildText.Contains($required) "build script omitted: $required"
    }
    foreach ($forbidden in @('Compress-Archive', 'SigningCertificate', 'AdHocOnly')) {
        Assert-True (-not $buildText.Contains($forbidden)) "build script retained forbidden flow: $forbidden"
    }
    $missingRejected = $false
    try {
        & $BuildScript -PayloadRoot (Join-Path $Temporary 'missing-payload') `
            -OutputDir (Join-Path $Temporary 'must-not-exist') `
            -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode
    } catch {
        $missingRejected = $_.Exception.Message.Contains('offline payload root is missing')
    }
    Assert-True $missingRejected 'build did not reject a missing payload root'
    $protectedOutputRejected = $false
    try {
        & $BuildScript -PayloadRoot $FixturePayload -OutputDir $WindowsRoot `
            -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode
    } catch {
        $protectedOutputRejected = $_.Exception.Message.Contains(
            'OutputDir may not equal')
    }
    Assert-True $protectedOutputRejected 'build accepted WindowsRoot as OutputDir'
    $buildOutputRejected = $false
    try {
        & $BuildScript -PayloadRoot $FixturePayload `
            -OutputDir (Join-Path $WindowsRoot 'build/release-output') `
            -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode
    } catch {
        $buildOutputRejected = $_.Exception.Message.Contains(
            'inside a protected source directory')
    }
    Assert-True $buildOutputRejected `
        'build accepted an OutputDir inside its temporary build tree'
    if ($env:OS -ne 'Windows_NT') {
        $unsafeOutput = Join-Path $Temporary 'unsafe-existing-output'
        $unsafeChild = Join-Path $unsafeOutput 'nested'
        New-Item -ItemType Directory -Path $unsafeChild | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $unsafeChild 'payload-link') `
            -Target $FixturePayload | Out-Null
        $reparseOutputRejected = $false
        try {
            & $BuildScript -PayloadRoot $FixturePayload -OutputDir $unsafeOutput `
                -PublishRoot $publish -IsccPath $fakeIscc -FixtureMode
        } catch {
            $reparseOutputRejected = $_.Exception.Message.Contains(
                'existing output directory contains a symbolic link')
        }
        Assert-True $reparseOutputRejected `
            'build accepted a reparse point nested in the existing output tree'
    }
    if ($runRealInno) {
        $realDist = Join-Path $Temporary 'real-inno-dist'
        $realInnoBuildOutput = @(& $BuildScript -PayloadRoot $FixturePayload -OutputDir $realDist `
            -PublishRoot $publish -IsccPath $RealIsccPath -FixtureMode -VerifyInnoRuntimeVersion
        )
        $realInnoBuildExitCode = $LASTEXITCODE
        $realInnoBuildOutput | Write-Output
        Assert-True ($realInnoBuildExitCode -eq 0) 'real Inno fixture build failed'
        Assert-True (@($realInnoBuildOutput | Where-Object {
                [string] $_ -ceq $ExpectedInnoRuntimeBanner
            }).Count -gt 0) 'real Inno fixture build omitted exact compiler runtime banner'
        $realCompilerVersion = '7.0.2'
        & $VerifyScript -DistRoot $realDist -ExpectUnsigned -FixtureMode
        Assert-True ($LASTEXITCODE -eq 0) 'real Inno extraction verification failed'
        if (-not [string]::IsNullOrWhiteSpace($EvidenceOutput)) {
            $evidenceRoot = [IO.Path]::GetFullPath($EvidenceOutput)
            $artifactRoot = Join-Path $evidenceRoot 'artifact'
            New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
            Copy-Item -Path (Join-Path $realDist '*') `
                -Destination $artifactRoot -Recurse -Force
            $evidence = [ordered]@{
                schemaVersion = 1
                status = 'pass'
                realInno = $true
                innoCompilerVersion = $realCompilerVersion
                extractor = 'installer-native'
                artifactDirectory = 'artifact'
            }
            Write-Utf8NoBom (Join-Path $evidenceRoot 'verification.json') (
                ($evidence | ConvertTo-Json -Depth 4) + "`n")
        }
    }
    Write-Host 'ReleaseArtifact.Tests: PASS'
} finally {
    if (Test-Path -LiteralPath $Temporary) {
        Remove-Item -LiteralPath $Temporary -Recurse -Force
    }
}
