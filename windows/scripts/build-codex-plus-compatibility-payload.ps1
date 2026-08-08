#Requires -Version 5.1
<#
.SYNOPSIS
Builds the fixed Codex++ v1.2.44 Windows compatibility payload.

.DESCRIPTION
Applies the shared CodexKit patch to the pinned upstream source, runs the
frontend and Rust checks, builds the x64 launchers, packages them with NSIS,
and publishes an auditable source archive plus checksums.

TestMode is reserved for the hermetic contract test. Its artifacts carry an
explicit fixtureOnly marker and are not accepted by BuiltRoot release inspection.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $Tag = 'v1.2.44',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Patch,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputRoot,

    [ValidateNotNullOrEmpty()]
    [string] $SourceArchive,

    [switch] $TestMode,

    [ValidateNotNullOrEmpty()]
    [string] $ToolRoot,

    [switch] $AllowUnprivilegedSymlinkTestSkip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExpectedTag = 'v1.2.44'
$ExpectedSourceArchiveSha256 = `
    '2c9a1900b24e838ed7b9405534be15efc81a670636cd97d4de8a16cab17a73cb'
$ExpectedPatchSha256 = `
    'ea9f8b3080fa8349b34ab2e2043814bd9e9b7bc0a60fe73f5dce3dad23906b69'
$UpstreamVersion = '1.2.44'
$PatchRevision = 'codexkit.1'
$PayloadVersion = '1.2.44+codexkit.1'
$CompatibilityRevision = 'cross-provider-content-v1'
$ExecutableMetadataMagic = 'CODEXKIT-EXECUTABLE-METADATA-V1:'
$SetupProvenanceSchema = 'CODEXKIT-SETUP-PROVENANCE-V1'
$SetupProvenanceMagic = "$SetupProvenanceSchema`:"
$PerUserInstallDir = '$LOCALAPPDATA\Programs\Codex++'
$SetupName = 'CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe'
$SourceName = 'CodexPlusPlus-v1.2.44-codexkit.1-source.tar.gz'
$UpstreamDirectory = 'CodexPlusPlus-1.2.44'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$SourcesFile = Join-Path (Join-Path $WindowsRoot 'vendor') 'upstream-sources.json'
$CanonicalPatch = Join-Path (Join-Path (Join-Path $RepositoryRoot 'patches') `
    'CodexPlusPlus') 'v1.2.44-cross-provider-history.patch'
$SharedFixture = Join-Path (Join-Path (Join-Path $RepositoryRoot 'tests') 'fixtures') `
    'codex-plus/cross_provider_content.rs'
$WorkRoot = ''
$StageRoot = ''
$Published = $false

function Fail([string] $Message) {
    throw "build-codex-plus-compatibility-payload: $Message"
}

function Test-IsWindows {
    return $env:OS -ceq 'Windows_NT'
}

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Assert-RegularFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point: $Path"
    }
    if ($item.PSObject.Properties['LinkType'] -and $null -ne $item.LinkType) {
        Fail "$Description is a symbolic link or reparse point: $Path"
    }
}

function Copy-CargoBuildOutputToRegularFile(
    [string] $Source,
    [string] $Destination,
    [string] $Description
) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Fail "$Description is missing: $Source"
    }
    $item = Get-Item -LiteralPath $Source -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point: $Source"
    }
    $linkType = if ($item.PSObject.Properties['LinkType']) {
        [string] $item.LinkType
    } else {
        ''
    }
    if (-not [string]::IsNullOrWhiteSpace($linkType) -and
        $linkType -cne 'HardLink') {
        Fail "$Description has an unsafe link type ($linkType): $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
    Assert-RegularFile $Destination "$Description materialized copy"
    $sourceHash = Get-FileHash -LiteralPath $Source -Algorithm SHA256
    $sourceSha = $sourceHash.Hash.ToLowerInvariant()
    if ($sourceSha -cne (Get-Sha256 $Destination)) {
        Fail "$Description materialized copy differs from Cargo output"
    }
}

function Assert-ReparseFreePath([string] $Path, [string] $Description) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    $tail = $full.Substring($root.Length)
    foreach ($segment in $tail.Split(
        @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "$Description contains a symbolic link or reparse point: $current"
        }
        if ($item.PSObject.Properties['LinkType'] -and $null -ne $item.LinkType) {
            Fail "$Description contains a symbolic link or reparse point: $current"
        }
    }
    return $full
}

function Resolve-Tool([string] $Name) {
    if ($TestMode) {
        foreach ($candidateName in @("$Name.ps1", "$Name.cmd", "$Name.exe", $Name)) {
            $candidate = Join-Path $ToolRoot $candidateName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
        Fail "test tool is missing: $Name"
    }
    if ($Name -ceq 'makensis' -and (Test-IsWindows)) {
        $programFilesX86 = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::ProgramFilesX86)
        if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
            $nsisCandidate = Join-Path (Join-Path $programFilesX86 'NSIS') `
                'makensis.exe'
            if (Test-Path -LiteralPath $nsisCandidate -PathType Leaf) {
                return $nsisCandidate
            }
        }
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { Fail "required command is missing: $Name" }
    return $command.Source
}

function Resolve-SystemTool([string] $Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { Fail "required command is missing: $Name" }
    return $command.Source
}

function Invoke-Checked(
    [string] $Step,
    [string] $Command,
    [string[]] $Arguments,
    [string] $WorkingDirectory
) {
    Write-Host "build-codex-plus-compatibility-payload: $Step"
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            Fail "$Step failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Get-Sha256([string] $Path) {
    Assert-RegularFile $Path 'hash input'
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
    Assert-RegularFile $Path 'setup provenance input'
    $bytes = [IO.File]::ReadAllBytes($Path)
    $markerBytes = [Text.Encoding]::UTF8.GetBytes($SetupProvenanceMagic)
    $offsets = @(Find-BytePatternOffsets $bytes $markerBytes)
    if ($offsets.Count -ne 1) {
        Fail "setup must contain exactly one $SetupProvenanceMagic marker"
    }
    $markerOffset = $offsets[0]
    if ($markerOffset -le 0 -or $bytes[$markerOffset - 1] -ne 10) {
        Fail 'setup provenance marker is not a line-aligned PE overlay'
    }
    if ($bytes.Length -le ($markerOffset + $markerBytes.Length + 2) -or
        $bytes[$bytes.Length - 1] -ne 10) {
        Fail 'setup provenance overlay is not the final newline-terminated record'
    }
    $jsonStart = $markerOffset + $markerBytes.Length
    $jsonLength = $bytes.Length - $jsonStart - 1
    $jsonBytes = New-Object byte[] $jsonLength
    [Array]::Copy($bytes, $jsonStart, $jsonBytes, 0, $jsonLength)
    if (($jsonBytes -contains 10) -or ($jsonBytes -contains 13)) {
        Fail 'setup provenance JSON must be exactly one line'
    }
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($jsonBytes) | ConvertFrom-Json
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
    if (($actual -join ',') -cne ($wanted -join ',')) {
        Fail "$Description properties are not the fixed schema"
    }
}

function Assert-SetupProvenanceContract(
    [string] $Path,
    [object] $Manifest
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
    ) 'setup provenance'
    if ($record.schema -cne $SetupProvenanceSchema -or
        $record.schemaVersion -ne 1 -or
        $record.setupFileName -cne $SetupName -or
        $record.upstreamTag -cne $ExpectedTag -or
        $record.patchSha256 -cne $ExpectedPatchSha256 -or
        $record.payloadVersion -cne $PayloadVersion -or
        $record.compatibilityRevision -cne $CompatibilityRevision -or
        $record.architecture -cne 'x64' -or
        $record.perUser -ne $true -or
        $record.executionLevel -cne 'user' -or
        $record.installDir -cne $PerUserInstallDir -or
        $record.registryHive -cne 'HKCU' -or
        $record.shortcutScope -cne 'currentUser' -or
        $record.requiresElevation -ne $false -or
        $record.rawCreateProcessCompatible -ne $true -or
        $record.fixtureOnly -ne [bool] $TestMode) {
        Fail 'setup provenance payload or per-user identity is inconsistent'
    }
    if ($Manifest.setupProvenanceSchema -cne $SetupProvenanceSchema -or
        $Manifest.setupProvenanceMagic -cne $SetupProvenanceMagic) {
        Fail 'source manifest setup provenance identity is inconsistent'
    }
    $manifestExecutables = @($Manifest.executables)
    $recordExecutables = @($record.executables)
    if ($manifestExecutables.Count -ne 2 -or $recordExecutables.Count -ne 2) {
        Fail 'setup provenance must describe exactly two executables'
    }
    foreach ($entry in $recordExecutables) {
        Assert-ExactJsonProperties $entry @(
            'name',
            'component',
            'sha256',
            'payloadVersion',
            'compatibilityRevision',
            'architecture',
            'metadataMagic'
        ) 'setup provenance executable'
        $manifestEntry = @($manifestExecutables | Where-Object {
            $_.component -ceq $entry.component
        })
        if ($manifestEntry.Count -ne 1 -or
            $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $entry.name -cne $manifestEntry[0].fileName -or
            $entry.sha256 -cne $manifestEntry[0].sha256 -or
            $entry.payloadVersion -cne $manifestEntry[0].payloadVersion -or
            $entry.compatibilityRevision -cne
                $manifestEntry[0].compatibilityRevision -or
            $entry.architecture -cne $manifestEntry[0].architecture -or
            $entry.metadataMagic -cne $manifestEntry[0].metadataMagic) {
            Fail 'setup provenance executable differs from source manifest'
        }
    }
    return $record
}

function Add-SetupProvenance([string] $Path, [object] $Record) {
    Assert-RegularFile $Path 'setup provenance output'
    $existing = [IO.File]::ReadAllBytes($Path)
    $markerBytes = [Text.Encoding]::UTF8.GetBytes($SetupProvenanceMagic)
    if (@(Find-BytePatternOffsets $existing $markerBytes).Count -ne 0) {
        Fail 'refusing to graft setup provenance onto a setup with an existing marker'
    }
    $json = $Record | ConvertTo-Json -Depth 5 -Compress
    $overlay = [Text.Encoding]::UTF8.GetBytes(
        "`n$SetupProvenanceMagic$json`n")
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Append, [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $stream.Write($overlay, 0, $overlay.Length)
    } finally {
        $stream.Dispose()
    }
}

function Assert-ExactPublishedFileSet(
    [string] $Root,
    [string] $Description
) {
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::Ordinal)
    foreach ($name in @($SetupName, $SourceName, 'CODEXKIT-PATCH.md',
        'SHA256SUMS.txt')) {
        [void] $expected.Add($name)
    }
    $entries = @(Get-ChildItem -LiteralPath $Root -Force)
    if ($entries.Count -ne 4) {
        Fail "$Description must contain exactly four payload files"
    }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or -not $expected.Remove($entry.Name)) {
            Fail "$Description contains an unexpected entry: $($entry.Name)"
        }
    }
    if ($expected.Count -ne 0) {
        Fail "$Description omits a required payload file"
    }
}

function Get-CodexKitExecutableMetadata([string] $Path) {
    Assert-RegularFile $Path 'executable metadata input'
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $length = [Math]::Min([long] 16384, $stream.Length)
        $stream.Position = $stream.Length - $length
        $bytes = New-Object byte[] ([int] $length)
        $read = $stream.Read($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    $tail = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
    $index = $tail.LastIndexOf(
        $ExecutableMetadataMagic, [StringComparison]::Ordinal)
    if ($index -lt 0) { Fail "executable metadata marker is missing: $Path" }
    $jsonStart = $index + $ExecutableMetadataMagic.Length
    $jsonEnd = $tail.IndexOf("`n", $jsonStart, [StringComparison]::Ordinal)
    if ($jsonEnd -le $jsonStart) {
        Fail "executable metadata is truncated: $Path"
    }
    try {
        return $tail.Substring($jsonStart, $jsonEnd - $jsonStart) |
            ConvertFrom-Json
    } catch {
        Fail "executable metadata is invalid JSON: $Path"
    }
}

function Add-CodexKitExecutableMetadata(
    [string] $Path,
    [ValidateSet('launcher', 'manager')] [string] $Component
) {
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $length = [Math]::Min([long] 16384, $stream.Length)
        $stream.Position = $stream.Length - $length
        $bytes = New-Object byte[] ([int] $length)
        $read = $stream.Read($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    $tail = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
    if ($tail.Contains($ExecutableMetadataMagic)) {
        Fail "executable already carries CodexKit metadata: $Path"
    }
    $metadata = [ordered]@{
        schemaVersion = 1
        payloadVersion = $PayloadVersion
        compatibilityRevision = $CompatibilityRevision
        architecture = 'x64'
        component = $Component
        fixtureOnly = [bool] $TestMode
    }
    $json = $metadata | ConvertTo-Json -Compress
    $encoded = [Text.Encoding]::UTF8.GetBytes(
        "`n$ExecutableMetadataMagic$json`n")
    $output = [IO.File]::Open(
        $Path, [IO.FileMode]::Append, [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $output.Write($encoded, 0, $encoded.Length)
    } finally {
        $output.Dispose()
    }
}

function Assert-CodexKitExecutableMetadata(
    [string] $Path,
    [ValidateSet('launcher', 'manager')] [string] $Component
) {
    $metadata = Get-CodexKitExecutableMetadata $Path
    if ($metadata.schemaVersion -ne 1 -or
        $metadata.payloadVersion -cne $PayloadVersion -or
        $metadata.compatibilityRevision -cne $CompatibilityRevision -or
        $metadata.architecture -cne 'x64' -or
        $metadata.component -cne $Component -or
        $metadata.fixtureOnly -ne [bool] $TestMode) {
        Fail "executable CodexKit metadata is inconsistent: $Path"
    }
}

function Set-ReproducibleSourceTimestamps(
    [string] $Root,
    [DateTime] $Timestamp
) {
    $directories = New-Object 'System.Collections.Generic.List[IO.DirectoryInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $rootItem = Get-Item -LiteralPath $Root -Force
    $pending.Push($rootItem)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $directories.Add($directory)
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if ($item.PSIsContainer) {
                if ($item.Name -in @('.git', 'dist', 'node_modules', 'target')) {
                    continue
                }
                $pending.Push($item)
            } else {
                $item.LastWriteTimeUtc = $Timestamp
            }
        }
    }
    for ($index = $directories.Count - 1; $index -ge 0; $index--) {
        $directories[$index].LastWriteTimeUtc = $Timestamp
    }
}

function New-ReproducibleSourceArchive(
    [string] $SourceParent,
    [string] $SourceDirectoryName,
    [string] $Destination,
    [string] $TarCommand
) {
    $uncompressed = Join-Path $WorkRoot 'CodexPlusPlus-source.tar'
    $previousCopyFileDisable = $env:COPYFILE_DISABLE
    $env:COPYFILE_DISABLE = '1'
    try {
        Invoke-Checked 'archive patched source' $TarCommand @(
            '--format=ustar',
            '--uid=0',
            '--gid=0',
            '--uname=codexkit',
            '--gname=codexkit',
            '-cf', $uncompressed,
            '--exclude=node_modules',
            '--exclude=target',
            '--exclude=dist',
            '--exclude=.git',
            '-C', $SourceParent,
            $SourceDirectoryName
        ) $RepositoryRoot
    } finally {
        $env:COPYFILE_DISABLE = $previousCopyFileDisable
    }
    Assert-RegularFile $uncompressed 'uncompressed patched source archive'
    $input = [IO.File]::Open(
        $uncompressed, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $output = [IO.File]::Open(
        $Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $gzip = New-Object IO.Compression.GZipStream(
            $output, [IO.Compression.CompressionMode]::Compress, $true)
        try {
            $input.CopyTo($gzip)
        } finally {
            $gzip.Dispose()
        }
    } finally {
        $input.Dispose()
        $output.Dispose()
    }
    Remove-Item -LiteralPath $uncompressed -Force
    Assert-RegularFile $Destination 'patched source archive'
}

function Assert-SafeArchiveEntries([string[]] $Entries) {
    if ($Entries.Count -eq 0) { Fail 'source archive is empty' }
    $topLevels = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::Ordinal)
    foreach ($rawEntry in $Entries) {
        $entry = ([string] $rawEntry).Trim()
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $normalized = $entry.Replace('\', '/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($normalized) -or
            $normalized.StartsWith('/') -or
            $normalized.StartsWith('~') -or
            $normalized -match '^[A-Za-z]:' -or
            $normalized.Contains([char] 0)) {
            Fail "source archive contains an unsafe path: $entry"
        }
        $segments = @($normalized.Split('/') | Where-Object { $_ -ne '' })
        if ($segments.Count -eq 0 -or $segments -contains '..' -or
            $segments -contains '.') {
            Fail "source archive contains an unsafe path: $entry"
        }
        [void] $topLevels.Add($segments[0])
    }
    if ($topLevels.Count -ne 1 -or -not $topLevels.Contains($UpstreamDirectory)) {
        Fail "source archive must contain only $UpstreamDirectory at its top level"
    }
}

function Expand-PinnedSource(
    [string] $Archive,
    [string] $Destination,
    [string] $TarCommand
) {
    Push-Location $RepositoryRoot
    try {
        $entries = @(& $TarCommand -tzf $Archive)
        if ($LASTEXITCODE -ne 0) { Fail 'unable to list source archive' }
    } finally {
        Pop-Location
    }
    Assert-SafeArchiveEntries $entries
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $tarFailure = $null
    try {
        Invoke-Checked 'extract pinned source' $TarCommand `
            @('-xzf', $Archive, '-C', $Destination) $RepositoryRoot
    } catch {
        $tarFailure = $_
    }
    if ($null -ne $tarFailure) {
        # Windows' inbox tar.exe can fail to materialize UTF-8 entry names on
        # some archives (notably the reviewed Codex++ source, which contains
        # Chinese documentation paths). Use Python's UTF-8-aware tarfile
        # implementation as a deterministic fallback, while rejecting links,
        # devices, and paths that escape the destination.
        $python = Get-Command python.exe, py.exe -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $python) {
            throw $tarFailure
        }
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $extractor = Join-Path $WorkRoot 'extract-pinned-source.py'
        Write-Utf8NoBom $extractor @'
import os
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2]).resolve()

def safe_target(name: str) -> pathlib.Path:
    normalized = name.replace('\\', '/')
    if not normalized or normalized.startswith('/'):
        raise RuntimeError(f'unsafe archive path: {name!r}')
    target = (destination / normalized).resolve()
    try:
        target.relative_to(destination)
    except ValueError as exc:
        raise RuntimeError(f'archive path escapes destination: {name!r}') from exc
    return target

with tarfile.open(archive, mode='r:gz') as source:
    for member in source.getmembers():
        target = safe_target(member.name)
        if member.issym() or member.islnk() or member.isdev():
            raise RuntimeError(f'archive contains an unsupported link/device: {member.name!r}')
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not member.isfile():
            raise RuntimeError(f'archive contains an unsupported entry: {member.name!r}')
        target.parent.mkdir(parents=True, exist_ok=True)
        stream = source.extractfile(member)
        if stream is None:
            raise RuntimeError(f'archive entry has no data: {member.name!r}')
        with stream, target.open('wb') as output:
            while True:
                block = stream.read(1024 * 1024)
                if not block:
                    break
                output.write(block)
        try:
            os.chmod(target, member.mode & 0o777)
        except OSError:
            pass
'@
        $pythonArguments = @($extractor, $Archive, $Destination)
        if ([IO.Path]::GetFileName($python.Source) -ieq 'py.exe') {
            $pythonArguments = @('-3') + $pythonArguments
        }
        Invoke-Checked 'extract pinned source with Python UTF-8 fallback' `
            $python.Source $pythonArguments $RepositoryRoot
    }
    $sourceRoot = Join-Path $Destination $UpstreamDirectory
    Assert-RegularFile (Join-Path $sourceRoot 'Cargo.toml') 'upstream Cargo.toml'
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "extracted source contains a symbolic link or reparse point: $($item.FullName)"
        }
        if ($item.PSObject.Properties['LinkType'] -and $null -ne $item.LinkType) {
            Fail "extracted source contains a symbolic link or reparse point: $($item.FullName)"
        }
    }
    return $sourceRoot
}

function Get-ExactNsisLineCount([string] $Text, [string] $Line) {
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Line) + '[ \t]*\r?$'
    return [regex]::Matches($Text, $pattern).Count
}

function Assert-FixedUpstreamNsisPerUserContract([string] $Text) {
    $requiredSectionHeaders = @(
        'Section "Install"',
        'Section "Uninstall"'
    )
    $requiredRegistryLines = @(
        'InstallDirRegKey HKCU "Software\Codex++" "InstallDir"',
        'WriteRegStr HKCU "Software\Codex++" "InstallDir" "$INSTDIR"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayName" "Codex++"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayVersion" "${VERSION}"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "Publisher" "BigPizzaV3"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "DisplayIcon" "$INSTDIR\codex-plus-plus-manager.exe"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "InstallLocation" "$INSTDIR"',
        'WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++" "UninstallString" "$INSTDIR\uninstall.exe"',
        'DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex++"',
        'DeleteRegKey HKCU "Software\Codex++"'
    )
    # Keep these labels ASCII-safe in the script source. Windows PowerShell
    # 5.1 parses a BOM-less UTF-8 script using the active ANSI code page, so
    # literal Chinese characters in the contract would become mojibake even
    # though the upstream NSIS file is read as UTF-8 below.
    $managerLabel = ([char] 0x7BA1) + ([char] 0x7406) +
        ([char] 0x5DE5) + ([char] 0x5177)
    $uninstallLabel = ([char] 0x5378) + ([char] 0x8F7D)
    $requiredShortcutLines = @(
        'CreateShortcut "$DESKTOP\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"',
        ('CreateShortcut "$DESKTOP\Codex++ ' + $managerLabel + '.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"'),
        'CreateShortcut "$SMPROGRAMS\Codex++\Codex++.lnk" "$INSTDIR\codex-plus-plus.exe" "" "$INSTDIR\codex-plus-plus.exe"',
        ('CreateShortcut "$SMPROGRAMS\Codex++\Codex++ ' + $managerLabel + '.lnk" "$INSTDIR\codex-plus-plus-manager.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"'),
        ('CreateShortcut "$SMPROGRAMS\Codex++\' + $uninstallLabel + ' Codex++.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\codex-plus-plus-manager.exe"')
    )
    if ((Get-ExactNsisLineCount $Text "InstallDir `"$PerUserInstallDir`"") -ne 1 -or
        [regex]::Matches($Text, '(?m)^[ \t]*InstallDir[ \t]+').Count -ne 1) {
        Fail 'CodexPlusPlus.nsi upstream per-user installer contract drifted: InstallDir'
    }
    foreach ($line in @($requiredRegistryLines + $requiredShortcutLines)) {
        if ((Get-ExactNsisLineCount $Text $line) -ne 1) {
            Fail "CodexPlusPlus.nsi upstream per-user installer contract drifted: $line"
        }
    }
    foreach ($line in $requiredSectionHeaders) {
        if ((Get-ExactNsisLineCount $Text $line) -ne 1) {
            Fail "CodexPlusPlus.nsi upstream per-user installer contract drifted: $line"
        }
    }
    if ([regex]::Matches(
            $Text,
            '(?im)^[ \t]*(?:InstallDirRegKey|WriteRegStr|DeleteRegKey)[ \t]+'
        ).Count -ne $requiredRegistryLines.Count -or
        [regex]::Matches(
            $Text, '(?im)^[ \t]*CreateShortcut[ \t]+'
        ).Count -ne $requiredShortcutLines.Count -or
        $Text -match `
            '(?i)\bHKLM\b|\$PROGRAMFILES(?:32|64)?\b|SetShellVarContext[ \t]+|\$(?:COMMONDESKTOP|COMMONPROGRAMS|COMMONSTARTMENU)\b') {
        Fail 'CodexPlusPlus.nsi upstream per-user installer contract drifted: machine-wide or unexpected primitive'
    }
}

function Assert-NsisCodexKitConversionSource([string] $NsiPath) {
    Assert-RegularFile $NsiPath 'CodexPlusPlus.nsi'
    # The upstream NSIS source is UTF-8 and contains localized shortcut names.
    # Windows PowerShell 5.1 otherwise decodes it with the active ANSI code
    # page, turning the reviewed lines into mojibake and rejecting a valid
    # installer contract.
    $text = Get-Content -LiteralPath $NsiPath -Encoding UTF8 -Raw
    if ($text -notmatch [regex]::Escape('OutFile "${ROOT}\dist\windows\CodexPlusPlus-${VERSION}-windows-x64-setup.exe"')) {
        Fail 'CodexPlusPlus.nsi output contract changed upstream'
    }
    if ($text.Contains('CodexKitCompatibilityRevision')) {
        Fail 'CodexPlusPlus.nsi already defines downstream compatibility metadata'
    }
    $adminPattern = `
        '(?m)^(?<indent>[ \t]*)RequestExecutionLevel[ \t]+admin[ \t]*(?=\r?$)'
    $adminRegex = New-Object Text.RegularExpressions.Regex($adminPattern)
    $adminCount = $adminRegex.Matches($text).Count
    if ($adminCount -ne 1) {
        Fail "expected exactly one upstream RequestExecutionLevel admin directive; found $adminCount"
    }
    if ([regex]::Matches(
            $text,
            '(?m)^[ \t]*RequestExecutionLevel[ \t]+[A-Za-z]+[ \t]*\r?$'
        ).Count -ne 1) {
        Fail 'CodexPlusPlus.nsi upstream per-user installer contract drifted: execution level'
    }
    Assert-FixedUpstreamNsisPerUserContract $text
    return $text
}

function Convert-NsisToCodexKitPerUserInstaller([string] $NsiPath) {
    $text = Assert-NsisCodexKitConversionSource $NsiPath
    $adminPattern = `
        '(?m)^(?<indent>[ \t]*)RequestExecutionLevel[ \t]+admin[ \t]*(?=\r?$)'
    $adminRegex = New-Object Text.RegularExpressions.Regex($adminPattern)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $executionReplacement = '${indent}RequestExecutionLevel user'
    $updated = $adminRegex.Replace($text, $executionReplacement, 1)
    foreach ($sectionName in @('Install', 'Uninstall')) {
        $sectionPattern = '(?m)^(?<indent>[ \t]*)' +
            [regex]::Escape("Section `"$sectionName`"") + '[ \t]*(?=\r?$)'
        $sectionRegex = New-Object Text.RegularExpressions.Regex($sectionPattern)
        if ($sectionRegex.Matches($updated).Count -ne 1) {
            Fail "CodexPlusPlus.nsi per-user section anchor drifted: $sectionName"
        }
        $sectionReplacement = '$0' + $newline +
            '${indent}  SetShellVarContext current'
        $updated = $sectionRegex.Replace($updated, $sectionReplacement, 1)
    }
    if ([regex]::Matches(
            $updated,
            '(?m)^[ \t]*RequestExecutionLevel[ \t]+user[ \t]*\r?$'
        ).Count -ne 1 -or
        [regex]::Matches(
            $updated,
            '(?m)^[ \t]*SetShellVarContext[ \t]+current[ \t]*\r?$'
        ).Count -ne 2 -or
        $updated -match `
            '(?im)^[ \t]*RequestExecutionLevel[ \t]+(?:admin|highest)[ \t]*\r?$|\bHKLM\b|\$PROGRAMFILES(?:32|64)?\b|SetShellVarContext[ \t]+all\b') {
        Fail 'CodexPlusPlus.nsi per-user execution transformation failed verification'
    }
    $anchor = '!endif'
    $anchorIndex = $updated.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) { Fail 'CodexPlusPlus.nsi version anchor is missing' }
    $metadata = @"

VIProductVersion "1.2.44.1"
VIFileVersion "1.2.44.1"
VIAddVersionKey "ProductName" "Codex++"
VIAddVersionKey "ProductVersion" "`${VERSION}"
VIAddVersionKey "FileVersion" "`${VERSION}"
VIAddVersionKey "CodexKitCompatibilityRevision" "$CompatibilityRevision"
"@
    $updatedWithMetadata = $updated.Insert(
        $anchorIndex + $anchor.Length, $metadata)
    Write-Utf8NoBom $NsiPath $updatedWithMetadata
}

function Get-PeMachine([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { Fail "not a PE file: $Path" }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt ($stream.Length - 6)) { Fail "invalid PE offset: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { Fail "invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-X64Pe([string] $Path, [string] $Description) {
    Assert-RegularFile $Path $Description
    if ((Get-PeMachine $Path) -ne 0x8664) {
        Fail "$Description is not an x64 PE executable"
    }
}

if ($Tag -cne $ExpectedTag) {
    Fail "only fixed tag $ExpectedTag is allowed"
}
if (-not (Test-IsWindows) -and -not $TestMode) {
    Fail 'production Codex++ payload builds require Windows x64'
}
if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($SourceArchive)) {
        Fail 'TestMode requires SourceArchive'
    }
    if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
        Fail 'TestMode requires ToolRoot'
    }
} elseif (-not [string]::IsNullOrWhiteSpace($ToolRoot)) {
    Fail 'ToolRoot is test-only'
}

$PatchFull = Assert-ReparseFreePath ([IO.Path]::GetFullPath($Patch)) 'patch path'
Assert-RegularFile $PatchFull 'shared compatibility patch'
Assert-RegularFile $CanonicalPatch 'repository shared compatibility patch'
$canonicalPatchSha = Get-Sha256 $CanonicalPatch
$inputPatchSha = Get-Sha256 $PatchFull
if ($canonicalPatchSha -cne $ExpectedPatchSha256) {
    Fail "repository shared patch SHA-256 is not the reviewed digest: $canonicalPatchSha"
}
if ($inputPatchSha -cne $ExpectedPatchSha256) {
    Fail 'Patch must be byte-identical to the reviewed repository v1.2.44 shared patch'
}
Assert-RegularFile $SourcesFile 'upstream source policy'
Assert-RegularFile $SharedFixture 'shared cross-provider Rust fixture'
$sources = Get-Content -LiteralPath $SourcesFile -Raw | ConvertFrom-Json
$expectedSourceUrl = "https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/tags/$ExpectedTag.tar.gz"
if ($sources.codexPlusPlusTag -cne $ExpectedTag -or
    $sources.codexPlusPlusSource -cne $expectedSourceUrl) {
    Fail 'upstream source policy is not pinned to the exact Codex++ v1.2.44 archive'
}

$OutputFull = [IO.Path]::GetFullPath($OutputRoot)
$outputParent = Split-Path -Parent $OutputFull
$outputLeaf = Split-Path -Leaf $OutputFull
if ([string]::IsNullOrWhiteSpace($outputParent) -or
    [string]::IsNullOrWhiteSpace($outputLeaf) -or
    $OutputFull -ceq [IO.Path]::GetPathRoot($OutputFull)) {
    Fail 'OutputRoot must name a new, non-root directory'
}
if (Test-Path -LiteralPath $OutputFull) {
    Fail "refusing to overwrite existing OutputRoot: $OutputFull"
}
if (-not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}
$outputParent = Assert-ReparseFreePath $outputParent 'output parent'
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "codex-plus-windows-build-$([Guid]::NewGuid().ToString('N'))"
$StageRoot = Join-Path $outputParent `
    ".$outputLeaf.stage-$([Guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $WorkRoot, $StageRoot -Force | Out-Null
    $tar = Resolve-SystemTool 'tar'
    $git = Resolve-Tool 'git'
    $npm = Resolve-Tool 'npm'
    $cargo = Resolve-Tool 'cargo'
    $makensis = Resolve-Tool 'makensis'

    if ([string]::IsNullOrWhiteSpace($SourceArchive)) {
        $archiveFull = Join-Path $WorkRoot "CodexPlusPlus-$ExpectedTag.tar.gz"
        Write-Host 'build-codex-plus-compatibility-payload: download pinned upstream source'
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 `
            -Uri $expectedSourceUrl -OutFile $archiveFull
    } else {
        $archiveFull = Assert-ReparseFreePath `
            ([IO.Path]::GetFullPath($SourceArchive)) 'source archive path'
    }
    Assert-RegularFile $archiveFull 'pinned upstream source archive'
    if ((Get-Item -LiteralPath $archiveFull).Length -eq 0) {
        Fail 'pinned upstream source archive is empty'
    }
    $sourceSha = Get-Sha256 $archiveFull
    if (-not $TestMode -and $sourceSha -cne $ExpectedSourceArchiveSha256) {
        Fail 'pinned upstream source archive SHA-256 does not match the reviewed v1.2.44 archive'
    }
    $patchSha = $ExpectedPatchSha256
    $extractRoot = Join-Path $WorkRoot 'extracted'
    $sourceRoot = Expand-PinnedSource $archiveFull $extractRoot $tar
    $nsi = Join-Path (Join-Path (Join-Path (Join-Path $sourceRoot 'scripts') `
        'installer') 'windows') 'CodexPlusPlus.nsi'
    [void] (Assert-NsisCodexKitConversionSource $nsi)

    Invoke-Checked 'patch dry-run' $git @(
        '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-C', $sourceRoot,
        'apply', '--check', '--unidiff-zero',
        '--whitespace=nowarn', $PatchFull
    ) $RepositoryRoot
    Invoke-Checked 'apply shared compatibility patch' $git @(
        '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-C', $sourceRoot,
        'apply', '--unidiff-zero', '--whitespace=nowarn',
        $PatchFull
    ) $RepositoryRoot
    if ($TestMode) {
        $fixturePatchTarget = Join-Path $sourceRoot `
            'apps/codex-plus-manager/src-tauri/src/lib.rs'
        Assert-RegularFile $fixturePatchTarget 'fixture patch target'
        if (-not (Get-Content -LiteralPath $fixturePatchTarget -Raw).Contains(
            'commands::take_content_compatibility_notice,')) {
            Fail 'fixture patch tool did not apply the reviewed shared-patch hunk'
        }
    } else {
        $patchedProtocol = Get-Content -LiteralPath (
            Join-Path $sourceRoot 'crates/codex-plus-core/src/protocol_proxy.rs') `
            -Raw
        $patchedManager = Get-Content -LiteralPath (
            Join-Path $sourceRoot 'apps/codex-plus-manager/src/App.tsx') -Raw
        foreach ($needle in @('normalize_chat_message_contents',
            'protocol_proxy.content_compatibility')) {
            if (-not $patchedProtocol.Contains($needle)) {
                Fail "applied source omits compatibility patch marker: $needle"
            }
        }
        if (-not $patchedManager.Contains('take_content_compatibility_notice')) {
            Fail 'applied manager source omits compatibility notice marker'
        }
    }

    $sourceFixture = Join-Path (Join-Path (Join-Path $sourceRoot 'crates') `
        'codex-plus-core') 'tests/codexkit_cross_provider_content.rs'
    Copy-Item -LiteralPath $SharedFixture -Destination $sourceFixture -Force
    $patchInSource = Join-Path (Join-Path (Join-Path $sourceRoot 'patches') `
        'CodexPlusPlus') 'v1.2.44-cross-provider-history.patch'
    New-Item -ItemType Directory -Path (Split-Path -Parent $patchInSource) `
        -Force | Out-Null
    Copy-Item -LiteralPath $PatchFull -Destination $patchInSource -Force
    if ((Get-Sha256 $patchInSource) -cne $ExpectedPatchSha256) {
        Fail 'archived patch copy differs from the reviewed patch'
    }

    $normalizedTime = [DateTime]::SpecifyKind(
        [DateTime]::ParseExact('2026-07-27T00:00:00', 'yyyy-MM-ddTHH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture),
        [DateTimeKind]::Utc)
    foreach ($generated in @($sourceFixture, $patchInSource, $nsi)) {
        (Get-Item -LiteralPath $generated).LastWriteTimeUtc = $normalizedTime
    }

    $managerRoot = Join-Path (Join-Path (Join-Path $sourceRoot 'apps') `
        'codex-plus-manager') ''
    Assert-RegularFile (Join-Path $managerRoot 'package-lock.json') `
        'manager package-lock.json'
    Invoke-Checked 'manager npm ci' $npm @('--prefix', $managerRoot, 'ci') $sourceRoot
    Invoke-Checked 'manager tests' $npm @('--prefix', $managerRoot, 'test') $sourceRoot
    Invoke-Checked 'manager type check' $npm @('--prefix', $managerRoot, 'run', 'check') `
        $sourceRoot
    Invoke-Checked 'manager frontend build' $npm `
        @('--prefix', $managerRoot, 'run', 'vite:build') $sourceRoot
    Invoke-Checked 'Rust formatting check' $cargo @('fmt', '--all', '--', '--check') `
        $sourceRoot
    # The upstream model_catalog integration tests use short-lived loopback
    # servers. Windows runners can delay concurrent first-use connections long
    # enough for those servers to expire, so keep the complete suite but run
    # each test binary serially.
    $workspaceTestArguments = @(
        'test', '--workspace', '--', '--test-threads=1'
    )
    if ($AllowUnprivilegedSymlinkTestSkip) {
        Write-Warning (
            'Skipping app_paths_resolves_portable_current_link_to_directory_version ' +
            'because this non-elevated Windows account lacks symbolic-link privilege.'
        )
        $workspaceTestArguments = @(
            'test', '--workspace',
            '--exclude', 'codex-plus-launcher',
            '--exclude', 'codex-plus-manager', '--',
            '--test-threads=1', '--skip',
            'app_paths_resolves_portable_current_link_to_directory_version'
        )
    }
    Invoke-Checked 'Rust workspace tests' $cargo $workspaceTestArguments $sourceRoot
    if ($AllowUnprivilegedSymlinkTestSkip) {
        Invoke-Checked 'Codex++ core launcher tests' $cargo @(
            'test', '-p', 'codex-plus-core', '--test', 'launcher', '--',
            '--test-threads=1', '--skip',
            'app_paths_resolves_portable_current_link_to_directory_version'
        ) $sourceRoot
        Invoke-Checked 'Codex++ manager library tests' $cargo @(
            'test', '-p', 'codex-plus-manager', '--lib', '--', '--test-threads=1'
        ) $sourceRoot
    }
    Invoke-Checked 'cross-provider Rust regression' $cargo @(
        'test', '-p', 'codex-plus-core', '--test', 'codexkit_cross_provider_content'
    ) $sourceRoot
    Invoke-Checked 'Windows release build' $cargo @('build', '--release') $sourceRoot

    $releaseRoot = Join-Path (Join-Path $sourceRoot 'target') 'release'
    $materializedRoot = Join-Path $WorkRoot 'materialized-cargo-output'
    New-Item -ItemType Directory -Path $materializedRoot -Force | Out-Null
    $launcher = Join-Path $materializedRoot 'codex-plus-plus.exe'
    $manager = Join-Path $materializedRoot 'codex-plus-plus-manager.exe'
    Copy-CargoBuildOutputToRegularFile `
        (Join-Path $releaseRoot 'codex-plus-plus.exe') $launcher 'Codex++ launcher'
    Copy-CargoBuildOutputToRegularFile `
        (Join-Path $releaseRoot 'codex-plus-plus-manager.exe') $manager `
        'Codex++ manager'
    if (-not $TestMode) {
        Assert-X64Pe $launcher 'Codex++ launcher'
        Assert-X64Pe $manager 'Codex++ manager'
    }
    Add-CodexKitExecutableMetadata $launcher 'launcher'
    Add-CodexKitExecutableMetadata $manager 'manager'
    Assert-CodexKitExecutableMetadata $launcher 'launcher'
    Assert-CodexKitExecutableMetadata $manager 'manager'
    $launcherSha = Get-Sha256 $launcher
    $managerSha = Get-Sha256 $manager

    $manifestPath = Join-Path $sourceRoot 'CODEXKIT-BUILD-MANIFEST.json'
    $manifest = [ordered]@{
        schemaVersion = 1
        upstream = 'https://github.com/BigPizzaV3/CodexPlusPlus'
        upstreamTag = $ExpectedTag
        upstreamSource = $expectedSourceUrl
        sourceArchiveSha256 = $sourceSha
        patch = 'patches/CodexPlusPlus/v1.2.44-cross-provider-history.patch'
        patchSha256 = $patchSha
        patchRevision = $PatchRevision
        payloadVersion = $PayloadVersion
        compatibilityRevision = $CompatibilityRevision
        architecture = 'x64'
        perUser = $true
        executionLevel = 'user'
        installDir = $PerUserInstallDir
        registryHive = 'HKCU'
        shortcutScope = 'currentUser'
        requiresElevation = $false
        rawCreateProcessCompatible = $true
        setupFileName = $SetupName
        setupProvenanceSchema = $SetupProvenanceSchema
        setupProvenanceMagic = $SetupProvenanceMagic
        executables = @(
            [ordered]@{
                fileName = 'codex-plus-plus.exe'
                component = 'launcher'
                sha256 = $launcherSha
                payloadVersion = $PayloadVersion
                compatibilityRevision = $CompatibilityRevision
                architecture = 'x64'
                metadataMagic = $ExecutableMetadataMagic
            },
            [ordered]@{
                fileName = 'codex-plus-plus-manager.exe'
                component = 'manager'
                sha256 = $managerSha
                payloadVersion = $PayloadVersion
                compatibilityRevision = $CompatibilityRevision
                architecture = 'x64'
                metadataMagic = $ExecutableMetadataMagic
            }
        )
        fixtureOnly = [bool] $TestMode
    }
    Write-Utf8NoBom $manifestPath (($manifest | ConvertTo-Json -Depth 5) + "`n")

    $provenancePath = Join-Path $sourceRoot 'CODEXKIT-PATCH.md'
    $provenance = @"
# CodexKit Windows compatibility build

- Upstream: https://github.com/BigPizzaV3/CodexPlusPlus
- Upstream tag: $ExpectedTag
- Upstream source: $expectedSourceUrl
- Source archive SHA-256: $sourceSha
- Patch: patches/CodexPlusPlus/v1.2.44-cross-provider-history.patch
- Patch SHA-256: $patchSha
- Patch revision: $PatchRevision
- Payload version: $PayloadVersion
- Compatibility revision: $CompatibilityRevision
- Architecture: x64
- Fixture only: $([bool] $TestMode)
- Per-user installer: True
- Execution level: user
- Install directory: $PerUserInstallDir
- Registry hive: HKCU
- Shortcut scope: currentUser
- Requires elevation: False
- Raw CreateProcess compatible: True
- Setup provenance schema: $SetupProvenanceSchema
- Setup provenance marker: $SetupProvenanceMagic
- Executable SHA-256 (launcher, codex-plus-plus.exe): $launcherSha
- Executable SHA-256 (manager, codex-plus-plus-manager.exe): $managerSha

Build sequence:

1. Verify the fixed upstream NSIS installer has exactly one
   ``RequestExecutionLevel admin`` directive plus the reviewed LOCALAPPDATA,
   HKCU, and current-user shortcut contracts; reject any drift, ProgramFiles,
   HKLM, or all-users primitive.
2. Apply the shared zero-context-compatible patch with ``git apply
   --check --unidiff-zero`` followed by ``git apply --unidiff-zero``.
3. Run ``npm ci``, manager tests, TypeScript checks, and the Vite build.
4. Run ``cargo fmt --all -- --check`` and ``cargo test --workspace``.
5. Run the targeted ``codexkit_cross_provider_content`` Rust regression.
6. Run ``cargo build --release`` on a Windows x64 host.
7. Materialize Cargo hard-link outputs as byte-identical regular files,
   append and verify the structured ``$ExecutableMetadataMagic`` record in
   both x64 executables, then record each final executable's SHA-256.
8. Replace the NSIS execution-level directive exactly once with
   ``RequestExecutionLevel user``, add ``SetShellVarContext current`` inside
   both the install and uninstall sections, stage both x64 launchers, and invoke
   ``makensis /INPUTCHARSET UTF8 /DVERSION=$PayloadVersion CodexPlusPlus.nsi``.
9. Append exactly one final, newline-terminated ``$SetupProvenanceMagic`` JSON
   overlay to the setup and verify its fixed schema against the source
   manifest and executable hashes.

The generated source manifest records the fixed tag, source digest, patch
digest, compatibility revision, architecture, fixture-only status, audited
per-user installer contract, and the final hashes of both included launchers.
Each launcher also carries these downstream identifiers. The resulting setup
is asInvoker with uiAccess=false and can be launched by the outer installer
through raw CreateProcess without elevation or switching to another
administrator profile. Its fixed setup overlay lets the outer installer
verify the same payload identity and executable hashes after installation.
"@
    Write-Utf8NoBom $provenancePath ($provenance + "`n")
    foreach ($generated in @($manifestPath, $provenancePath)) {
        (Get-Item -LiteralPath $generated).LastWriteTimeUtc = $normalizedTime
    }

    $setupProvenance = [ordered]@{
        schema = $SetupProvenanceSchema
        schemaVersion = 1
        setupFileName = $SetupName
        upstreamTag = $ExpectedTag
        patchSha256 = $ExpectedPatchSha256
        payloadVersion = $PayloadVersion
        compatibilityRevision = $CompatibilityRevision
        architecture = 'x64'
        perUser = $true
        executionLevel = 'user'
        installDir = $PerUserInstallDir
        registryHive = 'HKCU'
        shortcutScope = 'currentUser'
        requiresElevation = $false
        rawCreateProcessCompatible = $true
        fixtureOnly = [bool] $TestMode
        executables = @(
            [ordered]@{
                name = 'codex-plus-plus.exe'
                component = 'launcher'
                sha256 = $launcherSha
                payloadVersion = $PayloadVersion
                compatibilityRevision = $CompatibilityRevision
                architecture = 'x64'
                metadataMagic = $ExecutableMetadataMagic
            },
            [ordered]@{
                name = 'codex-plus-plus-manager.exe'
                component = 'manager'
                sha256 = $managerSha
                payloadVersion = $PayloadVersion
                compatibilityRevision = $CompatibilityRevision
                architecture = 'x64'
                metadataMagic = $ExecutableMetadataMagic
            }
        )
    }

    $appRoot = Join-Path (Join-Path (Join-Path $sourceRoot 'dist') 'windows') 'app'
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
    Copy-Item -LiteralPath $launcher -Destination (
        Join-Path $appRoot 'codex-plus-plus.exe') -Force
    Copy-Item -LiteralPath $manager -Destination (
        Join-Path $appRoot 'codex-plus-plus-manager.exe') -Force
    if ((Get-Sha256 (Join-Path $appRoot 'codex-plus-plus.exe')) -cne
            $launcherSha -or
        (Get-Sha256 (Join-Path $appRoot 'codex-plus-plus-manager.exe')) -cne
            $managerSha) {
        Fail 'staged NSIS executables differ from recorded SHA-256 values'
    }

    Convert-NsisToCodexKitPerUserInstaller $nsi
    $nsiRoot = Split-Path -Parent $nsi
    Invoke-Checked 'NSIS package build' $makensis @(
        '/INPUTCHARSET', 'UTF8', "/DVERSION=$PayloadVersion", 'CodexPlusPlus.nsi'
    ) $nsiRoot
    $upstreamSetup = Join-Path (Join-Path (Join-Path $sourceRoot 'dist') 'windows') `
        "CodexPlusPlus-$PayloadVersion-windows-x64-setup.exe"
    Assert-RegularFile $upstreamSetup 'NSIS setup'
    if (-not $TestMode) {
        $versionInfo = (Get-Item -LiteralPath $upstreamSetup).VersionInfo
        if ($versionInfo.ProductVersion -cne $PayloadVersion -or
            $versionInfo.FileVersion -cne $PayloadVersion) {
            Fail "NSIS setup version metadata is not $PayloadVersion"
        }
    }
    Add-SetupProvenance $upstreamSetup $setupProvenance
    [void] (Assert-SetupProvenanceContract $upstreamSetup $manifest)
    $stagedSetup = Join-Path $StageRoot $SetupName
    Copy-Item -LiteralPath $upstreamSetup -Destination $stagedSetup
    [void] (Assert-SetupProvenanceContract $stagedSetup $manifest)

    Set-ReproducibleSourceTimestamps $sourceRoot $normalizedTime
    $stagedSource = Join-Path $StageRoot $SourceName
    New-ReproducibleSourceArchive $extractRoot $UpstreamDirectory `
        $stagedSource $tar
    Copy-Item -LiteralPath $provenancePath -Destination (
        Join-Path $StageRoot 'CODEXKIT-PATCH.md')

    $checksumNames = @('CODEXKIT-PATCH.md', $SetupName, $SourceName)
    $checksumLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $checksumNames) {
        $checksumLines.Add("$(Get-Sha256 (Join-Path $StageRoot $name))  $name")
    }
    Write-Utf8NoBom (Join-Path $StageRoot 'SHA256SUMS.txt') `
        (($checksumLines.ToArray() -join "`n") + "`n")
    Assert-ExactPublishedFileSet $StageRoot 'staged output'

    [IO.Directory]::Move($StageRoot, $OutputFull)
    $Published = $true
    Assert-ExactPublishedFileSet $OutputFull 'published output'
    Write-Output "build-codex-plus-compatibility-payload: PASS ($PayloadVersion, x64, $CompatibilityRevision)"
} finally {
    if ($WorkRoot -and (Test-Path -LiteralPath $WorkRoot)) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $Published -and $StageRoot -and (Test-Path -LiteralPath $StageRoot)) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
}
