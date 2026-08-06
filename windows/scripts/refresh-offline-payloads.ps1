#Requires -Version 5.1
<#
.SYNOPSIS
Builds the complete Windows offline payload snapshot from pinned upstreams.

.NOTES
This script intentionally runs only on Windows. It never uses a mirror for
Codex and it validates Appx identity plus Authenticode before publishing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputRoot,
    [Parameter(Mandatory)] [string] $CodexPlusPlusSetup,
    [Parameter(Mandatory)] [string] $CodexPlusPlusSource,
    [switch] $UseCachedModelCatalog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') {
    throw 'refresh-offline-payloads requires Windows for Appx and Authenticode validation'
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'offline-payload-supply.ps1')
$WindowsRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$SourcesPath = Join-Path $WindowsRoot 'vendor/upstream-sources.json'
$LockPath = Join-Path $WindowsRoot 'vendor/payload-lock.json'
$ValidatorPath = Join-Path $ScriptRoot 'validate-offline-payloads.ps1'
$StorePackageResolverProject = Join-Path $WindowsRoot `
    'tools/StorePackageResolver/StorePackageResolver.csproj'
$PluginSeedRoot = Join-Path $WindowsRoot 'vendor/plugin-seeds'
$PluginSeedLockPath = Join-Path $WindowsRoot 'vendor/plugin-seed-lock.json'
$PluginCatalogSource = Join-Path $WindowsRoot 'vendor/plugin-catalog.json'
$ModelCatalogSource = Join-Path $RepositoryRoot 'Resources/model-catalog.json'
$OutputFull = [IO.Path]::GetFullPath($OutputRoot)
$OutputParent = [IO.Path]::GetDirectoryName($OutputFull)
$OutputName = [IO.Path]::GetFileName($OutputFull.TrimEnd('\', '/'))
$StageRoot = Join-Path $OutputParent ".$OutputName.stage-$([Guid]::NewGuid().ToString('N'))"
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-windows-refresh-$([Guid]::NewGuid().ToString('N'))"

function Fail([string] $Message) { throw "refresh-offline-payloads: $Message" }

function Assert-RegularFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point: $Path"
    }
}

function Invoke-Download([uri] $Uri, [string] $Destination) {
    if ($Uri.Scheme -ne 'https') { Fail "refusing non-HTTPS source: $Uri" }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 -Uri $Uri.AbsoluteUri `
        -OutFile $Destination
    Assert-RegularFile $Destination "download from $Uri"
    if ((Get-Item -LiteralPath $Destination).Length -eq 0) {
        Fail "download is empty: $Uri"
    }
}

function Invoke-MicrosoftStorePackageDownload([uri] $Uri, [string] $Destination) {
    if ($Uri.Scheme -notin @('http', 'https') -or
        ($Uri.Host -cne 'dl.delivery.mp.microsoft.com' -and
         -not $Uri.Host.EndsWith(
            '.dl.delivery.mp.microsoft.com',
            [StringComparison]::OrdinalIgnoreCase))) {
        Fail "refusing untrusted Microsoft Store delivery source: $Uri"
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 -Uri $Uri.AbsoluteUri `
        -OutFile $Destination
    Assert-RegularFile $Destination "Microsoft Store package from $($Uri.Host)"
    if ((Get-Item -LiteralPath $Destination).Length -eq 0) {
        Fail "Microsoft Store package download is empty: $($Uri.Host)"
    }
}

function Assert-NotPeFile([string] $Path, [string] $Description) {
    Assert-RegularFile $Path $Description
    $stream = [IO.File]::OpenRead($Path)
    try {
        $first = $stream.ReadByte()
        $second = $stream.ReadByte()
    } finally {
        $stream.Dispose()
    }
    if ($first -eq 0x4d -and $second -eq 0x5a) {
        Fail "$Description is a Store bootstrapper EXE, not an offline Appx package"
    }
}

function Get-FileDigest([string] $Path) {
    Assert-RegularFile $Path 'payload file'
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        return [pscustomobject]@{ Sha256 = $hash; Size = $stream.Length }
    } finally { $stream.Dispose() }
}

function Compare-Utf8([string] $Left, [string] $Right) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $a = $utf8.GetBytes($Left); $b = $utf8.GetBytes($Right)
    for ($i = 0; $i -lt [Math]::Min($a.Length, $b.Length); $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return $a.Length.CompareTo($b.Length)
}

function Get-DirectoryDigest([string] $Path) {
    $rootItem = Get-Item -LiteralPath $Path -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "unsafe payload directory: $Path"
    }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "payload tree contains a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = $item.FullName.Substring($Path.TrimEnd('\', '/').Length + 1).Replace('\', '/')
            if (-not $paths.Add($relative)) {
                Fail "payload tree has a Windows case collision: $relative"
            }
            $files.Add([pscustomobject]@{ Relative = $relative; FullName = $item.FullName })
        }
    }
    $array = @($files.ToArray())
    [Array]::Sort($array, [Comparison[object]] {
        param($left, $right)
        Compare-Utf8 $left.Relative $right.Relative
    })
    $buffer = New-Object IO.MemoryStream
    $utf8 = New-Object Text.UTF8Encoding($false)
    [long] $size = 0
    try {
        foreach ($file in $array) {
            $digest = Get-FileDigest $file.FullName
            $size += [long] $digest.Size
            $bytes = $utf8.GetBytes("$($file.Relative)`0$($digest.Sha256)`0$($digest.Size)`n")
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $buffer.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        return [pscustomobject]@{
            Sha256 = $hash
            Size = $size
            FileCount = $array.Count
        }
    } finally { $buffer.Dispose() }
}

function Expand-Appx([string] $Package, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($Package, $Destination)
    } catch {
        Fail "official Store response is not an Appx archive: $($_.Exception.Message)"
    }
}

function Get-PublisherId([string] $Publisher) {
    return Get-PackagePublisherId $Publisher
}

function Get-AppxIdentity([string] $Package, [string] $ExpandedRoot) {
    $manifestPath = Join-Path $ExpandedRoot 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Expand-Appx $Package $ExpandedRoot
    }
    Assert-RegularFile $manifestPath 'AppxManifest.xml'
    [xml] $xml = Get-Content -LiteralPath $manifestPath -Raw
    $identity = $xml.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if ($null -eq $identity) { Fail "Appx identity is missing: $Package" }
    $architecture = [string] $identity.ProcessorArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architectureNode = $xml.SelectSingleNode(
            "/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='ProcessorArchitecture']")
        $architecture = [string] $architectureNode.InnerText
    }
    $family = "$($identity.Name)_$(Get-PublisherId ([string] $identity.Publisher))"
    return [pscustomobject]@{
        Name = [string] $identity.Name
        Publisher = [string] $identity.Publisher
        Version = [string] $identity.Version
        Architecture = $architecture
        PackageFamilyName = $family
        ExpandedRoot = $ExpandedRoot
    }
}

function Assert-ValidSignature([string] $Path, [string] $Description) {
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Fail "$Description Authenticode signature is not Valid: $($signature.Status)"
    }
    return $signature
}

function Resolve-StoreCodexPackage([string] $ProductId) {
    Assert-RegularFile $StorePackageResolverProject 'Store package resolver project'
    $resolverOutput = @(& dotnet run --project $StorePackageResolverProject `
        --configuration Release --no-restore -- $ProductId x64 OpenAI.Codex 2>&1)
    $resolverExitCode = $LASTEXITCODE
    if ($resolverExitCode -ne 0) {
        $summary = (@($resolverOutput | Select-Object -First 8) -join ' ')
        if ($summary.Length -gt 1000) { $summary = $summary.Substring(0, 1000) }
        Fail "Microsoft Store resolver failed ($resolverExitCode): $summary"
    }
    $matches = @($resolverOutput | Where-Object {
        [string] $_ -match
            '^OpenAI\.Codex_[0-9]+(\.[0-9]+){3}_x64__2p2nqsd0c76g0\thttps?://\S+$'
    })
    if ($matches.Count -ne 1) {
        Fail 'Microsoft Store resolver did not return exactly one x64 OpenAI.Codex package'
    }
    $parts = [string] $matches[0] -split "`t", 2
    $downloadUri = [uri] $parts[1]
    if ($downloadUri.Scheme -notin @('http', 'https') -or
        ($downloadUri.Host -cne 'dl.delivery.mp.microsoft.com' -and
         -not $downloadUri.Host.EndsWith(
            '.dl.delivery.mp.microsoft.com',
            [StringComparison]::OrdinalIgnoreCase))) {
        Fail "Microsoft Store resolver returned an untrusted CDN host: $($downloadUri.Host)"
    }
    $download = Join-Path $WorkRoot 'store/Codex.msix'
    Invoke-MicrosoftStorePackageDownload $downloadUri $download
    Assert-NotPeFile $download 'resolved official Codex package'
    [void] (Assert-ValidSignature $download 'resolved official Codex package')
    try {
        $format = Get-AppxArchiveFormat $download $WorkRoot
    } catch {
        Fail "resolved official Codex package is not Appx: $($_.Exception.Message)"
    }
    if ($format -cne 'msix') {
        Fail "resolved per-architecture Codex package must be msix, got $format"
    }
    try {
        $graph = Get-AppxPayloadGraph $download $format $WorkRoot $WorkRoot `
            ([object[]]::new(0))
    } catch {
        Fail "resolved official Codex package graph is invalid: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Graph = $graph
        PackageMoniker = $parts[0]
        DownloadURL = $downloadUri.AbsoluteUri
    }
}

function Get-PinnedPluginMarket([string] $Marketplace, [object] $SeedLock) {
    $records = @($SeedLock.marketplaces | Where-Object {
        $_.name -ceq $Marketplace
    })
    if ($records.Count -ne 1) {
        Fail "plugin seed lock must contain exactly one $Marketplace marketplace"
    }
    $record = $records[0]
    if ([string] $record.relativePath -cne $Marketplace -or
        ([string] $record.sha256) -cnotmatch '^[0-9a-f]{64}$' -or
        [long] $record.size -le 0 -or
        [int] $record.fileCount -le 0) {
        Fail "plugin seed lock metadata is invalid: $Marketplace"
    }
    $marketRoot = Join-Path $PluginSeedRoot ([string] $record.relativePath)
    $digest = Get-DirectoryDigest $marketRoot
    if ($digest.Sha256 -cne [string] $record.sha256 -or
        $digest.Size -ne [long] $record.size -or
        $digest.FileCount -ne [int] $record.fileCount) {
        Fail "plugin seed digest mismatch: $Marketplace"
    }
    $pluginsRoot = Join-Path $marketRoot 'plugins'
    if (-not (Test-Path -LiteralPath $pluginsRoot -PathType Container)) {
        Fail "plugin seed marketplace omits plugins directory: $Marketplace"
    }
    $declared = @{}
    foreach ($plugin in @($record.plugins)) {
        $id = [string] $plugin.id
        $version = [string] $plugin.version
        $manifestLicense = [string] $plugin.manifestLicense
        if ([string]::IsNullOrWhiteSpace($id) -or
            [string]::IsNullOrWhiteSpace($version) -or
            [string]::IsNullOrWhiteSpace($manifestLicense) -or
            $declared.ContainsKey($id)) {
            Fail "plugin seed lock has an invalid identity: $Marketplace/$id"
        }
        $declared[$id] = $version
        $identityPath = Join-Path $pluginsRoot "$id/.codex-plugin/plugin.json"
        Assert-RegularFile $identityPath "plugin seed identity $Marketplace/$id"
        $identity = Get-Content -LiteralPath $identityPath -Raw |
            ConvertFrom-Json
        if ($identity.name -cne $id -or
            $identity.version -cne $version -or
            $identity.license -cne $manifestLicense) {
            Fail "plugin seed identity mismatch: $Marketplace/$id"
        }
    }
    $actualDirectories = @(
        Get-ChildItem -LiteralPath $pluginsRoot -Directory -Force
    )
    if ($actualDirectories.Count -ne $declared.Count) {
        Fail "plugin seed contains an undeclared plugin: $Marketplace"
    }
    foreach ($directory in $actualDirectories) {
        if (-not $declared.ContainsKey($directory.Name)) {
            Fail "plugin seed contains an undeclared plugin: $Marketplace/$($directory.Name)"
        }
    }
    return [pscustomobject]@{
        Root = $marketRoot
        Plugins = $declared
    }
}

function New-OfflineMarketplaceMetadata(
    [string] $Marketplace,
    [object] $Catalog,
    [string] $TargetMarket
) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($plugin in @($Catalog.plugins | Where-Object {
        $_.marketplace -ceq $Marketplace -and $_.delivery -ceq 'offline'
    })) {
        $entries.Add([ordered]@{
            name = [string] $plugin.id
            source = [ordered]@{
                source = 'local'
                path = "./plugins/$($plugin.id)"
            }
        })
    }
    if ($entries.Count -eq 0) {
        Fail "offline marketplace has no selected plugins: $Marketplace"
    }
    $metadataPath = Join-Path $TargetMarket '.agents/plugins/marketplace.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $metadataPath) -Force |
        Out-Null
    Write-Utf8NoBomJson -InputObject ([ordered]@{
        name = $Marketplace
        plugins = $entries.ToArray()
    }) -Path $metadataPath
}

function Copy-PinnedPlugins([string] $CodexExpandedRoot, [string] $Destination) {
    New-Item -ItemType Directory -Path (Join-Path $Destination 'marketplaces') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Destination 'cache') -Force | Out-Null
    $catalog = Get-Content -LiteralPath $PluginCatalogSource -Raw | ConvertFrom-Json
    if ([int] $catalog.schemaVersion -ne 2 -or
        @($catalog.plugins).Count -ne 9) {
        Fail 'plugin catalog must contain exactly nine schema-2 plugins'
    }
    $offlinePlugins = @($catalog.plugins | Where-Object {
        $_.delivery -ceq 'offline'
    })
    $runtimePlugins = @($catalog.plugins | Where-Object {
        $_.delivery -ceq 'runtime'
    })
    if ($offlinePlugins.Count -ne 5 -or $runtimePlugins.Count -ne 4) {
        Fail 'plugin catalog must select five offline and four runtime plugins'
    }
    foreach ($plugin in $runtimePlugins) {
        if ($plugin.marketplace -cne 'openai-primary-runtime' -or
            $plugin.runtimeId -cne 'codex-primary-runtime') {
            Fail "invalid runtime plugin: $($plugin.marketplace)/$($plugin.id)"
        }
    }
    $expectedMarkets = @('openai-bundled', 'openai-curated')
    $seedLock = Get-Content -LiteralPath $PluginSeedLockPath -Raw |
        ConvertFrom-Json
    if ($seedLock.schemaVersion -ne 1 -or
        $seedLock.sourceRepository -cne 'https://github.com/openai/plugins' -or
        $seedLock.sourceCommit -cne
            '11c74d6ba24d3a6d48f54a194cd00ef3beea18f9' -or
        @($seedLock.marketplaces).Count -ne 1) {
        Fail 'plugin seed lock must contain one pinned public GitHub marketplace'
    }
    if (@($seedLock.marketplaces[0].localAdditions).Count -ne 1 -or
        $seedLock.marketplaces[0].localAdditions[0] -cne
            'plugins/github/LICENSE.plugin-manifest-MIT.txt') {
        Fail 'plugin seed lock must disclose the added MIT license text'
    }
    $seedMarket = Get-PinnedPluginMarket 'openai-curated' $seedLock
    $bundledCandidates = @(
        Get-ChildItem -LiteralPath $CodexExpandedRoot -Directory -Recurse -Force |
            Where-Object {
                $_.Name -ceq 'openai-bundled' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'plugins') -PathType Container)
            }
    )
    if ($bundledCandidates.Count -ne 1) {
        Fail 'official Codex payload must contain exactly one openai-bundled marketplace'
    }
    foreach ($market in $expectedMarkets) {
        $targetMarket = Join-Path $Destination "marketplaces/$market"
        New-Item -ItemType Directory -Path (Join-Path $targetMarket 'plugins') -Force |
            Out-Null
        New-OfflineMarketplaceMetadata $market $catalog $targetMarket
    }
    foreach ($plugin in $offlinePlugins) {
        $source = Join-Path $Destination "marketplaces/$($plugin.marketplace)/plugins/$($plugin.id)"
        $upstreamPlugin = if ($plugin.marketplace -ceq 'openai-bundled') {
            $candidate = Join-Path $bundledCandidates[0].FullName "plugins/$($plugin.id)"
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                Fail "official Codex payload omits bundled plugin $($plugin.id)"
            }
            $candidate
        } else {
            if (-not $seedMarket.Plugins.ContainsKey([string] $plugin.id)) {
                Fail "plugin seed lock omits $($plugin.marketplace)/$($plugin.id)"
            }
            Join-Path $seedMarket.Root "plugins/$($plugin.id)"
        }
        if (-not (Test-Path -LiteralPath $source)) {
            Copy-Item -LiteralPath $upstreamPlugin -Destination $source -Recurse
        }
        Assert-RegularFile (Join-Path $source '.codex-plugin/plugin.json') `
            "plugin identity $($plugin.marketplace)/$($plugin.id)"
        $identity = Get-Content -LiteralPath (Join-Path $source '.codex-plugin/plugin.json') -Raw |
            ConvertFrom-Json
        if ($identity.name -cne $plugin.id -or [string]::IsNullOrWhiteSpace([string] $identity.version)) {
            Fail "plugin identity mismatch: $($plugin.marketplace)/$($plugin.id)"
        }
        $cache = Join-Path $Destination "cache/$($plugin.marketplace)/$($plugin.id)/$($identity.version)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $cache) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $cache -Recurse
    }
}

function Copy-ScriptMarket(
    [string] $Commit,
    [string] $ExpectedIndexSha,
    [string] $Destination
) {
    New-Item -ItemType Directory -Path (Join-Path $Destination 'scripts') -Force | Out-Null
    $base = "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/$Commit"
    $upstreamIndexPath = Join-Path $Destination 'upstream-index.json'
    Invoke-Download ([uri] "$base/index.json") $upstreamIndexPath
    if ((Get-FileDigest $upstreamIndexPath).Sha256 -cne $ExpectedIndexSha) {
        Fail 'script-market upstream index hash does not match payload lock'
    }
    $index = Get-Content -LiteralPath $upstreamIndexPath -Raw | ConvertFrom-Json
    $overrides = @((Get-Content -LiteralPath (
        Join-Path $RepositoryRoot 'Resources/script-market-overrides.json') -Raw |
        ConvertFrom-Json).overrides)
    $seen = @{}
    foreach ($script in @($index.scripts)) {
        if ([string]::IsNullOrWhiteSpace([string] $script.id) -or
            ([string] $script.sha256) -cnotmatch '^[0-9A-Fa-f]{64}$' -or
            $seen.ContainsKey([string] $script.id)) {
            Fail 'script-market index contains an unsafe or duplicate entry'
        }
        $seen[[string] $script.id] = $true
        $source = Resolve-ImmutableScriptSource -ScriptUrl ([string] $script.script_url) `
            -Id ([string] $script.id) -Commit $Commit -Overrides $overrides
        $target = Join-Path $Destination $source.LocalPath
        if ($source.SourceKind -ceq 'managed') {
            if ([string] $source.UpstreamSha256 -cne
                    ([string] $script.sha256).ToLowerInvariant()) {
                Fail "managed script upstream hash mismatch: $($script.id)"
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) `
                -Force | Out-Null
            Copy-Item -LiteralPath $source.SourcePath -Destination $target
        } else {
            Invoke-Download ([uri] $source.SourceUrl) $target
        }
        $actual = Get-FileDigest $target
        $expectedFinal = if ([string]::IsNullOrWhiteSpace([string] $source.Sha256)) {
            ([string] $script.sha256).ToLowerInvariant()
        } else {
            [string] $source.Sha256
        }
        if ($actual.Sha256 -cne $expectedFinal) {
            Fail "script-market hash mismatch: $($script.id)"
        }
        $script.sha256 = $actual.Sha256
        $script.script_url = $source.SourceUrl
        $script | Add-Member -NotePropertyName local_path -NotePropertyValue $source.LocalPath
        $script | Add-Member -NotePropertyName source_commit -NotePropertyValue $source.SourceCommit
        $script | Add-Member -NotePropertyName upstream_url -NotePropertyValue $source.UpstreamUrl
    }
    Write-Utf8NoBomJson -InputObject $index -Path (Join-Path $Destination 'index.json')
}

function New-PayloadEntry(
    [string] $Id, [string] $Version, [string] $Architecture,
    [string] $RelativePath, [string] $SourceURL, [string] $Format,
    [hashtable] $Optional = @{}) {
    $target = Join-Path $StageRoot $RelativePath
    $digest = if ($Format -eq 'directory') {
        Get-DirectoryDigest $target
    } else {
        Get-FileDigest $target
    }
    $entry = [ordered]@{
        id = $Id; version = $Version; architecture = $Architecture
        relativePath = $RelativePath.Replace('\', '/')
        sha256 = $digest.Sha256; size = [long] $digest.Size
        sourceURL = $SourceURL; format = $Format
    }
    foreach ($key in $Optional.Keys) { $entry[$key] = $Optional[$key] }
    return $entry
}

try {
    foreach ($file in @($SourcesPath, $LockPath, $ValidatorPath,
            $StorePackageResolverProject,
            $PluginSeedLockPath,
            $PluginCatalogSource, $ModelCatalogSource,
            $CodexPlusPlusSetup, $CodexPlusPlusSource)) {
        Assert-RegularFile ([IO.Path]::GetFullPath($file)) 'required input'
    }
    if (-not (Test-Path -LiteralPath $PluginSeedRoot -PathType Container)) {
        Fail "plugin seed root is missing: $PluginSeedRoot"
    }
    $sources = Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json
    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    try { Assert-PayloadLockMatchesPolicy $lock (Get-WindowsPayloadPolicy) }
    catch { Fail $_.Exception.Message }
    if ($sources.schemaVersion -ne 2 -or $lock.schemaVersion -ne 2 -or
        $sources.codexStoreProductId -cne '9PLM9XGG6VKS' -or
        $sources.codexStoreListingURL -cne
            'https://apps.microsoft.com/detail/9PLM9XGG6VKS' -or
        $sources.codexPlusPlusTag -cne 'v1.2.44' -or
        $sources.scriptMarketCommit -cne 'b3c1d16d7d75145b9cf5b0e34000316436d905dd') {
        Fail 'upstream source or payload lock is not the approved schema-2 lock'
    }
    if ($lock.scriptMarket.indexSha256 -cne
        '0776ecee1165babd3794fa3a740433b5326549bc8c5d8546aa4f8bb52374d540') {
        Fail 'payload lock does not contain the approved script-market index hash'
    }
    if ((Split-Path -Leaf $CodexPlusPlusSetup) -cnotmatch
        '^CodexPlusPlus-1\.2\.43-codexkit\.1-windows-x64-setup\.exe$' -or
        (Split-Path -Leaf $CodexPlusPlusSource) -cnotmatch
        '^CodexPlusPlus-v1\.2\.44-codexkit\.1-source\.tar\.gz$') {
        Fail 'Codex++ inputs are not the exact Task 3 v1.2.44+codexkit.1 artifacts'
    }

    New-Item -ItemType Directory -Path $OutputParent, $StageRoot, $WorkRoot -Force | Out-Null
    Assert-ReparseFreeAbsolutePath $OutputParent 'output parent' | Out-Null
    foreach ($directory in @('apps', 'sources', 'plugins', 'script-market', 'metadata')) {
        New-Item -ItemType Directory -Path (Join-Path $StageRoot $directory) -Force | Out-Null
    }

    $resolvedStore = Resolve-StoreCodexPackage $sources.codexStoreProductId
    $graph = $resolvedStore.Graph
    $identity = $graph.Main.Identity
    if ($identity.Architecture -cne 'x64' -or
        $identity.PackageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0') {
        Fail "official Codex identity mismatch: $($identity.PackageFamilyName) $($identity.Architecture)"
    }
    foreach ($signedPackage in @($graph.SignedPackages)) {
        $signature = Assert-ValidSignature $signedPackage.Path 'official Codex graph package'
        if ($signature.SignerCertificate.Subject -cne $signedPackage.Identity.Publisher) {
            Fail 'official Codex graph signer subject does not match actual Appx publisher'
        }
    }
    $codexRelative = 'apps/Codex.msix'
    Copy-Item -LiteralPath $graph.Main.Path -Destination (Join-Path $StageRoot $codexRelative)

    $dependencyEntries = New-Object 'System.Collections.Generic.List[object]'
    $dependencyIndex = 0
    foreach ($dependency in @($graph.Dependencies)) {
        $dependencyIdentity = $dependency.Identity
        $extension = if ($dependency.Format -ceq 'msixbundle') {
            '.msixbundle'
        } else { '.msix' }
        $relative = "apps/dependencies/Codex-dependency-$dependencyIndex$extension"
        New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $StageRoot $relative)) -Force |
            Out-Null
        Copy-Item -LiteralPath $dependency.Path -Destination (Join-Path $StageRoot $relative)
        $dependencyEntries.Add((New-PayloadEntry "codex-dependency-$dependencyIndex" `
            $dependencyIdentity.Version $dependencyIdentity.Architecture $relative `
            $sources.codexStoreListingURL $dependency.Format @{
                packageName = $dependencyIdentity.Name
                packageFamilyName = $dependencyIdentity.PackageFamilyName
                publisher = $dependencyIdentity.Publisher
                minimumVersion = $dependency.MinimumVersion
            }))
        $dependencyIndex++
    }

    $cppRelative = 'apps/CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe'
    $sourceRelative = 'sources/CodexPlusPlus-v1.2.44-codexkit.1-source.tar.gz'
    Copy-Item -LiteralPath $CodexPlusPlusSetup -Destination (Join-Path $StageRoot $cppRelative)
    Copy-Item -LiteralPath $CodexPlusPlusSource -Destination (Join-Path $StageRoot $sourceRelative)

    Copy-Item -LiteralPath $LockPath -Destination (Join-Path $StageRoot 'payload-lock.json')
    $modelSource = $ModelCatalogSource
    if ($UseCachedModelCatalog -and
        (Test-Path -LiteralPath (Join-Path $OutputFull 'current.json') -PathType Leaf)) {
        $activeOutput = Resolve-ActivePayloadRoot $OutputFull
        $cached = Join-Path $activeOutput 'model-catalog.json'
        if ((Get-FileDigest $cached).Sha256 -cne (Get-FileDigest $ModelCatalogSource).Sha256) {
            Fail 'cached model catalog differs from the pinned repository resource'
        }
        $modelSource = $cached
    }
    Copy-Item -LiteralPath $modelSource -Destination (Join-Path $StageRoot 'model-catalog.json')
    Copy-PinnedPlugins $identity.ExpandedRoot (Join-Path $StageRoot 'plugins')
    Copy-Item -LiteralPath $PluginCatalogSource `
        -Destination (Join-Path $StageRoot 'plugins/plugin-catalog.json')
    Copy-ScriptMarket $sources.scriptMarketCommit $lock.scriptMarket.indexSha256 `
        (Join-Path $StageRoot 'script-market')

    $licenseManifest = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        packages = @(
            [ordered]@{ id = 'codex-plus-plus-windows-x64'; licenseID = 'AGPL-3.0-only'; source = $sourceRelative }
            [ordered]@{ id = 'codex-plus-plus-source'; licenseID = 'AGPL-3.0-only'; sourceURL = $sources.codexPlusPlusSource }
        )
    }
    Write-Utf8NoBomJson -InputObject $licenseManifest `
        -Path (Join-Path $StageRoot 'metadata/third-party-licenses.json')

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $entries.Add((New-PayloadEntry 'codex-windows-x64' $identity.Version 'x64' `
        $codexRelative $sources.codexStoreListingURL $graph.Main.Format @{
            packageFamilyName = $identity.PackageFamilyName
            publisher = $identity.Publisher
            packageName = $identity.Name
        }))
    foreach ($entry in $dependencyEntries) { $entries.Add($entry) }
    $entries.Add((New-PayloadEntry 'codex-plus-plus-windows-x64' '1.2.44+codexkit.1' 'x64' `
        $cppRelative $sources.codexPlusPlusSource 'exe' @{
            compatibilityRevision = 'cross-provider-content-v1'; licenseID = 'AGPL-3.0-only'
            authenticodePolicy = 'unsigned'
        }))
    $entries.Add((New-PayloadEntry 'codex-plus-plus-source' '1.2.44+codexkit.1' 'source' `
        $sourceRelative $sources.codexPlusPlusSource 'archive' @{
            compatibilityRevision = 'cross-provider-content-v1'; licenseID = 'AGPL-3.0-only'
        }))
    $entries.Add((New-PayloadEntry 'model-catalog' '1' 'any' 'model-catalog.json' `
        'https://github.com/openai/codex' 'json'))
    $entries.Add((New-PayloadEntry 'plugin-marketplaces' $identity.Version 'any' 'plugins' `
        $sources.codexStoreListingURL 'directory'))
    $entries.Add((New-PayloadEntry 'script-market' $sources.scriptMarketCommit 'any' 'script-market' `
        "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/$($sources.scriptMarketCommit)/index.json" `
        'directory'))

    $payloadManifest = [ordered]@{
        schemaVersion = 2
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        platform = 'windows'
        files = $entries.ToArray()
    }
    Write-Utf8NoBomJson -InputObject $payloadManifest `
        -Path (Join-Path $StageRoot 'payload-manifest.json')

    & $ValidatorPath -PayloadRoot $StageRoot -StrictSignatures -StagedGeneration

    $generationId = "{0}-{1}" -f
        (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'),
        ([Guid]::NewGuid().ToString('N'))
    Publish-PayloadGeneration -StageRoot $StageRoot -OutputRoot $OutputFull `
        -GenerationId $generationId
    Write-Output "refresh-offline-payloads: PASS ($OutputFull)"
} finally {
    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force
    }
}
