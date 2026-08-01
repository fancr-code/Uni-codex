#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DistRoot,
    [switch] $ExpectUnsigned,
    [string] $ExtractedRoot = '',
    [switch] $FixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExpectedExe = 'Codex-One-Click-Windows-x64-Offline-Setup.exe'
$ValidatePayloadsScript = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'scripts/validate-offline-payloads.ps1'
$RequiredFiles = @(
    $ExpectedExe,
    'SHA256SUMS.txt',
    'payload-manifest.json',
    'SBOM.spdx.json',
    'RELEASE-REPORT.zh-CN.md'
)

function Fail([string] $Message) { throw "verify-release-artifact: $Message" }

function Resolve-SafeDirectory([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Description is missing: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point"
    }
    return $resolved
}

function Assert-SafeTree([string] $Root, [string] $Description) {
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "$Description contains a symbolic link or reparse point: $($item.FullName)"
        }
    }
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$dist = Resolve-SafeDirectory $DistRoot 'dist root'
Assert-SafeTree $dist 'dist root'
foreach ($name in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $dist $name) -PathType Leaf)) {
        Fail "required release file is missing: $name"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $dist 'test-results') -PathType Container)) {
    Fail 'required release directory is missing: test-results'
}
$topFiles = @(Get-ChildItem -LiteralPath $dist -Force -File | ForEach-Object Name)
$topNames = @(Get-ChildItem -LiteralPath $dist -Force | ForEach-Object Name)
$expectedTopNames = @($RequiredFiles + 'test-results' | Sort-Object)
if (Compare-Object $expectedTopNames @($topNames | Sort-Object)) {
    Fail 'release top-level file set is not exact'
}
if (@($topFiles | Where-Object { $_ -like '*.zip' }).Count -ne 0) {
    Fail 'ZIP and online-only release artifacts are forbidden'
}
if (@($topFiles | Where-Object { $_ -like '*.exe' }).Count -ne 1) {
    Fail 'release must contain exactly one EXE'
}

$checksumPath = Join-Path $dist 'SHA256SUMS.txt'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { $_ -ne '' })
$checksums = @{}
foreach ($line in $checksumLines) {
    if ($line -notmatch '^([0-9a-f]{64})  ([^/\\]+)$') {
        Fail "invalid SHA256SUMS line: $line"
    }
    if ($checksums.ContainsKey($Matches[2])) { Fail "duplicate checksum entry: $($Matches[2])" }
    $checksums[$Matches[2]] = $Matches[1]
}
foreach ($name in @($ExpectedExe, 'payload-manifest.json', 'SBOM.spdx.json', 'RELEASE-REPORT.zh-CN.md')) {
    if (-not $checksums.ContainsKey($name) -or
        $checksums[$name] -cne (Get-Sha256 (Join-Path $dist $name))) {
        Fail "checksum mismatch or omission: $name"
    }
}
$expectedChecksumNames = @(
    $ExpectedExe,
    'payload-manifest.json',
    'SBOM.spdx.json',
    'RELEASE-REPORT.zh-CN.md'
)
if (Compare-Object @($expectedChecksumNames | Sort-Object) @($checksums.Keys | Sort-Object)) {
    Fail 'SHA256SUMS file set is not exact'
}

try {
    $manifest = Get-Content -LiteralPath (Join-Path $dist 'payload-manifest.json') -Raw |
        ConvertFrom-Json
    $sbom = Get-Content -LiteralPath (Join-Path $dist 'SBOM.spdx.json') -Raw |
        ConvertFrom-Json
} catch {
    Fail "release JSON is invalid: $($_.Exception.Message)"
}
if (-not $manifest.schemaVersion -or @($manifest.files).Count -eq 0) {
    Fail 'payload manifest is empty or invalid'
}
if ($sbom.spdxVersion -cne 'SPDX-2.3' -or [string]::IsNullOrWhiteSpace($sbom.documentNamespace)) {
    Fail 'SBOM is not a valid SPDX 2.3 document'
}
$packages = @($sbom.packages)
$sbomFiles = @($sbom.files)
if ($packages.Count -ne 1 -or
    -not $packages[0].filesAnalyzed -or
    [string]::IsNullOrWhiteSpace(
        $packages[0].packageVerificationCode.packageVerificationCodeValue) -or
    $sbomFiles.Count -eq 0) {
    Fail 'SBOM package verification data is incomplete'
}
$spdxIdPattern = '^SPDXRef-[A-Za-z0-9.-]+$'
$spdxIds = @([string] $sbom.SPDXID) +
    @($packages | ForEach-Object { [string] $_.SPDXID }) +
    @($sbomFiles | ForEach-Object { [string] $_.SPDXID })
if (@($spdxIds | Where-Object { $_ -cnotmatch $spdxIdPattern }).Count -ne 0 -or
    @($spdxIds | Sort-Object -Unique).Count -ne $spdxIds.Count) {
    Fail 'SBOM document, package, and file SPDX IDs must be valid and globally unique'
}
foreach ($file in $sbomFiles) {
    if ([string]::IsNullOrWhiteSpace($file.licenseConcluded) -or
        @($file.licenseInfoInFiles).Count -eq 0 -or
        [string]::IsNullOrWhiteSpace($file.copyrightText)) {
        Fail "SBOM file licensing fields are incomplete: $($file.fileName)"
    }
}
$containsRelationships = @(
    @($sbom.relationships) |
        Where-Object {
            $_.spdxElementId -ceq 'SPDXRef-Package' -and
            $_.relationshipType -ceq 'CONTAINS'
        }
)
if ($containsRelationships.Count -ne $sbomFiles.Count) {
    Fail 'SBOM package-to-file CONTAINS relationships are incomplete'
}
$fileIds = @($sbomFiles | ForEach-Object { [string] $_.SPDXID } | Sort-Object)
$containsTargets = @(
    $containsRelationships |
        ForEach-Object { [string] $_.relatedSpdxElement } |
        Sort-Object
)
if (Compare-Object $fileIds $containsTargets) {
    Fail 'SBOM CONTAINS targets do not exactly cover the file SPDX IDs'
}
$report = Get-Content -LiteralPath (Join-Path $dist 'RELEASE-REPORT.zh-CN.md') -Raw
foreach ($text in @(
    '签名状态：未签名（首个 Windows 测试版）',
    'SmartScreen：首次运行可能出现“Windows 已保护你的电脑”',
    '校验方式：对照 SHA256SUMS.txt'
)) {
    if (-not $report.Contains($text)) { Fail "release report omitted required text: $text" }
}

$exePath = Join-Path $dist $ExpectedExe
if ($ExpectUnsigned) {
    $signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    if ($null -eq $signatureCommand) {
        if (-not $FixtureMode) {
            Fail 'Authenticode verification is Windows-only; use FixtureMode only for mock artifacts'
        }
    } else {
        $signature = Get-AuthenticodeSignature -LiteralPath $exePath
        if ($signature.Status -ne 'NotSigned') {
            Fail "expected unsigned EXE, got Authenticode status $($signature.Status)"
        }
    }
}

$temporaryExtraction = $null
if ([string]::IsNullOrWhiteSpace($ExtractedRoot)) {
    $temporaryExtraction = Join-Path ([IO.Path]::GetTempPath()) (
        'codex-release-extract-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $temporaryExtraction) {
        Fail "generated extraction root already exists: $temporaryExtraction"
    }
    if ($env:OS -eq 'Windows_NT') {
        if ($temporaryExtraction.Contains('"')) {
            Fail "generated extraction root contains an unsupported quote character: $temporaryExtraction"
        }
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $exePath
        $startInfo.UseShellExecute = $false
        $startInfo.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART ' +
            '/CODEXEXTRACTROOT="' + $temporaryExtraction + '"'
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            Fail "installer-native extraction failed with exit code $($process.ExitCode)"
        }
    } else {
        $extractor = Get-Command 7z, 7zz, innounp -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $extractor) {
            Fail 'cannot inspect Inno contents: provide ExtractedRoot or install 7z/innounp'
        }
        New-Item -ItemType Directory -Path $temporaryExtraction | Out-Null
        if ($extractor.Name -eq 'innounp') {
            & $extractor.Source '-x' "-d$temporaryExtraction" $exePath | Out-Null
        } else {
            & $extractor.Source 'x' '-y' "-o$temporaryExtraction" $exePath | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { Fail 'Inno extraction failed' }
    }
    $ExtractedRoot = $temporaryExtraction
}
try {
    $extraction = Resolve-SafeDirectory $ExtractedRoot 'extracted root'
    Assert-SafeTree $extraction 'extracted root'
    $contentRoots = @()
    if ((Test-Path -LiteralPath (Join-Path $extraction 'app') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $extraction 'offline-payloads') -PathType Container)) {
        $contentRoots += $extraction
    }
    $contentRoots += @(
        Get-ChildItem -LiteralPath $extraction -Force -Recurse -Directory |
            Where-Object {
                $_.Name -like 'codex-one-click-*' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'app') -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'offline-payloads') -PathType Container)
            } |
            ForEach-Object FullName
    )
    $contentRoots = @($contentRoots | Sort-Object -Unique)
    if ($contentRoots.Count -ne 1) {
        Fail "expected exactly one extracted codex-one-click content root, found $($contentRoots.Count)"
    }
    $stage = $contentRoots[0]
    foreach ($directory in @('app', 'offline-payloads', 'guides', 'licenses')) {
        $path = Join-Path $stage $directory
        if (-not (Test-Path -LiteralPath $path -PathType Container) -or
            @(Get-ChildItem -LiteralPath $path -Force -Recurse -File).Count -eq 0) {
            Fail "extracted release directory is missing or empty: $directory"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'app/CodexOneClickInstaller.exe') -PathType Leaf)) {
        Fail 'WPF publish executable is absent from extracted release'
    }
    $innerManifest = Join-Path $stage 'offline-payloads/payload-manifest.json'
    if (-not (Test-Path -LiteralPath $innerManifest -PathType Leaf) -or
        (Get-Sha256 $innerManifest) -cne
            (Get-Sha256 (Join-Path $dist 'payload-manifest.json'))) {
        Fail 'inner payload manifest is absent or differs from the release manifest'
    }
    $innerPayloadRoot = Join-Path $stage 'offline-payloads'
    $payloadValidationError = ''
    $payloadValidationExitCode = 0
    try {
        $LASTEXITCODE = 0
        if ($FixtureMode) {
            & $ValidatePayloadsScript -PayloadRoot $innerPayloadRoot -FixtureMode
        } else {
            & $ValidatePayloadsScript -PayloadRoot $innerPayloadRoot `
                -StrictSignatures -StagedGeneration
        }
        $payloadValidationExitCode = $LASTEXITCODE
    } catch {
        $payloadValidationError = $_.Exception.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($payloadValidationError)) {
        Fail "extracted payload validation failed: $payloadValidationError"
    }
    if ($payloadValidationExitCode -ne 0) {
        Fail "extracted payload validation failed with exit code $payloadValidationExitCode"
    }
    foreach ($entry in @($manifest.files)) {
        $relative = [string] $entry.relativePath
        $normalized = $relative.Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relative) -or
            $normalized.StartsWith('/') -or
            $normalized -match '^[A-Za-z]:' -or
            @($normalized.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -ne 0) {
            Fail "payload manifest contains an unsafe relative path: $relative"
        }
        $payloadPath = Join-Path $innerPayloadRoot (
            $normalized.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            Fail "manifest payload is absent from extracted release: $relative"
        }
        if ((Get-Item -LiteralPath $payloadPath -Force).PSIsContainer -and
            @(Get-ChildItem -LiteralPath $payloadPath -Force -Recurse -File).Count -eq 0) {
            Fail "manifest payload directory is empty: $relative"
        }
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $dist 'test-results') -Force -File).Count -eq 0) {
        Fail 'test-results is empty'
    }
} finally {
    if ($null -ne $temporaryExtraction -and (Test-Path -LiteralPath $temporaryExtraction)) {
        Remove-Item -LiteralPath $temporaryExtraction -Recurse -Force
    }
}

Write-Host 'verify-release-artifact: PASS'
