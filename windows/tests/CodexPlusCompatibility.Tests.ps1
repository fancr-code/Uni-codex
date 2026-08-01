#Requires -Version 5.1
<#
.SYNOPSIS
Runs the Codex++ v1.2.43 cross-provider compatibility contract.

.DESCRIPTION
With no parameters, this script runs a hermetic fixture build. SourceArchive
mode reproduces the unpatched regression or applies the shared patch and runs
the targeted Rust fixture. BuiltRoot mode performs Windows-only inspection of
the real NSIS payload; fixture output is never accepted as a release artifact.
#>
[CmdletBinding(DefaultParameterSetName = 'Contract')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Source')]
    [string] $SourceArchive,

    [Parameter(Mandatory, ParameterSetName = 'Source')]
    [string] $Patch,

    [Parameter(ParameterSetName = 'Source')]
    [switch] $ExpectUnpatchedFailure,

    [Parameter(Mandatory, ParameterSetName = 'Built')]
    [string] $BuiltRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Builder = Join-Path (Join-Path $WindowsRoot 'scripts') `
    'build-codex-plus-compatibility-payload.ps1'
$PayloadLock = Join-Path (Join-Path $WindowsRoot 'vendor') 'payload-lock.json'
$SharedFixture = Join-Path (Join-Path (Join-Path $RepositoryRoot 'tests') 'fixtures') `
    'codex-plus/cross_provider_content.rs'
$ExpectedTag = 'v1.2.43'
$ExpectedVersion = '1.2.43+codexkit.1'
$ExpectedRevision = 'cross-provider-content-v1'
$ExpectedPatchSha256 = `
    '5a411571c2c950a3ce5f8b1ed3a72a0f42bb4c4de2f9ea3ba5de8d767e14f739'
$ExecutableMetadataMagic = 'CODEXKIT-EXECUTABLE-METADATA-V1:'
$SetupProvenanceSchema = 'CODEXKIT-SETUP-PROVENANCE-V1'
$SetupProvenanceMagic = "$SetupProvenanceSchema`:"
$ExpectedInstallDir = '$LOCALAPPDATA\Programs\Codex++'
$SetupName = 'CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe'
$SourceName = 'CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "codex-plus-compatibility-$([Guid]::NewGuid().ToString('N'))"

function Fail([string] $Message) {
    throw "CodexPlusCompatibility.Tests: $Message"
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { Fail $Message }
}

function Assert-Contains([string] $Text, [string] $Expected, [string] $Message) {
    if (-not $Text.Contains($Expected)) { Fail $Message }
}

function Assert-PerUserNsiContract([string] $Text, [string] $Description) {
    $userLevelCount = [regex]::Matches(
        $Text, '(?m)^[ \t]*RequestExecutionLevel[ \t]+user[ \t]*\r?$').Count
    Assert-True ($userLevelCount -eq 1) `
        "$Description must contain exactly one RequestExecutionLevel user"
    Assert-True ($Text -notmatch `
        '(?im)^[ \t]*RequestExecutionLevel[ \t]+(admin|highest)[ \t]*\r?$') `
        "$Description still requests elevation"
    $installDirCount = [regex]::Matches(
        $Text,
        '(?m)^[ \t]*InstallDir[ \t]+"\$LOCALAPPDATA\\Programs\\Codex\+\+"[ \t]*\r?$'
    ).Count
    Assert-True ($installDirCount -eq 1) `
        "$Description install directory is not the fixed per-user directory"
    $shellContextCount = [regex]::Matches(
        $Text, '(?m)^[ \t]*SetShellVarContext[ \t]+current[ \t]*\r?$').Count
    Assert-True ($shellContextCount -eq 2) `
        "$Description must set the current-user shell context in both sections"
    foreach ($sectionName in @('Install', 'Uninstall')) {
        $sectionPattern = '(?m)^[ \t]*' +
            [regex]::Escape("Section `"$sectionName`"") +
            '[ \t]*\r?\n[ \t]*SetShellVarContext[ \t]+current[ \t]*\r?$'
        Assert-True ([regex]::Matches($Text, $sectionPattern).Count -eq 1) `
            "$Description must set current-user shell context inside $sectionName"
    }
    Assert-True ($Text -notmatch '(?i)\bHKLM\b|\$PROGRAMFILES(?:32|64)?\b|SetShellVarContext[ \t]+all\b') `
        "$Description contains a machine-wide installer primitive"
    foreach ($line in @(
        'InstallDirRegKey HKCU "Software\Codex++" "InstallDir"',
        'WriteRegStr HKCU "Software\Codex++" "InstallDir" "$INSTDIR"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayName" "Codex++"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayVersion" "${VERSION}"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "InstallLocation" "$INSTDIR"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "UninstallString" "$INSTDIR\uninstall.exe"',
        'DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++"',
        'DeleteRegKey HKCU "Software\Codex++"',
        'CreateShortcut "$DESKTOP\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"',
        'CreateShortcut "$DESKTOP\Codex++ 管理工具.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"',
        'CreateShortcut "$SMPROGRAMS\Codex++\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"',
        'CreateShortcut "$SMPROGRAMS\Codex++\Codex++ 管理工具.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"',
        'CreateShortcut "$SMPROGRAMS\Codex++\卸载 Codex++.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"'
    )) {
        Assert-Contains $Text $line "$Description omits current-user contract line: $line"
    }
}

function Assert-RawCreateProcessContract([string] $Path, [string] $Description) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $manifestText = [Text.Encoding]::UTF8.GetString($bytes) + "`n" +
        [Text.Encoding]::Unicode.GetString($bytes)
    $executionTags = @([regex]::Matches(
        $manifestText, '(?is)<requestedExecutionLevel\b[^>]*>') |
        ForEach-Object { $_.Value })
    Assert-True ($executionTags.Count -gt 0) `
        "$Description does not embed a requestedExecutionLevel manifest"
    foreach ($tag in $executionTags) {
        Assert-True ($tag -match '(?is)\blevel\s*=\s*["'']asInvoker["'']') `
            "$Description execution manifest is not asInvoker"
        Assert-True ($tag -match '(?is)\buiAccess\s*=\s*["'']false["'']') `
            "$Description execution manifest does not set uiAccess=false"
    }
    Assert-True ($manifestText -notmatch '(?i)requireAdministrator|highestAvailable') `
        "$Description embeds an elevation-requiring execution manifest"
}

function Find-BytePatternOffsets([byte[]] $Data, [byte[]] $Pattern) {
    $offsets = New-Object 'System.Collections.Generic.List[int]'
    if ($Pattern.Length -eq 0 -or $Data.Length -lt $Pattern.Length) {
        return $offsets.ToArray()
    }
    $singleByteEncoding = [Text.Encoding]::GetEncoding(28591)
    $dataText = $singleByteEncoding.GetString($Data)
    $patternText = $singleByteEncoding.GetString($Pattern)
    $start = 0
    while ($start -le $dataText.Length - $patternText.Length) {
        $index = $dataText.IndexOf(
            $patternText, $start, [StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        $offsets.Add($index)
        $start = $index + 1
    }
    return $offsets.ToArray()
}

function Get-SetupProvenance([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $markerBytes = [Text.Encoding]::UTF8.GetBytes($SetupProvenanceMagic)
    $offsets = @(Find-BytePatternOffsets $bytes $markerBytes)
    Assert-True ($offsets.Count -eq 1) `
        "setup must contain exactly one $SetupProvenanceMagic marker"
    $markerOffset = $offsets[0]
    Assert-True ($markerOffset -gt 0 -and $bytes[$markerOffset - 1] -eq 10) `
        'setup provenance marker is not a line-aligned PE overlay'
    Assert-True ($bytes.Length -gt ($markerOffset + $markerBytes.Length + 2) -and
        $bytes[$bytes.Length - 1] -eq 10) `
        'setup provenance overlay is not the final newline-terminated record'
    $jsonStart = $markerOffset + $markerBytes.Length
    $jsonLength = $bytes.Length - $jsonStart - 1
    $jsonBytes = New-Object byte[] $jsonLength
    [Array]::Copy($bytes, $jsonStart, $jsonBytes, 0, $jsonLength)
    Assert-True (-not ($jsonBytes -contains 10) -and -not ($jsonBytes -contains 13)) `
        'setup provenance JSON must be exactly one line'
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $json = $strictUtf8.GetString($jsonBytes)
        return $json | ConvertFrom-Json
    } catch {
        Fail "setup provenance JSON is invalid: $($_.Exception.Message)"
    }
}

function Assert-ExactJsonProperties(
    [object] $Value,
    [string[]] $Expected,
    [string] $Description
) {
    $actual = @($Value.PSObject.Properties |
        ForEach-Object { $_.Name } | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    Assert-True (($actual -join ',') -ceq ($wanted -join ',')) `
        "$Description properties are not the fixed schema"
}

function Assert-SetupProvenanceContract(
    [string] $Path,
    [object] $Manifest,
    [bool] $FixtureOnly,
    [string] $Description
) {
    $record = Get-SetupProvenance $Path
    Assert-ExactJsonProperties $record @(
        'schema',
        'schemaVersion',
        'setupFileName',
        'upstreamTag',
        'patchSha256',
        'payloadVersion',
        'compatibilityRevision',
        'architecture',
        'perUser',
        'executionLevel',
        'installDir',
        'registryHive',
        'shortcutScope',
        'requiresElevation',
        'rawCreateProcessCompatible',
        'fixtureOnly',
        'executables'
    ) "$Description top-level provenance"
    Assert-True ($record.schema -ceq $SetupProvenanceSchema -and
        $record.schemaVersion -eq 1) "$Description schema is wrong"
    Assert-True ($record.setupFileName -ceq $SetupName) `
        "$Description setup identity is wrong"
    Assert-True ($record.upstreamTag -ceq $ExpectedTag -and
        $record.patchSha256 -ceq $ExpectedPatchSha256) `
        "$Description reviewed source identity is wrong"
    Assert-True ($record.payloadVersion -ceq $ExpectedVersion -and
        $record.compatibilityRevision -ceq $ExpectedRevision -and
        $record.architecture -ceq 'x64') "$Description payload identity is wrong"
    Assert-True ($record.perUser -eq $true -and
        $record.executionLevel -ceq 'user' -and
        $record.installDir -ceq $ExpectedInstallDir -and
        $record.registryHive -ceq 'HKCU' -and
        $record.shortcutScope -ceq 'currentUser' -and
        $record.requiresElevation -eq $false -and
        $record.rawCreateProcessCompatible -eq $true) `
        "$Description per-user launch contract is wrong"
    Assert-True ($record.fixtureOnly -eq $FixtureOnly) `
        "$Description fixtureOnly value is wrong"
    Assert-True ($Manifest.setupProvenanceSchema -ceq $SetupProvenanceSchema -and
        $Manifest.setupProvenanceMagic -ceq $SetupProvenanceMagic) `
        "$Description source manifest setup provenance identity is wrong"
    $manifestExecutables = @($Manifest.executables)
    $recordExecutables = @($record.executables)
    Assert-True ($manifestExecutables.Count -eq 2 -and
        $recordExecutables.Count -eq 2) `
        "$Description must describe exactly two executables"
    foreach ($entry in $recordExecutables) {
        Assert-ExactJsonProperties $entry @(
            'name',
            'component',
            'sha256',
            'payloadVersion',
            'compatibilityRevision',
            'architecture',
            'metadataMagic'
        ) "$Description executable provenance"
        Assert-True ($entry.sha256 -cmatch '^[0-9a-f]{64}$') `
            "$Description executable SHA-256 is malformed"
        $manifestEntry = @($manifestExecutables | Where-Object {
            $_.component -ceq $entry.component
        })
        Assert-True ($manifestEntry.Count -eq 1) `
            "$Description executable component is not unique"
        Assert-True ($entry.name -ceq $manifestEntry[0].fileName -and
            $entry.sha256 -ceq $manifestEntry[0].sha256 -and
            $entry.payloadVersion -ceq $manifestEntry[0].payloadVersion -and
            $entry.compatibilityRevision -ceq
                $manifestEntry[0].compatibilityRevision -and
            $entry.architecture -ceq $manifestEntry[0].architecture -and
            $entry.metadataMagic -ceq $manifestEntry[0].metadataMagic) `
            "$Description executable record differs from source manifest"
    }
    return $record
}

function Assert-ThrowsLike(
    [scriptblock] $Action,
    [string] $Pattern,
    [string] $Message
) {
    try {
        & $Action
        Fail "$Message (no exception)"
    } catch {
        if ($_.Exception.Message -notlike $Pattern) {
            Fail "$Message (actual=$($_.Exception.Message), expected=$Pattern)"
        }
    }
}

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Native(
    [string] $Command,
    [string[]] $Arguments,
    [string] $WorkingDirectory
) {
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            Fail "native command failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Get-TarCommand {
    $command = Get-Command 'tar' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { Fail 'tar is required' }
    return $command.Source
}

function Expand-SourceArchive([string] $Archive, [string] $Destination) {
    $tar = Get-TarCommand
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Invoke-Native $tar @('-xzf', $Archive, '-C', $Destination) $RepositoryRoot
    $roots = @(Get-ChildItem -LiteralPath $Destination -Directory -Force)
    Assert-True ($roots.Count -eq 1) 'source archive must have exactly one top-level directory'
    Assert-True ($roots[0].Name -ceq 'CodexPlusPlus-1.2.43') `
        'source archive top-level directory is not CodexPlusPlus-1.2.43'
    return $roots[0].FullName
}

function Assert-PatchContract([string] $PatchPath) {
    Assert-True (Test-Path -LiteralPath $PatchPath -PathType Leaf) `
        "shared patch is missing: $PatchPath"
    Assert-True (Test-Path -LiteralPath $SharedFixture -PathType Leaf) `
        "shared Rust fixture is missing: $SharedFixture"
    $actualPatchSha = (Get-FileHash -LiteralPath $PatchPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actualPatchSha -ceq $ExpectedPatchSha256) `
        "shared patch SHA-256 is not the reviewed digest: $actualPatchSha"
    $patchText = Get-Content -LiteralPath $PatchPath -Raw
    foreach ($needle in @(
        'normalize_chat_message_contents',
        'content_compatibility',
        'repairedMessageCount',
        'originalTypes',
        'compatibility_notice',
        'take_content_compatibility_notice',
        'A missing notice must never interrupt the manager.'
    )) {
        Assert-Contains $patchText $needle "shared patch omits $needle"
    }
    $fixtureText = Get-Content -LiteralPath $SharedFixture -Raw
    foreach ($needle in @(
        'content.is_string() || content.is_array()',
        '"content": null',
        '"content": true',
        '"content": 42',
        '"type": "input_image"',
        '"type": "function_call"',
        '"type": "function_call_output"',
        'PRIVATE-CONTENT-MUST-NOT-BE-LOGGED',
        'assert!(!log_text.contains(private_marker))'
    )) {
        Assert-Contains $fixtureText $needle "shared Rust fixture omits $needle"
    }
}

function Assert-ExactPayloadChecksums([string] $Root) {
    $expectedNames = @('CODEXKIT-PATCH.md', $SetupName, $SourceName)
    $remaining = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::Ordinal)
    foreach ($name in $expectedNames) { [void] $remaining.Add($name) }
    $checksumPath = Join-Path $Root 'SHA256SUMS.txt'
    $lines = @(Get-Content -LiteralPath $checksumPath)
    Assert-True ($lines.Count -eq 3) `
        'SHA256SUMS must contain exactly setup, source, and provenance'
    foreach ($line in $lines) {
        Assert-True ($line -cmatch '^[0-9a-f]{64}  [^/\\]+$') `
            "invalid SHA256SUMS line: $line"
        $parts = $line -split '  ', 2
        Assert-True ($remaining.Remove($parts[1])) `
            "SHA256SUMS contains an unexpected or duplicate entry: $($parts[1])"
        $actual = (Get-FileHash -LiteralPath (Join-Path $Root $parts[1]) `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -ceq $parts[0]) "stale checksum for $($parts[1])"
    }
    Assert-True ($remaining.Count -eq 0) 'SHA256SUMS omitted a required payload'
}

function Get-ExecutableMetadata([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $length = [Math]::Min([long] 16384, $stream.Length)
        $stream.Position = $stream.Length - $length
        $bytes = New-Object byte[] ([int] $length)
        $read = $stream.Read($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    $tail = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
    $index = $tail.LastIndexOf($ExecutableMetadataMagic, [StringComparison]::Ordinal)
    Assert-True ($index -ge 0) "executable metadata marker is missing: $Path"
    $jsonStart = $index + $ExecutableMetadataMagic.Length
    $jsonEnd = $tail.IndexOf("`n", $jsonStart, [StringComparison]::Ordinal)
    Assert-True ($jsonEnd -gt $jsonStart) "executable metadata is truncated: $Path"
    return $tail.Substring($jsonStart, $jsonEnd - $jsonStart) | ConvertFrom-Json
}

function New-UnpatchedRegressionFixture([string] $SourceRoot) {
    $testPath = Join-Path (Join-Path (Join-Path $SourceRoot 'crates') `
        'codex-plus-core/tests') 'codexkit_unpatched_regression.rs'
    Write-Utf8NoBom $testPath @'
use codex_plus_core::protocol_proxy::responses_to_chat_completions;
use serde_json::{Value, json};

fn value_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[test]
fn unpatched_object_content_reproduces_cross_provider_regression() {
    let converted = responses_to_chat_completions(json!({
        "model": "gpt-5.6",
        "input": [{
            "type": "message",
            "role": "user",
            "content": {"type": "input_text", "text": "fixture"}
        }]
    })).unwrap();
    for (index, message) in converted["messages"].as_array().unwrap().iter().enumerate() {
        let content = &message["content"];
        assert!(
            content.is_string() || content.is_array(),
            "unpatched-regression: messages[{index}].content type {}",
            value_type(content)
        );
    }
}
'@
    return $testPath
}

function Invoke-SourceMode {
    $archiveFull = [IO.Path]::GetFullPath($SourceArchive)
    $patchFull = [IO.Path]::GetFullPath($Patch)
    Assert-True (Test-Path -LiteralPath $archiveFull -PathType Leaf) `
        "source archive is missing: $archiveFull"
    Assert-PatchContract $patchFull
    $sourceRoot = Expand-SourceArchive $archiveFull (Join-Path $TestRoot 'source')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CODEXKIT-PATCH.md'))) `
        'SourceArchive mode requires the unpatched upstream archive'

    $git = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $git) { Fail 'git is required for patch dry-run' }
    Invoke-Native $git.Source @(
        '-C', $sourceRoot, 'apply', '--check', '--unidiff-zero',
        '--whitespace=nowarn', $patchFull
    ) $RepositoryRoot

    $cargo = Get-Command 'cargo' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $cargo) { Fail 'cargo is required for source regression tests' }

    if ($ExpectUnpatchedFailure) {
        [void] (New-UnpatchedRegressionFixture $sourceRoot)
        Push-Location $sourceRoot
        try {
            $output = @(& $cargo.Source test -p codex-plus-core `
                --test codexkit_unpatched_regression -- --nocapture 2>&1)
            $status = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        Assert-True ($status -ne 0) `
            'unpatched source unexpectedly satisfied the content invariant'
        Assert-True (($output -join "`n") -like '*unpatched-regression:*content type object*') `
            'unpatched failure was not the object-content regression'
        Write-Output 'unpatched-regression: reproduced'
        return
    }

    Invoke-Native $git.Source @(
        '-C', $sourceRoot, 'apply', '--unidiff-zero', '--whitespace=nowarn',
        $patchFull
    ) $RepositoryRoot
    Copy-Item -LiteralPath $SharedFixture -Destination (
        Join-Path (Join-Path (Join-Path $sourceRoot 'crates') 'codex-plus-core/tests') `
            'codexkit_cross_provider_content.rs')
    Invoke-Native $cargo.Source @(
        'test', '-p', 'codex-plus-core', '--test', 'codexkit_cross_provider_content'
    ) $sourceRoot
    Write-Output 'CodexPlusCompatibility.Tests: patched-source PASS'
}

function New-FixtureSourceArchive(
    [string] $ArchivePath,
    [ValidateSet(
        'Valid',
        'ExecutionLevelDrift',
        'ExecutionLevelMissing',
        'ExecutionLevelDuplicate',
        'ProgramFilesDrift',
        'HklmDrift',
        'AllUsersDrift'
    )]
    [string] $NsiVariant = 'Valid'
) {
    $fixtureParent = Join-Path $TestRoot 'fixture-source'
    $root = Join-Path $fixtureParent 'CodexPlusPlus-1.2.43'
    $manager = Join-Path (Join-Path (Join-Path $root 'apps') 'codex-plus-manager') ''
    $managerTauri = Join-Path (Join-Path $manager 'src-tauri') 'src'
    $tests = Join-Path (Join-Path (Join-Path $root 'crates') 'codex-plus-core') 'tests'
    $installer = Join-Path (Join-Path (Join-Path $root 'scripts') 'installer') 'windows'
    New-Item -ItemType Directory -Path $manager, $managerTauri, $tests, $installer `
        -Force | Out-Null
    Write-Utf8NoBom (Join-Path $root 'Cargo.toml') "[workspace]`nmembers = []`n"
    Write-Utf8NoBom (Join-Path $root 'LICENSE') "AGPL-3.0-only fixture`n"
    Write-Utf8NoBom (Join-Path $managerTauri 'lib.rs') @'
pub fn run() {
        .invoke_handler(tauri::generate_handler![
            commands::backend_version,
            commands::startup_options,
            commands::load_overview,
            commands::launch_codex_plus,
            commands::restart_codex_plus,
}
'@
    Write-Utf8NoBom (Join-Path $manager 'package.json') @'
{"name":"codex-plus-manager","version":"1.2.43","private":true,"scripts":{}}
'@
    Write-Utf8NoBom (Join-Path $manager 'package-lock.json') @'
{"name":"codex-plus-manager","version":"1.2.43","lockfileVersion":3,"packages":{}}
'@
    $nsiText = @'
Unicode true
!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!define ROOT "..\..\.."
OutFile "${ROOT}\dist\windows\CodexPlusPlus-${VERSION}-windows-x64-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\Codex++"
InstallDirRegKey HKCU "Software\Codex++" "InstallDir"
RequestExecutionLevel admin
Section "Install"
  SetOutPath "$INSTDIR"
  File "${ROOT}\dist\windows\app\codex-plus-plus.exe"
  File "${ROOT}\dist\windows\app\codex-plus-plus-manager.exe"
  CreateShortcut "$DESKTOP\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"
  CreateShortcut "$DESKTOP\Codex++ 管理工具.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"
  CreateDirectory "$SMPROGRAMS\Codex++"
  CreateShortcut "$SMPROGRAMS\Codex++\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"
  CreateShortcut "$SMPROGRAMS\Codex++\Codex++ 管理工具.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"
  CreateShortcut "$SMPROGRAMS\Codex++\卸载 Codex++.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\Codex++" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayName" "Codex++"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "Publisher" "BigPizzaV3"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayIcon" "$INSTDIR\codex-plus-plus-manager.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "UninstallString" "$INSTDIR\uninstall.exe"
SectionEnd
Section "Uninstall"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++"
  DeleteRegKey HKCU "Software\Codex++"
SectionEnd
'@
    $fixtureNewline = if ($nsiText.Contains("`r`n")) { "`r`n" } else { "`n" }
    switch ($NsiVariant) {
        'ExecutionLevelDrift' {
            $nsiText = $nsiText.Replace(
                'RequestExecutionLevel admin', 'RequestExecutionLevel highest')
        }
        'ExecutionLevelMissing' {
            $nsiText = $nsiText -replace `
                '(?m)^[ \t]*RequestExecutionLevel[ \t]+admin[ \t]*\r?\n', ''
        }
        'ExecutionLevelDuplicate' {
            $nsiText = $nsiText.Replace(
                'RequestExecutionLevel admin',
                "RequestExecutionLevel admin${fixtureNewline}RequestExecutionLevel admin")
        }
        'ProgramFilesDrift' {
            $nsiText = $nsiText.Replace(
                'InstallDir "$LOCALAPPDATA\Programs\Codex++"',
                'InstallDir "$PROGRAMFILES64\Codex++"')
        }
        'HklmDrift' {
            $nsiText = $nsiText.Replace(' HKCU ', ' HKLM ')
        }
        'AllUsersDrift' {
            $nsiText = $nsiText.Replace(
                'RequestExecutionLevel admin',
                "RequestExecutionLevel admin${fixtureNewline}SetShellVarContext all")
        }
    }
    Write-Utf8NoBom (Join-Path $installer 'CodexPlusPlus.nsi') $nsiText
    $tar = Get-TarCommand
    Invoke-Native $tar @('-czf', $ArchivePath, 'CodexPlusPlus-1.2.43') $fixtureParent
}

function New-ToolShim([string] $Path, [string] $Body) {
    Write-Utf8NoBom $Path $Body
}

function New-FixtureToolRoot([string] $ToolRoot) {
    New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
    New-ToolShim (Join-Path $ToolRoot 'git.ps1') @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
Add-Content -LiteralPath $env:CODEXKIT_TEST_CAPTURE -Value ("git`t" + ($Rest -join ' '))
if ($env:CODEXKIT_TEST_FAIL_TOOL -ceq 'git') { exit 97 }
$sourceIndex = [Array]::IndexOf($Rest, '-C')
if ($sourceIndex -lt 0 -or $sourceIndex + 1 -ge $Rest.Count) { exit 91 }
$sourceRoot = $Rest[$sourceIndex + 1]
$patchPath = $Rest[$Rest.Count - 1]
$patchSha = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($patchSha -cne '5a411571c2c950a3ce5f8b1ed3a72a0f42bb4c4de2f9ea3ba5de8d767e14f739') {
    exit 92
}
$patchText = Get-Content -LiteralPath $patchPath -Raw
$startMarker = 'diff --git a/apps/codex-plus-manager/src-tauri/src/lib.rs b/apps/codex-plus-manager/src-tauri/src/lib.rs'
$endMarker = 'diff --git a/apps/codex-plus-manager/src/App.tsx b/apps/codex-plus-manager/src/App.tsx'
$start = $patchText.IndexOf($startMarker, [StringComparison]::Ordinal)
$end = $patchText.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
if ($start -lt 0 -or $end -le $start) { exit 93 }
$subsetPath = Join-Path $sourceRoot '.codexkit-fixture-subset.patch'
[IO.File]::WriteAllText($subsetPath, $patchText.Substring($start, $end - $start),
    (New-Object Text.UTF8Encoding($false)))
try {
    $realGit = Get-Command 'git' -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $forward = @('-C', $sourceRoot, 'apply')
    if ($Rest -contains '--check') { $forward += '--check' }
    $forward += @('--unidiff-zero', '--whitespace=nowarn', $subsetPath)
    & $realGit.Source @forward
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if (Test-Path -LiteralPath $subsetPath) {
        Remove-Item -LiteralPath $subsetPath -Force
    }
}
exit 0
'@
    New-ToolShim (Join-Path $ToolRoot 'npm.ps1') @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
Add-Content -LiteralPath $env:CODEXKIT_TEST_CAPTURE -Value ("npm`t" + ($Rest -join ' '))
if ($env:CODEXKIT_TEST_FAIL_TOOL -ceq 'npm') { exit 97 }
exit 0
'@
    New-ToolShim (Join-Path $ToolRoot 'cargo.ps1') @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
Add-Content -LiteralPath $env:CODEXKIT_TEST_CAPTURE -Value ("cargo`t" + ($Rest -join ' '))
if ($env:CODEXKIT_TEST_FAIL_TOOL -ceq 'cargo') { exit 97 }
$cargoCommand = $Rest -join ' '
if ($cargoCommand -in @(
        'test --workspace -- --test-threads=1',
        'build --release'
    )) {
    $nsiPath = Join-Path (Get-Location) `
        'scripts/installer/windows/CodexPlusPlus.nsi'
    $nsiText = Get-Content -LiteralPath $nsiPath -Raw
    if ([regex]::Matches(
            $nsiText,
            '(?m)^[ \t]*RequestExecutionLevel[ \t]+admin[ \t]*\r?$'
        ).Count -ne 1 -or
        $nsiText -match `
            '(?im)^[ \t]*RequestExecutionLevel[ \t]+user[ \t]*\r?$|^[ \t]*SetShellVarContext[ \t]+current[ \t]*\r?$') {
        Write-Error 'Rust validation and build must use the unmodified upstream admin NSIS source'
        exit 98
    }
}
if ($cargoCommand -ceq 'build --release') {
    $target = Join-Path (Join-Path (Get-Location) 'target') 'release'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($binary in @('codex-plus-plus.exe', 'codex-plus-plus-manager.exe')) {
        $backing = Join-Path $target ".$binary.cargo-output"
        [IO.File]::WriteAllBytes($backing, [byte[]](77, 90))
        New-Item -ItemType HardLink -Path (Join-Path $target $binary) `
            -Target $backing | Out-Null
    }
}
exit 0
'@
    New-ToolShim (Join-Path $ToolRoot 'makensis.ps1') @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
Add-Content -LiteralPath $env:CODEXKIT_TEST_CAPTURE -Value ("makensis`t" + ($Rest -join ' '))
$versionArgument = @($Rest | Where-Object { $_ -like '/DVERSION=*' })[0]
$version = $versionArgument.Substring('/DVERSION='.Length)
$nsiText = Get-Content -LiteralPath (Join-Path (Get-Location) 'CodexPlusPlus.nsi') -Raw
if ([regex]::Matches(
        $nsiText,
        '(?m)^[ \t]*RequestExecutionLevel[ \t]+user[ \t]*\r?$'
    ).Count -ne 1) { exit 96 }
if ([regex]::Matches(
        $nsiText,
        '(?m)^[ \t]*SetShellVarContext[ \t]+current[ \t]*\r?$'
    ).Count -ne 2) { exit 96 }
if (-not $nsiText.Contains('InstallDir "$LOCALAPPDATA\Programs\Codex++"') -or
    $nsiText -match '(?i)\bHKLM\b|\$PROGRAMFILES(?:32|64)?\b|SetShellVarContext[ \t]+all\b') {
    exit 96
}
$sourceRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) '..\..\..'))
$appRoot = Join-Path (Join-Path (Join-Path $sourceRoot 'dist') 'windows') 'app'
$metadataLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($binary in @('codex-plus-plus.exe', 'codex-plus-plus-manager.exe')) {
    $binaryPath = Join-Path $appRoot $binary
    $tail = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($binaryPath))
    $magic = 'CODEXKIT-EXECUTABLE-METADATA-V1:'
    $marker = $tail.LastIndexOf($magic, [StringComparison]::Ordinal)
    if ($marker -lt 0) { exit 94 }
    $start = $marker + $magic.Length
    $finish = $tail.IndexOf("`n", $start, [StringComparison]::Ordinal)
    if ($finish -le $start) { exit 95 }
    $metadata = $tail.Substring($start, $finish - $start) | ConvertFrom-Json
    $metadata | Add-Member -NotePropertyName sha256 -NotePropertyValue (
        (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant())
    $metadata | Add-Member -NotePropertyName name -NotePropertyValue $binary
    $metadataLines.Add(($metadata | ConvertTo-Json -Compress))
}
[IO.File]::WriteAllLines($env:CODEXKIT_TEST_METADATA_CAPTURE,
    $metadataLines.ToArray(), (New-Object Text.UTF8Encoding($false)))
if (-not [string]::IsNullOrWhiteSpace($env:CODEXKIT_TEST_RACE_OUTPUT)) {
    New-Item -ItemType Directory -Path $env:CODEXKIT_TEST_RACE_OUTPUT -Force |
        Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $env:CODEXKIT_TEST_RACE_OUTPUT 'competitor.txt'), 'competitor')
}
$realMakensis = Get-Command 'makensis.exe' -CommandType Application `
    -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $realMakensis) { exit 93 }
& $realMakensis.Source @Rest
exit $LASTEXITCODE
'@
}

function Invoke-ContractMode {
    Assert-True (Test-Path -LiteralPath $Builder -PathType Leaf) `
        "builder is missing: $Builder"
    $builderText = Get-Content -LiteralPath $Builder -Raw
    Assert-Contains $builderText `
        '5612fbdc60244b9080823b596745c6e88f8cc5fa1996015b143b44ba6e51dd7f' `
        'builder does not pin the reviewed upstream source archive SHA-256'
    Assert-Contains $builderText $ExpectedPatchSha256 `
        'builder does not pin the reviewed shared patch SHA-256'
    Assert-Contains $builderText '[IO.Directory]::Move' `
        'builder does not publish with an atomic directory rename'
    Assert-Contains $builderText 'fixtureOnly' `
        'builder does not explicitly mark fixture-only artifacts'
    Assert-Contains $builderText 'RequestExecutionLevel user' `
        'builder does not convert the fixed NSIS source to per-user execution'
    Assert-Contains $builderText 'rawCreateProcessCompatible' `
        'builder does not record the raw non-elevated launch contract'
    Assert-Contains $builderText $SetupProvenanceSchema `
        'builder does not append the fixed setup provenance schema'
    $defaultPatch = Join-Path (Join-Path (Join-Path $RepositoryRoot 'patches') `
        'CodexPlusPlus') 'v1.2.43-cross-provider-history.patch'
    Assert-PatchContract $defaultPatch
    $lock = Get-Content -LiteralPath $PayloadLock -Raw | ConvertFrom-Json
    Assert-True ($lock.codexPlusPlus.payloadVersion -ceq $ExpectedVersion) `
        'payload lock Codex++ version is stale'
    Assert-True ($lock.codexPlusPlus.architecture -ceq 'x64') `
        'payload lock Codex++ architecture is stale'
    Assert-True ($lock.codexPlusPlus.compatibilityRevision -ceq $ExpectedRevision) `
        'payload lock compatibility revision is stale'
    Assert-True (
        $lock.components.'codex-plus-plus-windows-x64'.relativePath -ceq
        "apps/$SetupName") 'payload lock setup path is stale'
    Assert-True (
        $lock.components.'codex-plus-plus-source'.relativePath -ceq
        "sources/$SourceName") 'payload lock source path is stale'

    $archive = Join-Path $TestRoot 'CodexPlusPlus-v1.2.43-source.tar.gz'
    $toolRoot = Join-Path $TestRoot 'tools'
    $output = Join-Path $TestRoot 'built'
    $capture = Join-Path $TestRoot 'commands.log'
    $metadataCapture = Join-Path $TestRoot 'executable-metadata.jsonl'
    New-FixtureSourceArchive $archive
    New-FixtureToolRoot $toolRoot
    Write-Utf8NoBom $capture ''
    $previousCapture = $env:CODEXKIT_TEST_CAPTURE
    $previousMetadataCapture = $env:CODEXKIT_TEST_METADATA_CAPTURE
    $env:CODEXKIT_TEST_CAPTURE = $capture
    $env:CODEXKIT_TEST_METADATA_CAPTURE = $metadataCapture
    try {
        & $Builder -Tag $ExpectedTag -Patch $defaultPatch -OutputRoot $output `
            -SourceArchive $archive -TestMode -ToolRoot $toolRoot
    } finally {
        $env:CODEXKIT_TEST_CAPTURE = $previousCapture
        $env:CODEXKIT_TEST_METADATA_CAPTURE = $previousMetadataCapture
    }

    foreach ($name in @($SetupName, $SourceName, 'CODEXKIT-PATCH.md', 'SHA256SUMS.txt')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $output $name) -PathType Leaf) `
            "fixture build omitted $name"
    }
    $published = @(Get-ChildItem -LiteralPath $output -File -Force)
    Assert-True ($published.Count -eq 4) 'fixture build published unexpected files'
    Assert-RawCreateProcessContract (Join-Path $output $SetupName) `
        'fixture setup'
    foreach ($uiCase in @(
        [pscustomobject]@{
            Name = 'uiaccess-true'
            Manifest = '<requestedExecutionLevel level="asInvoker" uiAccess="true" />'
        },
        [pscustomobject]@{
            Name = 'uiaccess-missing'
            Manifest = '<requestedExecutionLevel level="asInvoker" />'
        }
    )) {
        $uiPath = Join-Path $TestRoot "$($uiCase.Name).exe"
        Write-Utf8NoBom $uiPath "MZ$($uiCase.Manifest)"
        Assert-ThrowsLike {
            Assert-RawCreateProcessContract $uiPath $uiCase.Name
        } '*uiAccess=false*' `
            "raw launch validation accepted $($uiCase.Name)"
    }

    $provenance = Get-Content -LiteralPath (Join-Path $output 'CODEXKIT-PATCH.md') -Raw
    foreach ($needle in @(
        "Upstream tag: $ExpectedTag",
        "Payload version: $ExpectedVersion",
        "Compatibility revision: $ExpectedRevision",
        'Fixture only: True',
        'Per-user installer: True',
        'Execution level: user',
        "Install directory: $ExpectedInstallDir",
        'Registry hive: HKCU',
        'Shortcut scope: currentUser',
        'Requires elevation: False',
        'Raw CreateProcess compatible: True',
        "Setup provenance schema: $SetupProvenanceSchema",
        "Setup provenance marker: $SetupProvenanceMagic",
        'Patch SHA-256:',
        'Source archive SHA-256:'
    )) {
        Assert-Contains $provenance $needle "provenance omits $needle"
    }
    Assert-True ($provenance -notmatch '(?i)(api[_ -]?key|sk-[A-Za-z0-9]{8,})') `
        'provenance contains secret-shaped text'

    Assert-ExactPayloadChecksums $output
    $extraChecksumRoot = Join-Path $TestRoot 'checksum-extra'
    Copy-Item -LiteralPath $output -Destination $extraChecksumRoot -Recurse
    Add-Content -LiteralPath (Join-Path $extraChecksumRoot 'SHA256SUMS.txt') `
        -Value '0000000000000000000000000000000000000000000000000000000000000000  unexpected.bin'
    Assert-ThrowsLike {
        Assert-ExactPayloadChecksums $extraChecksumRoot
    } '*exactly setup, source, and provenance*' `
        'checksum validation accepted an extra entry'
    $missingChecksumRoot = Join-Path $TestRoot 'checksum-missing'
    Copy-Item -LiteralPath $output -Destination $missingChecksumRoot -Recurse
    $missingLines = @(Get-Content -LiteralPath (
        Join-Path $missingChecksumRoot 'SHA256SUMS.txt'))[0..1]
    Write-Utf8NoBom (Join-Path $missingChecksumRoot 'SHA256SUMS.txt') `
        (($missingLines -join "`n") + "`n")
    Assert-ThrowsLike {
        Assert-ExactPayloadChecksums $missingChecksumRoot
    } '*exactly setup, source, and provenance*' `
        'checksum validation accepted a missing entry'

    $extract = Join-Path $TestRoot 'published-source'
    $sourceRoot = Expand-SourceArchive (Join-Path $output $SourceName) $extract
    foreach ($relative in @(
        'LICENSE',
        'CODEXKIT-PATCH.md',
        'CODEXKIT-BUILD-MANIFEST.json',
        'patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf) `
            "source archive omitted $relative"
    }
    $manifest = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'CODEXKIT-BUILD-MANIFEST.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.upstreamTag -ceq $ExpectedTag) 'source manifest tag is wrong'
    Assert-True ($manifest.payloadVersion -ceq $ExpectedVersion) `
        'source manifest payload version is wrong'
    Assert-True ($manifest.compatibilityRevision -ceq $ExpectedRevision) `
        'source manifest compatibility revision is wrong'
    Assert-True ($manifest.architecture -ceq 'x64') 'source manifest architecture is wrong'
    Assert-True ($manifest.fixtureOnly -eq $true) `
        'fixture source manifest lacks fixtureOnly marker'
    Assert-True ($manifest.perUser -eq $true) `
        'fixture source manifest is not marked per-user'
    Assert-True ($manifest.executionLevel -ceq 'user') `
        'fixture source manifest execution level is not user'
    Assert-True ($manifest.installDir -ceq $ExpectedInstallDir) `
        'fixture source manifest install directory is wrong'
    Assert-True ($manifest.registryHive -ceq 'HKCU') `
        'fixture source manifest registry hive is not HKCU'
    Assert-True ($manifest.shortcutScope -ceq 'currentUser') `
        'fixture source manifest shortcut scope is not currentUser'
    Assert-True ($manifest.requiresElevation -eq $false) `
        'fixture source manifest requires elevation'
    Assert-True ($manifest.rawCreateProcessCompatible -eq $true) `
        'fixture source manifest does not certify raw CreateProcess launch'
    Assert-True ($manifest.setupProvenanceSchema -ceq $SetupProvenanceSchema -and
        $manifest.setupProvenanceMagic -ceq $SetupProvenanceMagic) `
        'fixture source manifest setup provenance identity is wrong'
    Assert-True ($manifest.patchSha256 -ceq $ExpectedPatchSha256) `
        'fixture source manifest patch SHA-256 is wrong'
    $fixtureManifestExecutables = @($manifest.executables)
    Assert-True ($fixtureManifestExecutables.Count -eq 2) `
        'fixture source manifest must describe two executables'
    foreach ($entry in $fixtureManifestExecutables) {
        Assert-True ($entry.payloadVersion -ceq $ExpectedVersion) `
            'fixture source manifest executable payload version is wrong'
        Assert-True ($entry.compatibilityRevision -ceq $ExpectedRevision) `
            'fixture source manifest executable compatibility revision is wrong'
        Assert-True ($entry.architecture -ceq 'x64') `
            'fixture source manifest executable architecture is wrong'
        Assert-True ($entry.metadataMagic -ceq $ExecutableMetadataMagic) `
            'fixture source manifest executable metadata magic is wrong'
        Assert-True ($entry.sha256 -cmatch '^[0-9a-f]{64}$') `
            'fixture source manifest executable SHA-256 is missing or malformed'
        Assert-Contains $provenance `
            "Executable SHA-256 ($($entry.component), $($entry.fileName)): $($entry.sha256)" `
            'fixture provenance omits an executable SHA-256'
    }
    $setupRecord = Assert-SetupProvenanceContract (
        Join-Path $output $SetupName) $manifest $true 'fixture setup'
    $missingOverlay = Join-Path $TestRoot 'setup-provenance-missing.exe'
    Write-Utf8NoBom $missingOverlay `
        'MZ<requestedExecutionLevel level="asInvoker" uiAccess="false" />'
    Assert-ThrowsLike {
        Get-SetupProvenance $missingOverlay
    } "*exactly one $SetupProvenanceMagic marker*" `
        'setup provenance parser accepted a missing marker'
    $graftedOverlay = Join-Path $TestRoot 'setup-provenance-grafted.exe'
    Write-Utf8NoBom $graftedOverlay (
        "MZ<requestedExecutionLevel level=`"asInvoker`" uiAccess=`"false`" />" +
        "`n$SetupProvenanceMagic{}`n")
    Assert-ThrowsLike {
        Assert-SetupProvenanceContract $graftedOverlay $manifest $true `
            'grafted setup'
    } '*properties are not the fixed schema*' `
        'setup provenance validator accepted an ordinary grafted marker'
    $duplicateOverlay = Join-Path $TestRoot 'setup-provenance-duplicate.exe'
    Copy-Item -LiteralPath (Join-Path $output $SetupName) `
        -Destination $duplicateOverlay
    [IO.File]::AppendAllText(
        $duplicateOverlay,
        "`n$SetupProvenanceMagic{}`n",
        (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsLike {
        Get-SetupProvenance $duplicateOverlay
    } "*exactly one $SetupProvenanceMagic marker*" `
        'setup provenance parser accepted duplicate markers'
    $tamperedOverlay = Join-Path $TestRoot 'setup-provenance-tampered.exe'
    Copy-Item -LiteralPath (Join-Path $output $SetupName) `
        -Destination $tamperedOverlay
    $tamperedBytes = [IO.File]::ReadAllBytes($tamperedOverlay)
    $markerOffset = @(Find-BytePatternOffsets $tamperedBytes (
        [Text.Encoding]::UTF8.GetBytes($SetupProvenanceMagic)))[0]
    $originalHash = [string] $manifest.executables[0].sha256
    $hashOffsets = @(Find-BytePatternOffsets $tamperedBytes (
        [Text.Encoding]::UTF8.GetBytes($originalHash)) | Where-Object {
            $_ -gt $markerOffset
        })
    Assert-True ($hashOffsets.Count -eq 1) `
        'fixture setup does not contain one replaceable provenance hash'
    $replacementHash = [Text.Encoding]::UTF8.GetBytes(('0' * 64))
    [Array]::Copy(
        $replacementHash, 0, $tamperedBytes, $hashOffsets[0],
        $replacementHash.Length)
    [IO.File]::WriteAllBytes($tamperedOverlay, $tamperedBytes)
    Assert-ThrowsLike {
        Assert-SetupProvenanceContract $tamperedOverlay $manifest $true `
            'tampered setup'
    } '*executable record differs from source manifest*' `
        'setup provenance validator accepted a tampered executable hash'
    $archivedPatch = Join-Path $sourceRoot `
        'patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch'
    Assert-True ((Get-FileHash -LiteralPath $archivedPatch -Algorithm SHA256).Hash -ceq
        $ExpectedPatchSha256.ToUpperInvariant()) `
        'source archive patch is not byte-identical to the shared patch'
    $archivedProvenance = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'CODEXKIT-PATCH.md') -Raw
    Assert-True ($archivedProvenance -ceq $provenance) `
        'published provenance differs from archived provenance'
    Assert-Contains $provenance "Patch SHA-256: $ExpectedPatchSha256" `
        'provenance does not contain the reviewed patch SHA-256'
    $archivedNsi = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'scripts/installer/windows/CodexPlusPlus.nsi') -Raw
    Assert-PerUserNsiContract $archivedNsi 'fixture archived NSIS source'
    foreach ($needle in @(
        'VIProductVersion "1.2.43.1"',
        'VIFileVersion "1.2.43.1"',
        'VIAddVersionKey "ProductVersion" "${VERSION}"',
        'VIAddVersionKey "FileVersion" "${VERSION}"',
        'VIAddVersionKey "CodexKitCompatibilityRevision" "cross-provider-content-v1"'
    )) {
        Assert-Contains $archivedNsi $needle "generated NSIS source omits $needle"
    }
    $patchedFixtureTarget = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'apps/codex-plus-manager/src-tauri/src/lib.rs') -Raw
    Assert-Contains $patchedFixtureTarget `
        'commands::take_content_compatibility_notice,' `
        'fixture did not apply a real shared-patch hunk'
    $capturedMetadata = @(Get-Content -LiteralPath $metadataCapture | ForEach-Object {
        $_ | ConvertFrom-Json
    })
    Assert-True ($capturedMetadata.Count -eq 2) `
        'fixture package did not inspect both embedded executable metadata records'
    Assert-True ((@($capturedMetadata.component | Sort-Object) -join ',') -ceq
        'launcher,manager') 'fixture executable component identities are wrong'
    foreach ($metadata in $capturedMetadata) {
        Assert-True ($metadata.payloadVersion -ceq $ExpectedVersion) `
            'fixture executable payload version is wrong'
        Assert-True ($metadata.compatibilityRevision -ceq $ExpectedRevision) `
            'fixture executable compatibility revision is wrong'
        Assert-True ($metadata.architecture -ceq 'x64') `
            'fixture executable architecture metadata is wrong'
        Assert-True ($metadata.fixtureOnly -eq $true) `
            'fixture executable metadata lacks fixtureOnly marker'
        $manifestEntry = @($fixtureManifestExecutables | Where-Object {
            $_.component -ceq $metadata.component
        })
        $setupEntry = @($setupRecord.executables | Where-Object {
            $_.component -ceq $metadata.component
        })
        Assert-True ($manifestEntry.Count -eq 1 -and $setupEntry.Count -eq 1 -and
            $metadata.name -ceq $manifestEntry[0].fileName -and
            $metadata.sha256 -ceq $manifestEntry[0].sha256 -and
            $metadata.sha256 -ceq $setupEntry[0].sha256) `
            'fixture packaged executable SHA-256 differs from provenance'
    }

    $commands = @(Get-Content -LiteralPath $capture)
    $required = @(
        "git`t-c core.autocrlf=false -c core.eol=lf -C * apply --check --unidiff-zero --whitespace=nowarn *",
        "git`t-c core.autocrlf=false -c core.eol=lf -C * apply --unidiff-zero --whitespace=nowarn *",
        "npm`t--prefix * ci",
        "npm`t--prefix * test",
        "npm`t--prefix * run check",
        "npm`t--prefix * run vite:build",
        "cargo`tfmt --all -- --check",
        "cargo`ttest --workspace -- --test-threads=1",
        "cargo`ttest -p codex-plus-core --test codexkit_cross_provider_content",
        "cargo`tbuild --release",
        "makensis`t/INPUTCHARSET UTF8 /DVERSION=$ExpectedVersion CodexPlusPlus.nsi"
    )
    $last = -1
    foreach ($pattern in $required) {
        $index = -1
        for ($i = $last + 1; $i -lt $commands.Count; $i++) {
            if ($commands[$i] -like $pattern) { $index = $i; break }
        }
        Assert-True ($index -gt $last) "missing or out-of-order build command: $pattern"
        $last = $index
    }

    $secondOutput = Join-Path $TestRoot 'built-repeated'
    $previousCapture = $env:CODEXKIT_TEST_CAPTURE
    $previousMetadataCapture = $env:CODEXKIT_TEST_METADATA_CAPTURE
    $env:CODEXKIT_TEST_CAPTURE = $capture
    $env:CODEXKIT_TEST_METADATA_CAPTURE = $metadataCapture
    try {
        & $Builder -Tag $ExpectedTag -Patch $defaultPatch -OutputRoot $secondOutput `
            -SourceArchive $archive -TestMode -ToolRoot $toolRoot
    } finally {
        $env:CODEXKIT_TEST_CAPTURE = $previousCapture
        $env:CODEXKIT_TEST_METADATA_CAPTURE = $previousMetadataCapture
    }
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $output $SourceName) `
            -Algorithm SHA256).Hash -ceq
        (Get-FileHash -LiteralPath (Join-Path $secondOutput $SourceName) `
            -Algorithm SHA256).Hash) `
        'repeated fixture builds produced different patched source archives'

    $wrongOutput = Join-Path $TestRoot 'wrong-tag'
    Assert-ThrowsLike {
        & $Builder -Tag 'v1.2.42' -Patch $defaultPatch -OutputRoot $wrongOutput `
            -SourceArchive $archive -TestMode -ToolRoot $toolRoot
    } '*only fixed tag v1.2.43 is allowed*' 'builder accepted an unpinned tag'
    $tamperedPatch = Join-Path $TestRoot 'tampered.patch'
    Write-Utf8NoBom $tamperedPatch ((Get-Content -LiteralPath $defaultPatch -Raw) + "`n")
    Assert-ThrowsLike {
        & $Builder -Tag $ExpectedTag -Patch $tamperedPatch -OutputRoot (
            Join-Path $TestRoot 'tampered-patch-output') -SourceArchive $archive `
            -TestMode -ToolRoot $toolRoot
    } '*byte-identical*shared patch*' 'builder accepted an unreviewed patch'

    $invalidNsiCases = @(
        [pscustomobject]@{
            Variant = 'ExecutionLevelDrift'
            Pattern = '*expected exactly one upstream RequestExecutionLevel admin*'
        },
        [pscustomobject]@{
            Variant = 'ExecutionLevelMissing'
            Pattern = '*expected exactly one upstream RequestExecutionLevel admin*'
        },
        [pscustomobject]@{
            Variant = 'ExecutionLevelDuplicate'
            Pattern = '*expected exactly one upstream RequestExecutionLevel admin*'
        },
        [pscustomobject]@{
            Variant = 'ProgramFilesDrift'
            Pattern = '*upstream per-user installer contract drifted*'
        },
        [pscustomobject]@{
            Variant = 'HklmDrift'
            Pattern = '*upstream per-user installer contract drifted*'
        },
        [pscustomobject]@{
            Variant = 'AllUsersDrift'
            Pattern = '*upstream per-user installer contract drifted*'
        }
    )
    foreach ($case in $invalidNsiCases) {
        $caseArchive = Join-Path $TestRoot "$($case.Variant).tar.gz"
        $caseOutput = Join-Path $TestRoot "nsi-$($case.Variant)"
        New-FixtureSourceArchive $caseArchive $case.Variant
        Assert-ThrowsLike {
            & $Builder -Tag $ExpectedTag -Patch $defaultPatch `
                -OutputRoot $caseOutput -SourceArchive $caseArchive `
                -TestMode -ToolRoot $toolRoot
        } $case.Pattern "builder accepted NSIS drift: $($case.Variant)"
        Assert-True (-not (Test-Path -LiteralPath $caseOutput)) `
            "NSIS drift published an output: $($case.Variant)"
    }

    foreach ($failedTool in @('git', 'npm', 'cargo')) {
        $faultOutput = Join-Path $TestRoot "fault-$failedTool"
        $previousFailedTool = $env:CODEXKIT_TEST_FAIL_TOOL
        $previousCapture = $env:CODEXKIT_TEST_CAPTURE
        $previousMetadataCapture = $env:CODEXKIT_TEST_METADATA_CAPTURE
        $env:CODEXKIT_TEST_FAIL_TOOL = $failedTool
        $env:CODEXKIT_TEST_CAPTURE = $capture
        $env:CODEXKIT_TEST_METADATA_CAPTURE = $metadataCapture
        try {
            Assert-ThrowsLike {
                & $Builder -Tag $ExpectedTag -Patch $defaultPatch `
                    -OutputRoot $faultOutput -SourceArchive $archive `
                    -TestMode -ToolRoot $toolRoot
            } '*failed with exit code 97*' `
                "$failedTool failure did not fail the fixture build"
        } finally {
            $env:CODEXKIT_TEST_FAIL_TOOL = $previousFailedTool
            $env:CODEXKIT_TEST_CAPTURE = $previousCapture
            $env:CODEXKIT_TEST_METADATA_CAPTURE = $previousMetadataCapture
        }
        Assert-True (-not (Test-Path -LiteralPath $faultOutput)) `
            "$failedTool failure published an output"
    }

    $raceOutput = Join-Path $TestRoot 'publish-race'
    $previousRaceOutput = $env:CODEXKIT_TEST_RACE_OUTPUT
    $previousCapture = $env:CODEXKIT_TEST_CAPTURE
    $previousMetadataCapture = $env:CODEXKIT_TEST_METADATA_CAPTURE
    $env:CODEXKIT_TEST_RACE_OUTPUT = $raceOutput
    $env:CODEXKIT_TEST_CAPTURE = $capture
    $env:CODEXKIT_TEST_METADATA_CAPTURE = $metadataCapture
    try {
        Assert-ThrowsLike {
            & $Builder -Tag $ExpectedTag -Patch $defaultPatch `
                -OutputRoot $raceOutput -SourceArchive $archive `
                -TestMode -ToolRoot $toolRoot
        } '*already exists*' 'publish race did not fail atomically'
    } finally {
        $env:CODEXKIT_TEST_RACE_OUTPUT = $previousRaceOutput
        $env:CODEXKIT_TEST_CAPTURE = $previousCapture
        $env:CODEXKIT_TEST_METADATA_CAPTURE = $previousMetadataCapture
    }
    $raceEntries = @(Get-ChildItem -LiteralPath $raceOutput -Force)
    Assert-True ($raceEntries.Count -eq 1 -and
        $raceEntries[0].Name -ceq 'competitor.txt') `
        'publish race merged staged payloads into the competing target'
    Write-Output 'CodexPlusCompatibility.Tests: fixture-contract PASS'
}

function Get-PeMachine([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { Fail "not a PE file: $Path" }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { Fail "invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Invoke-BuiltMode {
    if ($env:OS -cne 'Windows_NT') {
        Fail 'BuiltRoot inspection is Windows-only; fixture mode does not certify release EXEs'
    }
    $root = [IO.Path]::GetFullPath($BuiltRoot)
    $rootEntries = @(Get-ChildItem -LiteralPath $root -Force)
    Assert-True ($rootEntries.Count -eq 4 -and
        @($rootEntries | Where-Object { $_.PSIsContainer }).Count -eq 0) `
        'built root must contain exactly four payload files'
    foreach ($name in @($SetupName, $SourceName, 'CODEXKIT-PATCH.md', 'SHA256SUMS.txt')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf) `
            "built root omitted $name"
    }
    Assert-ExactPayloadChecksums $root
    $canonicalPatch = Join-Path (Join-Path (Join-Path $RepositoryRoot 'patches') `
        'CodexPlusPlus') 'v1.2.43-cross-provider-history.patch'
    Assert-PatchContract $canonicalPatch
    $setup = Join-Path $root $SetupName
    $version = (Get-Item -LiteralPath $setup).VersionInfo
    Assert-True ($version.ProductVersion -ceq $ExpectedVersion) `
        "setup ProductVersion is not $ExpectedVersion"
    Assert-True ($version.FileVersion -ceq $ExpectedVersion) `
        "setup FileVersion is not $ExpectedVersion"
    Assert-RawCreateProcessContract $setup 'release setup'

    $sevenZip = Get-Command '7z.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $sevenZip) {
        $sevenZip = Get-Command '7z' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($null -eq $sevenZip) { Fail '7-Zip is required to inspect the NSIS payload' }
    $expanded = Join-Path $TestRoot 'setup'
    New-Item -ItemType Directory -Path $expanded -Force | Out-Null
    Invoke-Native $sevenZip.Source @('x', '-y', "-o$expanded", $setup) $RepositoryRoot
    $expectedComponents = [ordered]@{
        'codex-plus-plus.exe' = 'launcher'
        'codex-plus-plus-manager.exe' = 'manager'
    }
    $actualExecutableHashes = @{}
    foreach ($binary in $expectedComponents.Keys) {
        $matches = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Force |
            Where-Object { $_.Name -ceq $binary })
        Assert-True ($matches.Count -eq 1) "NSIS payload must contain exactly one $binary"
        Assert-True ((Get-PeMachine $matches[0].FullName) -eq 0x8664) `
            "$binary is not x64"
        $metadata = Get-ExecutableMetadata $matches[0].FullName
        Assert-True ($metadata.schemaVersion -eq 1) `
            "$binary executable metadata schema is wrong"
        Assert-True ($metadata.payloadVersion -ceq $ExpectedVersion) `
            "$binary executable payload version is wrong"
        Assert-True ($metadata.compatibilityRevision -ceq $ExpectedRevision) `
            "$binary executable compatibility revision is wrong"
        Assert-True ($metadata.architecture -ceq 'x64') `
            "$binary executable architecture metadata is wrong"
        Assert-True ($metadata.component -ceq $expectedComponents[$binary]) `
            "$binary executable component identity is wrong"
        Assert-True ($metadata.fixtureOnly -eq $false) `
            "$binary executable is marked fixtureOnly"
        $actualExecutableHashes[$binary] = (
            Get-FileHash -LiteralPath $matches[0].FullName -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }

    $sourceRoot = Expand-SourceArchive (Join-Path $root $SourceName) `
        (Join-Path $TestRoot 'built-source')
    $manifest = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'CODEXKIT-BUILD-MANIFEST.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.upstreamTag -ceq $ExpectedTag) 'source manifest tag is wrong'
    Assert-True ($manifest.payloadVersion -ceq $ExpectedVersion) `
        'source manifest payload version is wrong'
    Assert-True ($manifest.compatibilityRevision -ceq $ExpectedRevision) `
        'source manifest compatibility revision is wrong'
    Assert-True ($manifest.architecture -ceq 'x64') 'source manifest architecture is wrong'
    Assert-True ($manifest.fixtureOnly -eq $false) `
        'release source manifest is marked fixtureOnly'
    Assert-True ($manifest.perUser -eq $true) `
        'release source manifest is not marked per-user'
    Assert-True ($manifest.executionLevel -ceq 'user') `
        'release source manifest execution level is not user'
    Assert-True ($manifest.installDir -ceq $ExpectedInstallDir) `
        'release source manifest install directory is wrong'
    Assert-True ($manifest.registryHive -ceq 'HKCU') `
        'release source manifest registry hive is not HKCU'
    Assert-True ($manifest.shortcutScope -ceq 'currentUser') `
        'release source manifest shortcut scope is not currentUser'
    Assert-True ($manifest.requiresElevation -eq $false) `
        'release source manifest requires elevation'
    Assert-True ($manifest.rawCreateProcessCompatible -eq $true) `
        'release source manifest does not certify raw CreateProcess launch'
    Assert-True ($manifest.setupProvenanceSchema -ceq $SetupProvenanceSchema -and
        $manifest.setupProvenanceMagic -ceq $SetupProvenanceMagic) `
        'release source manifest setup provenance identity is wrong'
    Assert-True ($manifest.patchSha256 -ceq $ExpectedPatchSha256) `
        'source manifest patch SHA-256 is not the reviewed digest'
    $setupRecord = Assert-SetupProvenanceContract $setup $manifest $false `
        'release setup'
    $manifestExecutables = @($manifest.executables)
    Assert-True ($manifestExecutables.Count -eq 2) `
        'source manifest must describe exactly two executables'
    Assert-True ((@($manifestExecutables.component | Sort-Object) -join ',') -ceq
        'launcher,manager') 'source manifest executable components are wrong'
    foreach ($entry in $manifestExecutables) {
        Assert-True ($entry.payloadVersion -ceq $ExpectedVersion) `
            'source manifest executable payload version is wrong'
        Assert-True ($entry.compatibilityRevision -ceq $ExpectedRevision) `
            'source manifest executable compatibility revision is wrong'
        Assert-True ($entry.architecture -ceq 'x64') `
            'source manifest executable architecture is wrong'
        Assert-True ($entry.metadataMagic -ceq $ExecutableMetadataMagic) `
            'source manifest executable metadata magic is wrong'
        Assert-True ($entry.sha256 -cmatch '^[0-9a-f]{64}$') `
            'source manifest executable SHA-256 is missing or malformed'
        Assert-True ($actualExecutableHashes[$entry.fileName] -ceq $entry.sha256) `
            'actual unpacked executable SHA-256 differs from source manifest'
        $setupEntry = @($setupRecord.executables | Where-Object {
            $_.component -ceq $entry.component
        })
        Assert-True ($setupEntry.Count -eq 1 -and
            $setupEntry[0].name -ceq $entry.fileName -and
            $setupEntry[0].sha256 -ceq $entry.sha256) `
            'setup provenance executable differs from unpacked payload'
    }
    foreach ($relative in @(
        'LICENSE',
        'CODEXKIT-PATCH.md',
        'CODEXKIT-BUILD-MANIFEST.json',
        'patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf) `
            "source archive omitted $relative"
    }
    $archivedPatch = Join-Path $sourceRoot `
        'patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch'
    $archivedPatchSha = (Get-FileHash -LiteralPath $archivedPatch `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($archivedPatchSha -ceq $ExpectedPatchSha256) `
        'archived patch SHA-256 is not the reviewed digest'
    $archivedNsi = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'scripts/installer/windows/CodexPlusPlus.nsi') -Raw
    Assert-PerUserNsiContract $archivedNsi 'release archived NSIS source'
    $externalProvenance = Get-Content -LiteralPath (
        Join-Path $root 'CODEXKIT-PATCH.md') -Raw
    $archivedProvenance = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'CODEXKIT-PATCH.md') -Raw
    Assert-True ($externalProvenance -ceq $archivedProvenance) `
        'external and archived provenance differ'
    Assert-Contains $externalProvenance `
        "Patch SHA-256: $ExpectedPatchSha256" `
        'provenance does not record the reviewed patch SHA-256'
    Assert-Contains $externalProvenance "Payload version: $ExpectedVersion" `
        'provenance payload version is wrong'
    Assert-Contains $externalProvenance `
        "Compatibility revision: $ExpectedRevision" `
        'provenance compatibility revision is wrong'
    Assert-Contains $externalProvenance 'Fixture only: False' `
        'release provenance is marked fixtureOnly or omits the marker'
    foreach ($needle in @(
        'Per-user installer: True',
        'Execution level: user',
        "Install directory: $ExpectedInstallDir",
        'Registry hive: HKCU',
        'Shortcut scope: currentUser',
        'Requires elevation: False',
        'Raw CreateProcess compatible: True',
        "Setup provenance schema: $SetupProvenanceSchema",
        "Setup provenance marker: $SetupProvenanceMagic"
    )) {
        Assert-Contains $externalProvenance $needle `
            "release provenance omits per-user contract line: $needle"
    }
    foreach ($entry in $manifestExecutables) {
        Assert-Contains $externalProvenance `
            "Executable SHA-256 ($($entry.component), $($entry.fileName)): $($entry.sha256)" `
            'release provenance omits an executable SHA-256'
    }
    Write-Output 'CodexPlusCompatibility.Tests: built-artifact PASS'
}

try {
    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
    switch ($PSCmdlet.ParameterSetName) {
        'Source' { Invoke-SourceMode }
        'Built' { Invoke-BuiltMode }
        default { Invoke-ContractMode }
    }
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
