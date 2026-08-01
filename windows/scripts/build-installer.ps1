#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $PayloadRoot = '',
    [string] $OutputDir = '',
    [string] $Configuration = 'Release',
    [string] $IsccPath = '',
    [string] $InnoRoot = '',
    [string] $InnoInstallerPath = '',
    [string] $PublishRoot = '',
    [switch] $FixtureMode,
    [switch] $VerifyInnoRuntimeVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$InnoVersion = '7.0.2'
$InnoDownloadUrl =
    'https://github.com/jrsoftware/issrc/releases/download/is-7_0_2/innosetup-7.0.2-x64.exe'
$InnoInstallerSha256 =
    '5ad54ca3def786f8f4212552e54cc6d8d61329e2d24a1cfee0571d42c2684ff1'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$InstallerSource = Join-Path $WindowsRoot 'installer/CodexOneClick.iss'
$Project = Join-Path $WindowsRoot 'src/InstallerGUI/CodexOneClickInstaller.csproj'
$ValidateScript = Join-Path $ScriptRoot 'validate-offline-payloads.ps1'
$SbomScript = Join-Path $ScriptRoot 'generate-sbom.ps1'
$ExpectedExe = 'Codex-One-Click-Windows-x64-Offline-Setup.exe'
$ExpectedInnoRuntimeBanner = 'Compiler engine version: Inno Setup 7.0.2'

function Fail([string] $Message) { throw "build-installer: $Message" }
function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}
function Assert-ReparseFreeAncestors([string] $Path, [string] $Description) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($null -ne $current) {
        if ([IO.Directory]::Exists($current) -or [IO.File]::Exists($current)) {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "$Description has a symbolic link or reparse-point ancestor: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}
function Assert-SafeDirectoryTree([string] $Root, [string] $Description) {
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "$Description contains a symbolic link or reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}
function Resolve-SafeDirectory([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Description is missing: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Assert-ReparseFreeAncestors $resolved $Description
    $rootItem = Get-Item -LiteralPath $resolved -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point: $resolved"
    }
    Assert-SafeDirectoryTree $resolved $Description
    return $resolved
}
function Resolve-OutputPath([string] $Path, [string] $DefaultName) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return Join-Path $WindowsRoot $DefaultName }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $WindowsRoot $Path))
}
function Invoke-Checked([string] $Description, [scriptblock] $Operation) {
    $global:LASTEXITCODE = 0
    & $Operation
    if (-not $? -or $LASTEXITCODE -ne 0) {
        Fail "$Description failed with exit code $LASTEXITCODE"
    }
}
function Test-SameOrDescendant([string] $Candidate, [string] $Parent) {
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    if ($candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path -LiteralPath $InstallerSource -PathType Leaf)) {
    Fail 'Inno source is missing'
}
$payloadInput = if ([string]::IsNullOrWhiteSpace($PayloadRoot)) {
    Join-Path $WindowsRoot 'vendor/offline-payloads'
} else { $PayloadRoot }
$payload = Resolve-SafeDirectory $payloadInput 'offline payload root'
$output = Resolve-OutputPath $OutputDir 'dist'
$outputRoot = [IO.Path]::GetPathRoot($output)
$protectedSources = @(
    (Join-Path $WindowsRoot 'src'),
    (Join-Path $WindowsRoot 'scripts'),
    (Join-Path $WindowsRoot 'installer'),
    (Join-Path $WindowsRoot 'tests'),
    (Join-Path $WindowsRoot 'Resources'),
    (Join-Path $WindowsRoot 'docs'),
    (Join-Path $WindowsRoot 'vendor'),
    (Join-Path $WindowsRoot 'build')
)
if ($output.TrimEnd('\', '/') -eq $outputRoot.TrimEnd('\', '/') -or
    (Test-SameOrDescendant $payload $output) -or
    (Test-SameOrDescendant $WindowsRoot $output) -or
    (Test-SameOrDescendant $RepositoryRoot $output) -or
    (Test-SameOrDescendant $output $payload)) {
    Fail 'OutputDir may not equal, contain, or be inside a protected root or payload'
}
foreach ($protected in $protectedSources) {
    if (Test-SameOrDescendant $output $protected) {
        Fail "OutputDir may not equal or be inside a protected source directory: $protected"
    }
}
$outputParent = Split-Path -Parent $output
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
Assert-ReparseFreeAncestors $outputParent 'output parent'
if (Test-Path -LiteralPath $output) {
    if (-not (Test-Path -LiteralPath $output -PathType Container)) {
        Fail 'existing OutputDir is not a directory'
    }
    [void] (Resolve-SafeDirectory $output 'existing output directory')
}

if (-not [string]::IsNullOrWhiteSpace($InnoInstallerPath)) {
    if (-not (Test-Path -LiteralPath $InnoInstallerPath -PathType Leaf)) {
        Fail "Inno installer is missing: $InnoInstallerPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $InnoInstallerPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if ($actualHash -cne $InnoInstallerSha256) {
        Fail 'Inno 7.0.2 installer SHA256 mismatch; the installer was not executed'
    }
    Write-Host 'Pinned Inno installer verified. This script never executes compiler installers.'
}
if ([string]::IsNullOrWhiteSpace($IsccPath) -and
    -not [string]::IsNullOrWhiteSpace($InnoRoot)) {
    $IsccPath = Join-Path $InnoRoot 'ISCC.exe'
}
if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $isccCommand = Get-Command ISCC.exe, iscc -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $isccCommand) { $IsccPath = $isccCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($IsccPath) -or
    -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    Fail ("ISCC $InnoVersion is required. Download only $InnoDownloadUrl and verify SHA256 " +
        "$InnoInstallerSha256 before installing it.")
}
$isccItem = Get-Item -LiteralPath $IsccPath -Force
if (($isccItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Fail 'ISCC path is a symbolic link or reparse point'
}
if (-not $FixtureMode -and $env:OS -ne 'Windows_NT') {
    Fail 'production Inno builds are Windows-only'
}
if ($FixtureMode) {
    Invoke-Checked 'fixture payload validation' {
        & $ValidateScript -PayloadRoot $payload -FixtureMode
    }
} else {
    Invoke-Checked 'strict offline payload validation' {
        & $ValidateScript -PayloadRoot $payload -StrictSignatures `
            -StagedGeneration
    }
}

$buildParent = Join-Path $WindowsRoot 'build'
New-Item -ItemType Directory -Path $buildParent -Force | Out-Null
Assert-ReparseFreeAncestors $buildParent 'work/build parent'
$workRoot = Join-Path $buildParent (
    'installer-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $workRoot 'stage'
$appStage = Join-Path $stage 'app'
$payloadStage = Join-Path $stage 'offline-payloads'
$guideStage = Join-Path $stage 'guides'
$licenseStage = Join-Path $stage 'licenses'
$temporaryDist = Join-Path $outputParent (
    '.' + (Split-Path -Leaf $output) + '-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$backupDist = $null
try {
    New-Item -ItemType Directory -Path $appStage, $guideStage, $licenseStage, $temporaryDist |
        Out-Null
    if ([string]::IsNullOrWhiteSpace($PublishRoot)) {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($null -eq $dotnet) { Fail '.NET 8 SDK is required' }
        Invoke-Checked 'self-contained win-x64 publish' {
            & $dotnet.Source publish $Project -c $Configuration -r win-x64 `
                --self-contained true -p:PublishTrimmed=false -p:PublishSingleFile=false `
                -p:DebugType=None -p:DebugSymbols=false -o $appStage
        }
    } else {
        $publish = Resolve-SafeDirectory $PublishRoot 'fixture publish root'
        Copy-Item -Path (Join-Path $publish '*') -Destination $appStage `
            -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath (Join-Path $appStage 'CodexOneClickInstaller.exe') -PathType Leaf)) {
        Fail 'self-contained publish omitted CodexOneClickInstaller.exe'
    }
    Copy-Item -LiteralPath $payload -Destination $payloadStage -Recurse
    $guides = Resolve-SafeDirectory (Join-Path $WindowsRoot 'docs/guides') 'guides'
    Copy-Item -Path (Join-Path $guides '*') -Destination $guideStage -Recurse -Force
    $manifestPath = Join-Path $payloadStage 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Fail 'staged payload manifest is missing'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $licenseIds = @(
        @($manifest.files) |
            ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'licenseID') { [string] $_.licenseID }
                elseif ($_.PSObject.Properties.Name -contains 'licenseId') { [string] $_.licenseId }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $licenseText = @(
        'Codex Windows 完整离线包第三方许可索引',
        '',
        '以下许可标识来自 payload-manifest.json；具体适用范围以各载荷附带文件和源码包为准：',
        ($licenseIds | ForEach-Object { "- $_" })
    ) -join "`n"
    $payloadLicenses = Join-Path $payload 'licenses'
    if (Test-Path -LiteralPath $payloadLicenses -PathType Container) {
        $safePayloadLicenses = Resolve-SafeDirectory $payloadLicenses 'payload licenses'
        Copy-Item -Path (Join-Path $safePayloadLicenses '*') -Destination $licenseStage `
            -Recurse -Force
    }
    Write-Utf8NoBom (Join-Path $licenseStage 'THIRD-PARTY-LICENSES.zh-CN.txt') (
        $licenseText + "`n")

    & $SbomScript -StageRoot $stage -Output (Join-Path $temporaryDist 'SBOM.spdx.json')
    if ($LASTEXITCODE -ne 0) { Fail 'SPDX SBOM generation failed' }
    Copy-Item -LiteralPath $manifestPath -Destination (
        Join-Path $temporaryDist 'payload-manifest.json')

    $isccArguments = @(
        "/DStageRoot=$stage",
        "/DOutputDir=$temporaryDist",
        '/DAppVersion=1.0.0',
        $InstallerSource
    )
    $innoOutput = @(& $IsccPath @isccArguments)
    $innoExitCode = $LASTEXITCODE
    $innoOutput | Write-Output
    if ($innoExitCode -ne 0) {
        Fail "Inno compilation failed with exit code $innoExitCode"
    }
    if ((-not $FixtureMode -or $VerifyInnoRuntimeVersion) -and
        @($innoOutput | Where-Object { [string] $_ -ceq $ExpectedInnoRuntimeBanner }).Count -eq 0) {
        Fail "ISCC must report exact runtime banner '$ExpectedInnoRuntimeBanner'"
    }
    $exe = Join-Path $temporaryDist $ExpectedExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Fail "Inno compiler did not produce $ExpectedExe"
    }
    $report = @'
# Codex Windows 完整离线安装包发布说明

签名状态：未签名（首个 Windows 测试版）
SmartScreen：首次运行可能出现“Windows 已保护你的电脑”
校验方式：对照 SHA256SUMS.txt

本发布物只支持 Windows 10 build 17763 及以上 x64 系统。
'@
    Write-Utf8NoBom (Join-Path $temporaryDist 'RELEASE-REPORT.zh-CN.md') ($report + "`n")
    $testResults = Join-Path $temporaryDist 'test-results'
    New-Item -ItemType Directory -Path $testResults | Out-Null
    $resultDocument = [ordered]@{
        schemaVersion = 1
        fixture = [bool] $FixtureMode
        target = 'win-x64'
        selfContained = $true
        payloadValidation = if ($FixtureMode) { 'fixture' } else { 'strict-signatures' }
        innoVersion = $InnoVersion
    }
    Write-Utf8NoBom (Join-Path $testResults 'release-build.json') (
        ($resultDocument | ConvertTo-Json -Depth 4) + "`n")
    $hashNames = @(
        $ExpectedExe,
        'payload-manifest.json',
        'SBOM.spdx.json',
        'RELEASE-REPORT.zh-CN.md'
    )
    $hashLines = @(
        $hashNames |
            Sort-Object |
            ForEach-Object {
                $hash = (Get-FileHash -LiteralPath (Join-Path $temporaryDist $_) `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
                "$hash  $_"
            }
    )
    Write-Utf8NoBom (Join-Path $temporaryDist 'SHA256SUMS.txt') (
        ($hashLines -join "`n") + "`n")

    if (Test-Path -LiteralPath $output) {
        $backupDist = Join-Path $outputParent (
            '.' + (Split-Path -Leaf $output) + '-' + [Guid]::NewGuid().ToString('N') + '.bak')
        Move-Item -LiteralPath $output -Destination $backupDist
    }
    Move-Item -LiteralPath $temporaryDist -Destination $output
    if ($null -ne $backupDist) {
        Remove-Item -LiteralPath $backupDist -Recurse -Force
        $backupDist = $null
    }
    Write-Host "build-installer: PASS -> $output"
} catch {
    if ($null -ne $backupDist -and (Test-Path -LiteralPath $backupDist) -and
        -not (Test-Path -LiteralPath $output)) {
        Move-Item -LiteralPath $backupDist -Destination $output
        $backupDist = $null
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temporaryDist) {
        Remove-Item -LiteralPath $temporaryDist -Recurse -Force
    }
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
