#Requires -Version 5.1
<#
.SYNOPSIS
Validates a complete Windows offline payload snapshot without modifying it.

.DESCRIPTION
Production snapshots require -StrictSignatures. The only non-strict mode is
the checked-in tiny fixture under windows/tests/fixtures/payload-root. A
non-Windows host can validate that fixture's schema, identity, paths and
hashes, but can never report a production Authenticode check as successful.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PayloadRoot,
    [switch] $StrictSignatures,
    [switch] $FixtureMode,
    [switch] $StagedGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot 'offline-payload-supply.ps1')
$InputPayloadRoot = [IO.Path]::GetFullPath($PayloadRoot)
if ($FixtureMode -and $StagedGeneration) {
    throw 'validate-offline-payloads: FixtureMode and StagedGeneration are mutually exclusive'
}
$ResolvedPayloadRoot = if ($StagedGeneration) {
    Assert-ReparseFreeAbsolutePath $InputPayloadRoot 'staged payload generation'
} else {
    Resolve-ActivePayloadRoot $InputPayloadRoot -FixtureMode:$FixtureMode
}
$ManifestPath = Join-Path $ResolvedPayloadRoot 'payload-manifest.json'
$ShaPattern = '^[0-9a-f]{64}$'

function Fail([string] $Message) {
    throw "validate-offline-payloads: $Message"
}

function Assert-RegularPath([string] $Path, [bool] $Directory, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path)) { Fail "$Description is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic link or reparse point: $Path"
    }
    if ($Directory -ne $item.PSIsContainer) {
        Fail "$Description has the wrong file type: $Path"
    }
}

function Assert-NoReparseAncestors([string] $Path, [string] $Description) {
    try { Assert-ReparseFreeAbsolutePath $Path $Description | Out-Null }
    catch { Fail $_.Exception.Message }
}

function Normalize-RelativePath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Fail 'relativePath is empty' }
    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') {
        Fail "unsafe relativePath: $Path"
    }
    $segments = @($normalized.Split('/'))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or
            $segment -eq '..' -or $segment.EndsWith(' ') -or
            $segment.EndsWith('.') -or $segment -match '[<>:"|?*\x00-\x1f]' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            Fail "unsafe relativePath: $Path"
        }
    }
    return ($segments -join '/')
}

function Resolve-PayloadPath([string] $RelativePath) {
    $normalized = Normalize-RelativePath $RelativePath
    $current = $ResolvedPayloadRoot
    foreach ($segment in $normalized.Split('/')) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "payload path contains a symbolic link or reparse point: $current"
            }
        }
    }
    $candidate = [IO.Path]::GetFullPath(
        (Join-Path $ResolvedPayloadRoot ($normalized.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $prefix = $ResolvedPayloadRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "relativePath escapes payload root: $RelativePath"
    }
    return $candidate
}

function Get-FileDigest([string] $Path) {
    Assert-RegularPath $Path $false 'payload file'
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        return [pscustomobject]@{ Sha256 = $digest; Size = $stream.Length }
    } finally {
        $stream.Dispose()
    }
}

function Compare-Utf8([string] $Left, [string] $Right) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $leftBytes = $utf8.GetBytes($Left)
    $rightBytes = $utf8.GetBytes($Right)
    $common = [Math]::Min($leftBytes.Length, $rightBytes.Length)
    for ($index = 0; $index -lt $common; $index++) {
        if ($leftBytes[$index] -lt $rightBytes[$index]) { return -1 }
        if ($leftBytes[$index] -gt $rightBytes[$index]) { return 1 }
    }
    return $leftBytes.Length.CompareTo($rightBytes.Length)
}

function Get-DirectoryDigest([string] $Path) {
    Assert-RegularPath $Path $true 'payload directory'
    $files = New-Object 'System.Collections.Generic.List[object]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $windowsPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "payload tree contains a symbolic link or reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            } else {
                $relative = $item.FullName.Substring($Path.TrimEnd('\', '/').Length + 1)
                $relative = Normalize-RelativePath $relative
                if (-not $windowsPaths.Add($relative)) {
                    Fail "directory path collision under Windows case rules: $relative"
                }
                $files.Add([pscustomobject]@{ Relative = $relative; FullName = $item.FullName })
            }
        }
    }
    $array = @($files.ToArray())
    [Array]::Sort($array, [Comparison[object]] {
        param($left, $right)
        Compare-Utf8 $left.Relative $right.Relative
    })
    $tree = New-Object IO.MemoryStream
    $totalSize = [long] 0
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        foreach ($file in $array) {
            $digest = Get-FileDigest $file.FullName
            $totalSize += [long] $digest.Size
            $record = "$($file.Relative)`0$($digest.Sha256)`0$($digest.Size)`n"
            $bytes = $utf8.GetBytes($record)
            $tree.Write($bytes, 0, $bytes.Length)
        }
        $tree.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($tree))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        return [pscustomobject]@{ Sha256 = $hash; Size = $totalSize }
    } finally {
        $tree.Dispose()
    }
}

function Get-RequiredProperty($Object, [string] $Name) {
    if (-not ($Object.PSObject.Properties.Name -contains $Name)) {
        Fail "required property is missing: $Name"
    }
    return $Object.$Name
}

function Get-OptionalProperty($Object, [string] $Name) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $null
}

Assert-NoReparseAncestors $ResolvedPayloadRoot 'payload root'
Assert-RegularPath $ResolvedPayloadRoot $true 'payload root'
Assert-RegularPath $ManifestPath $false 'payload manifest'
$LockPath = Join-Path $ResolvedPayloadRoot 'payload-lock.json'
Assert-RegularPath $LockPath $false 'payload lock'
try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
} catch {
    Fail "payload JSON is invalid: $($_.Exception.Message)"
}
if ([int] (Get-RequiredProperty $manifest 'schemaVersion') -ne 2 -or
    [int] (Get-RequiredProperty $lock 'schemaVersion') -ne 2) {
    Fail 'manifest and payload-lock schemaVersion must be 2'
}
$manifestFixture = (Get-OptionalProperty $manifest 'fixture') -eq $true
$lockFixture = (Get-OptionalProperty $lock 'fixture') -eq $true
if ($FixtureMode -and (-not $manifestFixture -or -not $lockFixture)) {
    Fail '-FixtureMode requires explicit fixture markers in manifest and lock'
}
if (-not $FixtureMode -and ($manifestFixture -or $lockFixture)) {
    Fail 'fixture payload requires the explicit -FixtureMode switch'
}
if (-not $StrictSignatures -and -not $FixtureMode) {
    Fail 'production validation requires -StrictSignatures'
}
if ($StrictSignatures -and $env:OS -ne 'Windows_NT') {
    Fail 'StrictSignatures requires Windows; non-Windows Authenticode is never accepted'
}
$policy = Get-WindowsPayloadPolicy -FixtureMode:$FixtureMode
try { Assert-PayloadLockMatchesPolicy $lock $policy }
catch { Fail $_.Exception.Message }
if (-not $FixtureMode) {
    if ($lock.scriptMarket.commit -cne
            'b3c1d16d7d75145b9cf5b0e34000316436d905dd' -or
        $lock.scriptMarket.indexSha256 -cne
            '0776ecee1165babd3794fa3a740433b5326549bc8c5d8546aa4f8bb52374d540') {
        Fail 'production script-market commit or fixed index SHA256 is not approved'
    }
    $approvedMonitoring = @{
        'codex-context-used-meter' = @(
            '101', '7d1f79dd2f379bf25787ed1fc65778266fd286cd33966692708f985fe3adba7d')
        'codex-token-usage' = @(
            '0.1.7', 'bf233607f8e60f56b3c68d29c15bbd5ed5d7582fc488380f56b8d2f553bb4ddd')
        'codex-daily-token-usage' = @(
            '1.4.13', '80f5efb88d1e2e0da5c22f229b65d08710460a7c258bdaea7b82a84071fb7576')
        'codex-live-token-cost' = @(
            '0.7.2', 'aee6bf61236aa9edf183a71bba5a45cbb1f273f94e2197d4421d557999de5da8')
    }
    if (@($lock.monitoringScripts).Count -ne $approvedMonitoring.Count) {
        Fail 'production payload-lock must pin exactly four monitoring scripts'
    }
    foreach ($pin in @($lock.monitoringScripts)) {
        if (-not $approvedMonitoring.ContainsKey([string] $pin.id) -or
            $pin.version -cne $approvedMonitoring[[string] $pin.id][0] -or
            $pin.sha256 -cne $approvedMonitoring[[string] $pin.id][1]) {
            Fail "unapproved production monitoring script pin: $($pin.id)"
        }
    }
}

$requiredIds = @($policy.RequiredComponents)
if ((Compare-Object $requiredIds @($lock.requiredComponents))) {
    Fail 'payload-lock requiredComponents is not the canonical six-component set'
}
$entries = @($manifest.files)
$byId = @{}
$byPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
    [StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    $id = [string] (Get-RequiredProperty $entry 'id')
    if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
        Fail "empty or duplicate payload id: $id"
    }
    if ($id -notin $requiredIds -and $id -cnotmatch '^codex-dependency-[0-9]+$') {
        Fail "unexpected payload id: $id"
    }
    $entry.relativePath = Normalize-RelativePath (
        [string] (Get-RequiredProperty $entry 'relativePath'))
    if ($byPath.ContainsKey($entry.relativePath)) {
        Fail "relativePath collision under Windows case rules: $($entry.relativePath)"
    }
    $byPath.Add($entry.relativePath, $id)
    if ([string] (Get-RequiredProperty $entry 'sha256') -cnotmatch $ShaPattern -or
        [long] (Get-RequiredProperty $entry 'size') -lt 0) {
        Fail "invalid hash or size for $id"
    }
    foreach ($property in @('version', 'architecture', 'sourceURL', 'format')) {
        if ([string]::IsNullOrWhiteSpace([string] (Get-RequiredProperty $entry $property))) {
            Fail "empty $property for $id"
        }
    }
    $sourceUri = $null
    if (-not [Uri]::TryCreate([string] $entry.sourceURL, [UriKind]::Absolute,
            [ref] $sourceUri) -or $sourceUri.Scheme -cne 'https') {
        Fail "sourceURL must be absolute HTTPS for $id"
    }
    $byId[$id] = $entry
}
foreach ($id in $requiredIds) {
    if (-not $byId.ContainsKey($id)) { Fail "missing required component: $id" }
    $component = $policy.Components[$id]
    if ($byId[$id].relativePath -cne
            (Normalize-RelativePath ([string] $component.relativePath)) -or
        $byId[$id].format -cne [string] $component.format) {
        Fail "canonical path or format mismatch for $id"
    }
}
foreach ($entry in @($entries | Where-Object id -Like 'codex-dependency-*')) {
    $expectedExtension = if ($entry.format -ceq 'msix') {
        'msix'
    } elseif ($entry.format -ceq 'msixbundle') {
        'msixbundle'
    } else { '' }
    if ([string]::IsNullOrEmpty($expectedExtension) -or
        $entry.relativePath -cnotmatch
            "^apps/dependencies/Codex-dependency-[0-9]+\.$expectedExtension$") {
        Fail "dependency path or format is not canonical: $($entry.id)"
    }
}

$codex = $byId['codex-windows-x64']
if ($codex.architecture -cne [string] $lock.codex.architecture -or
    $codex.packageFamilyName -cne [string] $lock.codex.packageFamilyName -or
    $codex.packageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0') {
    Fail 'Codex x64 manifest identity does not match payload-lock'
}
$cpp = $byId['codex-plus-plus-windows-x64']
$source = $byId['codex-plus-plus-source']
foreach ($item in @($cpp, $source)) {
    if ($item.compatibilityRevision -cne [string] $lock.codexPlusPlus.compatibilityRevision -or
        $item.licenseID -cne [string] $lock.codexPlusPlus.licenseID) {
        Fail 'Codex++ revision or license does not match payload-lock'
    }
}
if ($cpp.version -cne [string] $lock.codexPlusPlus.payloadVersion -or
    $source.version -cne $cpp.version -or
    $cpp.architecture -cne [string] $lock.codexPlusPlus.architecture) {
    Fail 'Codex++ version or architecture does not match payload-lock'
}
if ([string] (Get-RequiredProperty $cpp 'authenticodePolicy') -cne 'unsigned') {
    Fail 'Codex++ Authenticode policy must be unsigned'
}

$expectedPlugins = @($policy.Plugins)
if ($expectedPlugins.Count -ne 9 -or
    @($policy.Plugins | ForEach-Object { $_.Split('/')[0] } |
        Sort-Object -Unique).Count -ne 3) {
    Fail 'payload-lock must pin exactly three marketplaces and nine plugins'
}
$pluginCatalogPath = Resolve-PayloadPath 'plugins/plugin-catalog.json'
Assert-RegularPath $pluginCatalogPath $false 'hashed plugin catalog'
$pluginCatalog = Get-Content -LiteralPath $pluginCatalogPath -Raw | ConvertFrom-Json
if ([int] $pluginCatalog.schemaVersion -ne 2) {
    Fail 'plugin catalog schemaVersion must be 2'
}
$actualPlugins = @($pluginCatalog.plugins | ForEach-Object {
    "$($_.marketplace)/$($_.id)"
})
if ($actualPlugins.Count -ne 9 -or
    (Compare-Object ($expectedPlugins | Sort-Object) ($actualPlugins | Sort-Object))) {
    Fail 'plugin catalog does not exactly match payload-lock'
}
$offlinePlugins = @($policy.OfflinePlugins)
foreach ($plugin in @($pluginCatalog.plugins)) {
    $identity = "$($plugin.marketplace)/$($plugin.id)"
    $isOffline = $offlinePlugins -ccontains $identity
    $expectedDelivery = if ($isOffline) { 'offline' } else { 'runtime' }
    if ([string] $plugin.delivery -cne $expectedDelivery) {
        Fail "plugin delivery differs from compiled policy: $identity"
    }
    if ($isOffline) {
        Assert-ExactPolicyProperties $plugin @('marketplace', 'id', 'delivery') `
            "offline plugin catalog entry $identity"
    } else {
        Assert-ExactPolicyProperties $plugin @(
            'marketplace', 'id', 'delivery', 'runtimeId') `
            "runtime plugin catalog entry $identity"
        if ([string] $plugin.runtimeId -cne 'codex-primary-runtime') {
            Fail "plugin runtimeId differs from compiled policy: $identity"
        }
    }
}
$marketRoot = Resolve-PayloadPath 'plugins/marketplaces'
$cacheRoot = Resolve-PayloadPath 'plugins/cache'
$expectedMarkets = @($offlinePlugins | ForEach-Object { $_.Split('/')[0] } |
    Sort-Object -Unique)
foreach ($root in @($marketRoot, $cacheRoot)) {
    $actualMarkets = @(Get-ChildItem -LiteralPath $root -Directory -Force |
        ForEach-Object Name | Sort-Object)
    if (Compare-Object ($expectedMarkets | Sort-Object) $actualMarkets) {
        Fail "unexpected marketplace directory under $root"
    }
}
foreach ($pluginIdentity in $offlinePlugins) {
    $parts = $pluginIdentity.Split('/')
    $market = $parts[0]
    $id = $parts[1]
    $expectedMarketPlugins = @($offlinePlugins |
        Where-Object { $_.StartsWith("$market/", [StringComparison]::Ordinal) } |
        ForEach-Object { $_.Split('/')[1] } | Sort-Object)
    $marketPluginRoot = Resolve-PayloadPath "plugins/marketplaces/$market/plugins"
    $actualMarketPlugins = @(Get-ChildItem -LiteralPath $marketPluginRoot -Directory -Force |
        ForEach-Object Name | Sort-Object)
    if (Compare-Object $expectedMarketPlugins $actualMarketPlugins) {
        Fail "unexpected plugin directory in marketplace $market"
    }
    $identityPath = Resolve-PayloadPath (
        "plugins/marketplaces/$market/plugins/$id/.codex-plugin/plugin.json")
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ($identity.name -cne $id -or
        [string]::IsNullOrWhiteSpace([string] $identity.version)) {
        Fail "plugin identity mismatch: $market/$id"
    }
    $cacheMarketRoot = Resolve-PayloadPath "plugins/cache/$market"
    $actualCachePlugins = @(Get-ChildItem -LiteralPath $cacheMarketRoot -Directory -Force |
        ForEach-Object Name | Sort-Object)
    if (Compare-Object $expectedMarketPlugins $actualCachePlugins) {
        Fail "unexpected cached plugin directory in marketplace $market"
    }
    $versionRoot = Resolve-PayloadPath "plugins/cache/$market/$id"
    $versions = @(Get-ChildItem -LiteralPath $versionRoot -Directory -Force)
    if ($versions.Count -ne 1 -or $versions[0].Name -cne [string] $identity.version) {
        Fail "plugin cache version mismatch: $market/$id"
    }
    $cachedIdentityPath = Resolve-PayloadPath (
        "plugins/cache/$market/$id/$($identity.version)/.codex-plugin/plugin.json")
    $cachedIdentity = Get-Content -LiteralPath $cachedIdentityPath -Raw | ConvertFrom-Json
    if ($cachedIdentity.name -cne $id -or
        $cachedIdentity.version -cne $identity.version) {
        Fail "cached plugin identity mismatch: $market/$id"
    }
}

$upstreamIndexPath = Resolve-PayloadPath 'script-market/upstream-index.json'
$upstreamDigest = Get-FileDigest $upstreamIndexPath
if ($upstreamDigest.Sha256 -cne [string] $lock.scriptMarket.indexSha256) {
    Fail 'fixed-commit script market index hash does not match payload-lock'
}
$scriptIndexPath = Resolve-PayloadPath 'script-market/index.json'
$scriptIndex = Get-Content -LiteralPath $scriptIndexPath -Raw | ConvertFrom-Json
$indexedScriptPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::OrdinalIgnoreCase)
foreach ($script in @($scriptIndex.scripts)) {
    $localPath = Normalize-RelativePath ([string] (Get-RequiredProperty $script 'local_path'))
    if ($localPath -cne "scripts/$($script.id).js") {
        Fail "non-canonical script local_path: $($script.id)"
    }
    if (-not $indexedScriptPaths.Add($localPath)) {
        Fail "duplicate script path in final index: $localPath"
    }
    $sourceCommit = [string] (Get-RequiredProperty $script 'source_commit')
    $scriptUri = $null
    if (-not [Uri]::TryCreate([string] $script.script_url, [UriKind]::Absolute,
            [ref] $scriptUri) -or $scriptUri.Scheme -cne 'https' -or
        [string] $script.script_url -match '/(?:main|master)/' -or
        [string] $script.script_url -notmatch
            ('/' + [Regex]::Escape($sourceCommit) + '/')) {
        Fail "script_url is not immutable absolute HTTPS: $($script.id)"
    }
    $actualScript = Get-FileDigest (
        Resolve-PayloadPath "script-market/$localPath")
    if ($actualScript.Sha256 -cne [string] $script.sha256) {
        Fail "script hash mismatch: $($script.id)"
    }
}
$actualScriptPaths = @(Get-ChildItem -LiteralPath (
        Resolve-PayloadPath 'script-market/scripts') -File -Force |
    ForEach-Object { "scripts/$($_.Name)" } | Sort-Object)
if (Compare-Object @($indexedScriptPaths | Sort-Object) $actualScriptPaths) {
    Fail 'script-market scripts directory contains unindexed or missing files'
}
foreach ($pin in @($policy.MonitoringScripts)) {
    if ([string] $pin.sha256 -cnotmatch $ShaPattern) {
        Fail "invalid payload-lock monitoring hash: $($pin.id)"
    }
    $matching = @($scriptIndex.scripts | Where-Object id -CEQ $pin.id)
    if ($matching.Count -ne 1 -or
        $matching[0].version -cne $pin.version -or
        $matching[0].sha256 -cne $pin.sha256) {
        Fail "monitoring script pin mismatch: $($pin.id)"
    }
}
if ($byId['script-market'].version -cne [string] $lock.scriptMarket.commit) {
    Fail 'script-market manifest version does not match payload-lock commit'
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "codex-appx-validate-$([Guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $workRoot | Out-Null
try {
    $codexPath = Resolve-PayloadPath $codex.relativePath
    $dependencyEntries = @($entries | Where-Object id -Like 'codex-dependency-*')
    $candidatePackages = @($dependencyEntries | ForEach-Object {
        [pscustomobject]@{
            Path = Resolve-PayloadPath $_.relativePath
            Format = [string] $_.format
        }
    })
    $graph = Get-AppxPayloadGraph $codexPath $codex.format `
        $ResolvedPayloadRoot $workRoot $candidatePackages
    if ($graph.Main.Identity.Name -cne 'OpenAI.Codex' -or
        $graph.Main.Identity.Architecture -cne 'x64' -or
        $graph.Main.Identity.PackageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0' -or
        $graph.Main.Identity.Publisher -cne [string] $codex.publisher -or
        $graph.Main.Identity.Version -cne [string] $codex.version) {
        Fail 'expanded Codex package identity, architecture, publisher, or PFN is invalid'
    }
    if ($graph.Main.Identity.PackageFamilyName -cne [string] $codex.packageFamilyName) {
        Fail 'expanded Codex identity does not match manifest identity'
    }
    if (@($graph.Dependencies).Count -ne $dependencyEntries.Count) {
        Fail 'dependency manifest entries do not exactly match the actual package closure'
    }
    foreach ($dependency in @($graph.Dependencies)) {
        $matching = @($dependencyEntries | Where-Object {
            $_.packageName -ceq $dependency.Identity.Name
        })
        if ($matching.Count -ne 1) {
            Fail "dependency entry is missing or duplicated: $($dependency.Identity.Name)"
        }
        $entry = $matching[0]
        if ($entry.packageFamilyName -cne $dependency.Identity.PackageFamilyName -or
            $entry.publisher -cne $dependency.Identity.Publisher -or
            $entry.architecture -cne $dependency.Identity.Architecture -or
            $entry.version -cne $dependency.Identity.Version -or
            $entry.minimumVersion -cne $dependency.MinimumVersion) {
            Fail "dependency entry identity or MinVersion mismatch: $($dependency.Identity.Name)"
        }
    }
    if ($StrictSignatures) {
        foreach ($signedPackage in @($graph.SignedPackages)) {
            $result = Get-AuthenticodeSignature -FilePath $signedPackage.Path
            if ($result.Status -ne
                    [System.Management.Automation.SignatureStatus]::Valid -or
                $null -eq $result.SignerCertificate -or
                $result.SignerCertificate.Subject -cne
                    [string] $signedPackage.Identity.Publisher) {
                Fail "package signature or signer mismatch: $($signedPackage.Path)"
            }
        }
    }

    foreach ($entry in $entries) {
        $target = Resolve-PayloadPath $entry.relativePath
        $actual = if ($entry.format -ceq 'directory') {
            Get-DirectoryDigest $target
        } else {
            Get-FileDigest $target
        }
        if ($actual.Sha256 -cne $entry.sha256 -or
            [long] $actual.Size -ne [long] $entry.size) {
            Fail "payload hash or size mismatch: $($entry.id)"
        }
        $signature = 'N/A'
        if ($entry.id -eq 'codex-windows-x64') {
            $signature = if ($StrictSignatures) { 'Valid' } else { 'SKIPPED-FIXTURE' }
        } elseif ($entry.id -eq 'codex-plus-plus-windows-x64') {
            if ($StrictSignatures) {
                $result = Get-AuthenticodeSignature -FilePath $target
                if ($result.Status -ne
                        [System.Management.Automation.SignatureStatus]::NotSigned) {
                    Fail "Authenticode signature is not NotSigned: $($entry.id)"
                }
                $signature = 'NotSigned'
            } else { $signature = 'SKIPPED-FIXTURE' }
        } elseif ($entry.id -like 'codex-dependency-*') {
            if ($StrictSignatures) {
                $signature = 'Valid'
            } else { $signature = 'SKIPPED-FIXTURE' }
        }
        $licenseId = Get-OptionalProperty $entry 'licenseID'
        $license = if ([string]::IsNullOrWhiteSpace([string] $licenseId)) {
            'N/A'
        } else { [string] $licenseId }
        Write-Output ("{0} version={1} size={2} SHA256={3} signature={4} license={5}" -f
            $entry.id, $entry.version, $actual.Size, $actual.Sha256, $signature, $license)
    }
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}

Write-Output 'validate-offline-payloads: PASS'
