#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $ResolveLive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$AttributesPath = Join-Path $RepositoryRoot '.gitattributes'
$OfflineSupplyTests = Join-Path $PSScriptRoot 'OfflinePayloadSupply.Tests.ps1'
$Project = Join-Path $WindowsRoot 'tools/StorePackageResolver/StorePackageResolver.csproj'
$Program = Join-Path $WindowsRoot 'tools/StorePackageResolver/Program.cs'
$License = Join-Path $WindowsRoot 'tools/StorePackageResolver/LICENSE.codex-app-mirror.txt'
$Refresh = Join-Path $WindowsRoot 'scripts/refresh-offline-payloads.ps1'
$SourcesPath = Join-Path $WindowsRoot 'vendor/upstream-sources.json'
$PluginCatalogPath = Join-Path $WindowsRoot 'vendor/plugin-catalog.json'
$PluginSeedRoot = Join-Path $WindowsRoot 'vendor/plugin-seeds'
$PluginSeedLockPath = Join-Path $WindowsRoot 'vendor/plugin-seed-lock.json'

function Fail([string] $Message) {
    throw "StoreDelivery.Tests: $Message"
}

foreach ($path in @(
        $Project,
        $Program,
        $License,
        $AttributesPath,
        $OfflineSupplyTests,
        $Refresh,
        $SourcesPath,
        $PluginCatalogPath,
        $PluginSeedLockPath
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "missing required file: $path"
    }
}
if (-not (Test-Path -LiteralPath $PluginSeedRoot -PathType Container)) {
    Fail "missing pinned plugin seed root: $PluginSeedRoot"
}

& $OfflineSupplyTests

$programText = Get-Content -LiteralPath $Program -Raw
$refreshText = Get-Content -LiteralPath $Refresh -Raw
$attributesText = Get-Content -LiteralPath $AttributesPath -Raw
$sources = Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json
$pluginCatalog = Get-Content -LiteralPath $PluginCatalogPath -Raw | ConvertFrom-Json
if (-not $attributesText.Contains('windows/vendor/plugin-seeds/** -text')) {
    Fail 'Git attributes do not preserve byte-for-byte plugin seed payloads'
}

foreach ($value in @(
    'https://displaycatalog.mp.microsoft.com/v7.0/products',
    'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx',
    'dl.delivery.mp.microsoft.com',
    'OpenAI.Codex'
)) {
    if (-not $programText.Contains($value)) {
        Fail "resolver omits required Microsoft delivery contract: $value"
    }
}
foreach ($value in @(
    'StorePackageResolver.csproj',
    'codexStoreProductId',
    'OpenAI.Codex',
    'Resolve-StoreCodexPackage',
    'Assert-NotPeFile',
    'Get-AppxPayloadGraph',
    'plugin-seed-lock.json',
    'Get-PinnedPluginMarket',
    'New-OfflineMarketplaceMetadata'
)) {
    if (-not $refreshText.Contains($value)) {
        Fail "refresh script omits required Store resolver contract: $value"
    }
}
if ($refreshText.Contains('codexStoreDirectDownload')) {
    Fail 'refresh script still depends on the obsolete Store bootstrapper URL'
}
if ($refreshText.Contains('files = @($entries)')) {
    Fail 'refresh script uses the broken array subexpression on a New-Object List[object]'
}
$signatureGate = $refreshText.IndexOf(
    "Assert-ValidSignature `$download 'resolved official Codex package'",
    [StringComparison]::Ordinal)
$archiveProbe = $refreshText.IndexOf(
    'Get-AppxArchiveFormat $download',
    [StringComparison]::Ordinal)
if ($signatureGate -lt 0 -or $archiveProbe -lt 0 -or
    $signatureGate -gt $archiveProbe) {
    Fail 'Store MSIX signature must be validated before archive expansion'
}
if ($sources.codexStoreProductId -cne '9PLM9XGG6VKS' -or
    $sources.codexStoreListingURL -cne
        'https://apps.microsoft.com/detail/9PLM9XGG6VKS') {
    Fail 'pinned Store ProductId or listing URL is wrong'
}

function Get-FileDigest([string] $Path) {
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString(
                $sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        return [pscustomobject]@{ Sha256 = $hash; Size = $stream.Length }
    } finally {
        $stream.Dispose()
    }
}

function Compare-Utf8([string] $Left, [string] $Right) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $leftBytes = $utf8.GetBytes($Left)
    $rightBytes = $utf8.GetBytes($Right)
    for ($index = 0;
         $index -lt [Math]::Min($leftBytes.Length, $rightBytes.Length);
         $index++) {
        if ($leftBytes[$index] -lt $rightBytes[$index]) { return -1 }
        if ($leftBytes[$index] -gt $rightBytes[$index]) { return 1 }
    }
    return $leftBytes.Length.CompareTo($rightBytes.Length)
}

function Get-DirectoryDigest([string] $Path) {
    $root = Get-Item -LiteralPath $Path -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "unsafe pinned plugin market: $Path"
    }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $relativePaths = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "pinned plugin market contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring(
            $Path.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        if (-not $relativePaths.Add($relative)) {
            Fail "pinned plugin market has a Windows case collision: $relative"
        }
        $files.Add([pscustomobject]@{
            Relative = $relative
            FullName = $item.FullName
        })
    }
    $ordered = @($files.ToArray())
    [Array]::Sort($ordered, [Comparison[object]] {
        param($left, $right)
        Compare-Utf8 $left.Relative $right.Relative
    })
    $buffer = New-Object IO.MemoryStream
    $utf8 = New-Object Text.UTF8Encoding($false)
    [long] $size = 0
    try {
        foreach ($file in $ordered) {
            $digest = Get-FileDigest $file.FullName
            $size += [long] $digest.Size
            $bytes = $utf8.GetBytes(
                "$($file.Relative)`0$($digest.Sha256)`0$($digest.Size)`n")
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $buffer.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString(
                $sha.ComputeHash($buffer))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        return [pscustomobject]@{
            Sha256 = $hash
            Size = $size
            FileCount = $ordered.Count
        }
    } finally {
        $buffer.Dispose()
    }
}

$seedLock = Get-Content -LiteralPath $PluginSeedLockPath -Raw | ConvertFrom-Json
$expectedSeedPlugins = [ordered]@{
    'openai-curated' = [ordered]@{
        github = '0.1.6'
    }
}
if ($seedLock.schemaVersion -ne 1 -or
    $seedLock.sourceRepository -cne 'https://github.com/openai/plugins' -or
    $seedLock.sourceCommit -cne '11c74d6ba24d3a6d48f54a194cd00ef3beea18f9' -or
    @($seedLock.marketplaces).Count -ne $expectedSeedPlugins.Count) {
    Fail 'public plugin seed provenance, schema or marketplace count is wrong'
}
$mitLicensePath = Join-Path $PluginSeedRoot `
    'openai-curated/plugins/github/LICENSE.plugin-manifest-MIT.txt'
if (@($seedLock.marketplaces[0].localAdditions).Count -ne 1 -or
    $seedLock.marketplaces[0].localAdditions[0] -cne
        'plugins/github/LICENSE.plugin-manifest-MIT.txt' -or
    -not (Test-Path -LiteralPath $mitLicensePath -PathType Leaf)) {
    Fail 'public plugin seed must disclose and carry its MIT license text'
}
foreach ($marketplace in $expectedSeedPlugins.Keys) {
    $records = @($seedLock.marketplaces | Where-Object {
        $_.name -ceq $marketplace
    })
    if ($records.Count -ne 1) {
        Fail "pinned plugin seed lock must contain exactly one $marketplace"
    }
    $record = $records[0]
    if ([string] $record.relativePath -cne $marketplace -or
        ([string] $record.sha256) -cnotmatch '^[0-9a-f]{64}$' -or
        [long] $record.size -le 0 -or
        [int] $record.fileCount -le 0) {
        Fail "pinned plugin seed lock metadata is invalid: $marketplace"
    }
    $marketRoot = Join-Path $PluginSeedRoot ([string] $record.relativePath)
    $digest = Get-DirectoryDigest $marketRoot
    if ($digest.Sha256 -cne [string] $record.sha256 -or
        $digest.Size -ne [long] $record.size -or
        $digest.FileCount -ne [int] $record.fileCount) {
        Fail "pinned plugin seed digest mismatch: $marketplace"
    }
    $expectedPlugins = $expectedSeedPlugins[$marketplace]
    if (@($record.plugins).Count -ne $expectedPlugins.Count) {
        Fail "pinned plugin seed inventory count is wrong: $marketplace"
    }
    foreach ($pluginId in $expectedPlugins.Keys) {
        $pluginRecords = @($record.plugins | Where-Object {
            $_.id -ceq $pluginId -and
            $_.version -ceq $expectedPlugins[$pluginId] -and
            $_.manifestLicense -ceq 'MIT'
        })
        $identityPath = Join-Path $marketRoot `
            "plugins/$pluginId/.codex-plugin/plugin.json"
        if ($pluginRecords.Count -ne 1 -or
            -not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            Fail "pinned plugin seed identity is missing: $marketplace/$pluginId"
        }
        $identity = Get-Content -LiteralPath $identityPath -Raw |
            ConvertFrom-Json
        if ($identity.name -cne $pluginId -or
            $identity.version -cne $expectedPlugins[$pluginId] -or
            $identity.license -cne 'MIT') {
            Fail "pinned plugin seed identity mismatch: $marketplace/$pluginId"
        }
    }
}

$offlinePlugins = @($pluginCatalog.plugins | Where-Object delivery -CEQ 'offline')
$runtimePlugins = @($pluginCatalog.plugins | Where-Object delivery -CEQ 'runtime')
if ($pluginCatalog.schemaVersion -ne 2 -or
    $offlinePlugins.Count -ne 5 -or
    $runtimePlugins.Count -ne 4 -or
    @($runtimePlugins | Where-Object {
        $_.marketplace -cne 'openai-primary-runtime' -or
        $_.runtimeId -cne 'codex-primary-runtime'
    }).Count -ne 0 -or
    (Test-Path -LiteralPath (
        Join-Path $PluginSeedRoot 'openai-primary-runtime'))) {
    Fail 'plugin delivery policy must be five offline plus four unvendored runtime plugins'
}

dotnet build $Project -c Release --no-restore
if ($LASTEXITCODE -ne 0) {
    Fail "resolver build failed with exit code $LASTEXITCODE"
}

if ($ResolveLive) {
    $output = @(& dotnet run --project $Project -c Release --no-build -- `
        $sources.codexStoreProductId x64 OpenAI.Codex)
    if ($LASTEXITCODE -ne 0) {
        Fail "live resolver failed with exit code $LASTEXITCODE"
    }
    $line = @($output | Where-Object {
        [string] $_ -match
            '^OpenAI\.Codex_[0-9]+(\.[0-9]+){3}_x64__2p2nqsd0c76g0\thttps?://'
    })
    if ($line.Count -ne 1) {
        Fail 'live resolver did not return exactly one pinned x64 Codex package'
    }
    $parts = [string] $line[0] -split "`t", 2
    if ($parts.Count -ne 2) {
        Fail 'live resolver output is malformed'
    }
    $uri = [uri] $parts[1]
    if ($uri.Scheme -notin @('http', 'https') -or
        ($uri.Host -cne 'dl.delivery.mp.microsoft.com' -and
         -not $uri.Host.EndsWith(
            '.dl.delivery.mp.microsoft.com',
            [StringComparison]::OrdinalIgnoreCase))) {
        Fail "live resolver returned an untrusted CDN host: $($uri.Host)"
    }
}

Write-Output 'StoreDelivery.Tests: PASS'
