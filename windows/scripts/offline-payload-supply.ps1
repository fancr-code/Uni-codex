#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-WindowsPayloadPolicy([switch] $FixtureMode) {
    $components = if ($FixtureMode) {
        [ordered]@{
            'codex-windows-x64' = [ordered]@{ relativePath = 'apps/Codex.msix'; format = 'msix' }
            'codex-plus-plus-windows-x64' = [ordered]@{ relativePath = 'apps/CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe'; format = 'exe' }
            'codex-plus-plus-source' = [ordered]@{ relativePath = 'sources/CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz'; format = 'archive' }
            'model-catalog' = [ordered]@{ relativePath = 'model-catalog.json'; format = 'json' }
            'plugin-marketplaces' = [ordered]@{ relativePath = 'plugins'; format = 'directory' }
            'script-market' = [ordered]@{ relativePath = 'script-market'; format = 'directory' }
        }
    } else {
        [ordered]@{
            'codex-windows-x64' = [ordered]@{ relativePath = 'apps/Codex.msix'; format = 'msix' }
            'codex-plus-plus-windows-x64' = [ordered]@{ relativePath = 'apps/CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe'; format = 'exe' }
            'codex-plus-plus-source' = [ordered]@{ relativePath = 'sources/CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz'; format = 'archive' }
            'model-catalog' = [ordered]@{ relativePath = 'model-catalog.json'; format = 'json' }
            'plugin-marketplaces' = [ordered]@{ relativePath = 'plugins'; format = 'directory' }
            'script-market' = [ordered]@{ relativePath = 'script-market'; format = 'directory' }
        }
    }
    $monitoring = if ($FixtureMode) {
        @(
            [ordered]@{ id = 'codex-context-used-meter'; version = '101'; sha256 = '2355c76bc467f5ba25f56ead9abf3ee1dc1c8653a6d6d9d0f0846d7b89b65798' },
            [ordered]@{ id = 'codex-token-usage'; version = '0.1.7'; sha256 = '15f97d3ecd87886cf9c6c47dd0e6040ac422a0c659d3e32ea169932f79377467' },
            [ordered]@{ id = 'codex-daily-token-usage'; version = '1.4.13'; sha256 = 'e5060f06cd96022c315892e54e96958d7dc7753bcf857f23d734b8b474cb7c59' },
            [ordered]@{ id = 'codex-live-token-cost'; version = '0.7.2'; sha256 = 'bd433af9ba95637e0a6babb7728e50d50d3ef44763a3e7d1ec47e4d9c25ece82' })
    } else {
        @(
            [ordered]@{ id = 'codex-context-used-meter'; version = '101'; sha256 = '7d1f79dd2f379bf25787ed1fc65778266fd286cd33966692708f985fe3adba7d' },
            [ordered]@{ id = 'codex-token-usage'; version = '0.1.7'; sha256 = 'bf233607f8e60f56b3c68d29c15bbd5ed5d7582fc488380f56b8d2f553bb4ddd' },
            [ordered]@{ id = 'codex-daily-token-usage'; version = '1.4.13'; sha256 = '80f5efb88d1e2e0da5c22f229b65d08710460a7c258bdaea7b82a84071fb7576' },
            [ordered]@{ id = 'codex-live-token-cost'; version = '0.7.2'; sha256 = 'aee6bf61236aa9edf183a71bba5a45cbb1f273f94e2197d4421d557999de5da8' })
    }
    return [pscustomobject]@{
        FixtureMode = [bool] $FixtureMode
        RequiredComponents = @($components.Keys)
        Components = $components
        Codex = [ordered]@{
            architecture = 'x64'
            packageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
        }
        CodexPlusPlus = [ordered]@{
            payloadVersion = '1.2.43+codexkit.1'
            architecture = 'x64'
            compatibilityRevision = 'cross-provider-content-v1'
            licenseID = 'AGPL-3.0-only'
        }
        Plugins = @(
            'openai-bundled/browser', 'openai-bundled/chrome',
            'openai-bundled/computer-use', 'openai-bundled/latex',
            'openai-primary-runtime/pdf', 'openai-primary-runtime/documents',
            'openai-primary-runtime/spreadsheets', 'openai-primary-runtime/presentations',
            'openai-curated/github')
        OfflinePlugins = @(
            'openai-bundled/browser', 'openai-bundled/chrome',
            'openai-bundled/computer-use', 'openai-bundled/latex',
            'openai-curated/github')
        MonitoringScripts = $monitoring
        ScriptMarket = [ordered]@{
            commit = $(if ($FixtureMode) { 'fixture-commit' } else { 'b3c1d16d7d75145b9cf5b0e34000316436d905dd' })
            indexSha256 = $(if ($FixtureMode) { 'bdb39dcb17eb31776318f7acdab4dc31a5bc2b782feba9dc21b0022f0556a5f4' } else { '0776ecee1165babd3794fa3a740433b5326549bc8c5d8546aa4f8bb52374d540' })
        }
    }
}

function Assert-ExactPolicyProperties($Object, [string[]] $Names, [string] $Description) {
    $actual = @($Object.PSObject.Properties.Name)
    if (Compare-Object @($Names) $actual) {
        throw "$Description fields differ from compiled policy"
    }
}

function Assert-PayloadLockMatchesPolicy($Lock, $Policy) {
    $rootFields = @(
        'schemaVersion', 'requiredComponents', 'components', 'codex',
        'codexPlusPlus', 'plugins', 'monitoringScripts', 'scriptMarket')
    if ($Policy.FixtureMode) { $rootFields += 'fixture' }
    Assert-ExactPolicyProperties $Lock $rootFields 'payload lock'
    if ([int] $Lock.schemaVersion -ne 2) { throw 'payload lock schemaVersion is not policy 2' }
    if (Compare-Object @($Policy.RequiredComponents) @($Lock.requiredComponents)) {
        throw 'payload lock requiredComponents differ from compiled policy'
    }
    $componentNames = @($Lock.components.PSObject.Properties.Name)
    if (Compare-Object @($Policy.RequiredComponents) $componentNames) {
        throw 'payload lock components differ from compiled policy'
    }
    foreach ($id in $Policy.RequiredComponents) {
        Assert-ExactPolicyProperties $Lock.components.$id @('relativePath', 'format') `
            "payload lock component $id"
        if ([string] $Lock.components.$id.relativePath -cne
                [string] $Policy.Components[$id].relativePath -or
            [string] $Lock.components.$id.format -cne
                [string] $Policy.Components[$id].format) {
            throw "payload lock component differs from compiled policy: $id"
        }
    }
    Assert-ExactPolicyProperties $Lock.codex @('architecture', 'packageFamilyName') `
        'payload lock Codex'
    foreach ($name in @('architecture', 'packageFamilyName')) {
        if ([string] $Lock.codex.$name -cne [string] $Policy.Codex[$name]) {
            throw "payload lock Codex $name differs from compiled policy"
        }
    }
    Assert-ExactPolicyProperties $Lock.codexPlusPlus @(
        'payloadVersion', 'architecture', 'compatibilityRevision', 'licenseID') `
        'payload lock Codex++'
    foreach ($name in @('payloadVersion', 'architecture', 'compatibilityRevision', 'licenseID')) {
        if ([string] $Lock.codexPlusPlus.$name -cne [string] $Policy.CodexPlusPlus[$name]) {
            throw "payload lock Codex++ $name differs from compiled policy"
        }
    }
    $plugins = @($Lock.plugins | ForEach-Object { "$($_.marketplace)/$($_.id)" })
    foreach ($plugin in @($Lock.plugins)) {
        Assert-ExactPolicyProperties $plugin @('marketplace', 'id') 'payload lock plugin'
    }
    if (Compare-Object @($Policy.Plugins) $plugins) {
        throw 'payload lock plugins differ from compiled policy'
    }
    if (@($Lock.monitoringScripts).Count -ne @($Policy.MonitoringScripts).Count) {
        throw 'payload lock monitoring scripts differ from compiled policy'
    }
    foreach ($pin in @($Policy.MonitoringScripts)) {
        $actual = @($Lock.monitoringScripts | Where-Object id -CEQ $pin.id)
        if ($actual.Count -ne 1 -or $actual[0].version -cne $pin.version -or
            $actual[0].sha256 -cne $pin.sha256) {
            throw "payload lock monitoring script differs from compiled policy: $($pin.id)"
        }
    }
    foreach ($pin in @($Lock.monitoringScripts)) {
        Assert-ExactPolicyProperties $pin @('id', 'version', 'sha256') `
            'payload lock monitoring script'
    }
    Assert-ExactPolicyProperties $Lock.scriptMarket @('commit', 'indexSha256') `
        'payload lock script market'
    foreach ($name in @('commit', 'indexSha256')) {
        if ([string] $Lock.scriptMarket.$name -cne [string] $Policy.ScriptMarket[$name]) {
            throw "payload lock script market $name differs from compiled policy"
        }
    }
}

function Write-Utf8NoBomText([string] $Text, [string] $Path) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-Utf8NoBomJson($InputObject, [string] $Path, [int] $Depth = 30) {
    Write-Utf8NoBomText -Text ($InputObject | ConvertTo-Json -Depth $Depth) -Path $Path
}

function Assert-ReparseFreeAbsolutePath([string] $Path, [string] $Description) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    if (Test-Path -LiteralPath $current) {
        $rootItem = Get-Item -LiteralPath $current -Force
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description path contains a symbolic link or reparse point: $current"
        }
    }
    $tail = $full.Substring($root.Length)
    foreach ($segment in $tail.Split(@([IO.Path]::DirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description path contains a symbolic link or reparse point: $current"
            }
        }
    }
    return $full
}

function Resolve-ImmutableScriptSource(
    [string] $ScriptUrl,
    [string] $Id,
    [string] $Commit,
    [object[]] $Overrides
) {
    $uri = [uri] $ScriptUrl
    if ($uri.Scheme -cne 'https') { throw "script URL must be HTTPS: $Id" }
    $matching = @($Overrides | Where-Object {
        $_.id -ceq $Id -and $_.upstreamURL -ceq $ScriptUrl
    })
    if ($matching.Count -gt 1) {
        throw "script override is ambiguous: $Id"
    }
    if ($matching.Count -eq 1 -and $matching[0].mode -ceq 'pinned') {
        $override = $matching[0]
        $pinned = [uri] $override.pinnedURL
        if ($pinned.Scheme -cne 'https' -or
            [string]::IsNullOrWhiteSpace([string] $override.sourceCommit) -or
            ([string] $override.pinnedSHA256) -cnotmatch '^[0-9a-f]{64}$') {
            throw "pinned script override is invalid: $Id"
        }
        return [pscustomobject]@{
            SourceKind = 'https'
            SourceUrl = $pinned.AbsoluteUri
            SourcePath = $null
            LocalPath = "scripts/$Id.js"
            Sha256 = [string] $override.pinnedSHA256
            UpstreamSha256 = $null
            SourceCommit = [string] $override.sourceCommit
            UpstreamUrl = $ScriptUrl
        }
    }
    if ($matching.Count -eq 1 -and $matching[0].mode -ceq 'managed') {
        $override = $matching[0]
        $managedUrl = $null
        if (-not [Uri]::TryCreate([string] $override.managedURL,
                [UriKind]::Absolute, [ref] $managedUrl) -or
            $managedUrl.Scheme -cne 'https' -or
            ([string] $override.sourceCommit) -cnotmatch '^[0-9a-f]{40}$' -or
            $managedUrl.AbsoluteUri -notmatch
                ('/' + [Regex]::Escape([string] $override.sourceCommit) + '/') -or
            ([string] $override.upstreamSHA256) -cnotmatch '^[0-9a-f]{64}$' -or
            ([string] $override.managedSHA256) -cnotmatch '^[0-9a-f]{64}$' -or
            [string]::IsNullOrWhiteSpace([string] $override.provenance)) {
            throw "managed script override is invalid: $Id"
        }
        $relative = ([string] $override.managedSource).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relative) -or
            $relative -notlike 'script-market-sources/*.js' -or
            $relative.Split('/') -contains '..' -or
            [IO.Path]::IsPathRooted($relative)) {
            throw "managed script source path is invalid: $Id"
        }
        $repositoryRoot = [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '../..'))
        $resourcesRoot = [IO.Path]::GetFullPath(
            (Join-Path $repositoryRoot 'Resources'))
        $sourcePath = [IO.Path]::GetFullPath(
            (Join-Path $resourcesRoot $relative))
        $resourcesPrefix = $resourcesRoot.TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        if (-not $sourcePath.StartsWith(
                $resourcesPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "managed script source is missing or outside Resources: $Id"
        }
        Assert-ReparseFreeAbsolutePath $sourcePath 'managed script source' |
            Out-Null
        $actual = (Get-FileHash -LiteralPath $sourcePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne [string] $override.managedSHA256) {
            throw "managed script hash mismatch: $Id"
        }
        return [pscustomobject]@{
            SourceKind = 'managed'
            SourceUrl = $managedUrl.AbsoluteUri
            SourcePath = $sourcePath
            LocalPath = "scripts/$Id.js"
            Sha256 = [string] $override.managedSHA256
            UpstreamSha256 = [string] $override.upstreamSHA256
            SourceCommit = [string] $override.sourceCommit
            UpstreamUrl = $ScriptUrl
        }
    }
    if ($matching.Count -eq 1) {
        throw "script override mode is unsupported: $Id"
    }

    if ($uri.Host -cne 'raw.githubusercontent.com') {
        throw "script URL is not a supported immutable GitHub raw source: $Id"
    }
    $segments = $uri.AbsolutePath.TrimStart('/').Split('/')
    if ($segments.Length -lt 4 -or
        $segments[0] -cne 'BigPizzaV3' -or
        $segments[1] -cne 'CodexPlusPlusScriptMarket') {
        throw "external script requires a pinned override: $Id"
    }
    $repositoryPath = ($segments[3..($segments.Length - 1)] -join '/')
    return [pscustomobject]@{
        SourceKind = 'https'
        SourceUrl = "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/$Commit/$repositoryPath"
        SourcePath = $null
        LocalPath = "scripts/$Id.js"
        Sha256 = $null
        UpstreamSha256 = $null
        SourceCommit = $Commit
        UpstreamUrl = $ScriptUrl
    }
}

function Get-PackagePublisherId([string] $Publisher) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher)) }
    finally { $sha.Dispose() }
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    $result = New-Object Text.StringBuilder
    for ($group = 0; $group -lt 13; $group++) {
        $value = 0
        for ($bit = 0; $bit -lt 5; $bit++) {
            $sourceBit = ($group * 5) + $bit
            $value = $value -shl 1
            if ($sourceBit -lt 64) {
                $byte = [Math]::Floor($sourceBit / 8)
                $offset = 7 - ($sourceBit % 8)
                $value = $value -bor (($digest[$byte] -shr $offset) -band 1)
            }
        }
        [void] $result.Append($alphabet[$value])
    }
    return $result.ToString()
}

function Expand-AppxArchive([string] $PackagePath, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $Destination)
}

function Get-AppxArchiveFormat([string] $PackagePath, [string] $WorkRoot) {
    $expanded = Join-Path $WorkRoot "format-$([Guid]::NewGuid().ToString('N'))"
    Expand-AppxArchive $PackagePath $expanded
    if (Test-Path -LiteralPath (Join-Path $expanded 'AppxMetadata/AppxBundleManifest.xml') `
            -PathType Leaf) {
        return 'msixbundle'
    }
    if (Test-Path -LiteralPath (Join-Path $expanded 'AppxManifest.xml') -PathType Leaf) {
        return 'msix'
    }
    throw "Appx archive has no package or bundle manifest: $PackagePath"
}

function Read-AppxIdentity([string] $ExpandedRoot) {
    $manifestPath = Join-Path $ExpandedRoot 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "AppxManifest.xml is missing: $ExpandedRoot"
    }
    [xml] $xml = Get-Content -LiteralPath $manifestPath -Raw
    $identity = $xml.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if ($null -eq $identity) { throw 'Appx Identity is missing' }
    $architecture = [string] $identity.ProcessorArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $node = $xml.SelectSingleNode(
            "/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='ProcessorArchitecture']")
        if ($null -ne $node) { $architecture = [string] $node.InnerText }
    }
    $publisher = [string] $identity.Publisher
    $dependencies = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dependency in $xml.SelectNodes(
        "/*[local-name()='Package']/*[local-name()='Dependencies']/*[local-name()='PackageDependency']")) {
        $name = [string] $dependency.Name
        $dependencyPublisher = [string] $dependency.Publisher
        $minimumVersion = [string] $dependency.MinVersion
        if ([string]::IsNullOrWhiteSpace($name) -or
            [string]::IsNullOrWhiteSpace($dependencyPublisher) -or
            [string]::IsNullOrWhiteSpace($minimumVersion)) {
            throw 'Appx PackageDependency must include Name, Publisher, and MinVersion'
        }
        try { [void] [Version] $minimumVersion }
        catch { throw "Appx PackageDependency has invalid MinVersion: $name" }
        $dependencies.Add([pscustomobject]@{
            Name = $name
            Publisher = $dependencyPublisher
            MinVersion = $minimumVersion
        })
    }
    return [pscustomobject]@{
        Name = [string] $identity.Name
        Version = [string] $identity.Version
        Architecture = $architecture
        Publisher = $publisher
        PackageFamilyName = "$($identity.Name)_$(Get-PackagePublisherId $publisher)"
        Dependencies = $dependencies.ToArray()
        ExpandedRoot = $ExpandedRoot
    }
}

function Get-AppxPayloadDescriptor(
    [string] $PackagePath,
    [string] $Format,
    [string] $PayloadRoot,
    [string] $WorkRoot
) {
    $package = [IO.Path]::GetFullPath($PackagePath)
    $extension = [IO.Path]::GetExtension($package).ToLowerInvariant()
    $expectedExtension = @{
        msix = '.msix'; msixbundle = '.msixbundle'; appinstaller = '.appinstaller'
    }[$Format]
    if ([string]::IsNullOrWhiteSpace([string] $expectedExtension) -or
        $extension -cne $expectedExtension) {
        throw "package format does not match canonical extension: $Format $extension"
    }
    if ($Format -ceq 'appinstaller') {
        [xml] $appInstaller = Get-Content -LiteralPath $package -Raw
        $main = $appInstaller.SelectSingleNode(
            "/*[local-name()='AppInstaller']/*[local-name()='MainBundle' or local-name()='MainPackage']")
        if ($null -eq $main) { throw 'AppInstaller main package is missing' }
        $mainUri = [uri] ([string] $main.Uri)
        if ($mainUri.IsAbsoluteUri) { throw 'offline AppInstaller main URI must be relative' }
        $mainPath = [IO.Path]::GetFullPath((Join-Path $PayloadRoot $mainUri.OriginalString))
        $prefix = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        if (-not $mainPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AppInstaller main package escapes payload root'
        }
        $mainFormat = switch ([IO.Path]::GetExtension($mainPath).ToLowerInvariant()) {
            '.msix' { 'msix' } '.msixbundle' { 'msixbundle' }
            default { throw 'AppInstaller main package format is unsupported' }
        }
        $descriptor = Get-AppxPayloadDescriptor $mainPath $mainFormat $PayloadRoot $WorkRoot
        $signedPackages = New-Object 'System.Collections.Generic.List[object]'
        foreach ($signedPackage in $descriptor.SignedPackages) {
            $signedPackages.Add($signedPackage)
        }
        foreach ($dependency in $appInstaller.SelectNodes(
            "/*[local-name()='AppInstaller']/*[local-name()='Dependencies']/*[local-name()='Package']")) {
            $dependencyUri = [uri] ([string] $dependency.Uri)
            if ($dependencyUri.IsAbsoluteUri) { throw 'offline dependency URI must be relative' }
            $dependencyPath = [IO.Path]::GetFullPath(
                (Join-Path $PayloadRoot $dependencyUri.OriginalString))
            if (-not $dependencyPath.StartsWith($prefix,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw 'AppInstaller dependency escapes payload root'
            }
            $dependencyFormat = if (
                [IO.Path]::GetExtension($dependencyPath).ToLowerInvariant() -eq '.msixbundle') {
                'msixbundle'
            } else { 'msix' }
            $dependencyDescriptor = Get-AppxPayloadDescriptor $dependencyPath `
                $dependencyFormat $PayloadRoot $WorkRoot
            foreach ($signedPackage in $dependencyDescriptor.SignedPackages) {
                $signedPackages.Add($signedPackage)
            }
        }
        return [pscustomobject]@{
            Identity = $descriptor.Identity
            SignedPackages = $signedPackages.ToArray()
        }
    }

    $expanded = Join-Path $WorkRoot "appx-$([Guid]::NewGuid().ToString('N'))"
    Expand-AppxArchive $package $expanded
    if ($Format -ceq 'msix') {
        return [pscustomobject]@{
            Identity = Read-AppxIdentity $expanded
            SignedPackages = @([pscustomobject]@{
                Path = $package
                Identity = Read-AppxIdentity $expanded
            })
        }
    }

    $bundleManifest = Join-Path $expanded 'AppxMetadata/AppxBundleManifest.xml'
    [xml] $bundle = Get-Content -LiteralPath $bundleManifest -Raw
    $main = @(@($bundle.SelectNodes(
        "/*[local-name()='Bundle']/*[local-name()='Packages']/*[local-name()='Package']")) |
        Where-Object {
            $_.Type -eq 'application' -and $_.Architecture -eq 'x64'
        })
    if ($main.Count -ne 1) { throw 'MSIXBundle must contain exactly one x64 main package' }
    $inner = Join-Path $expanded ([string] $main[0].FileName)
    $innerDescriptor = Get-AppxPayloadDescriptor $inner 'msix' $PayloadRoot $WorkRoot
    return [pscustomobject]@{
        Identity = $innerDescriptor.Identity
        SignedPackages = @(
            [pscustomobject]@{
                Path = $package
                Identity = $innerDescriptor.Identity
            }
            $innerDescriptor.SignedPackages
        )
    }
}

function Resolve-PayloadPackagePath(
    [string] $PayloadRoot,
    [string] $RelativePath,
    [string] $Description
) {
    $root = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escapes payload root"
    }
    Assert-ReparseFreeAbsolutePath $candidate $Description | Out-Null
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Description is missing: $candidate"
    }
    return $candidate
}

function Resolve-AppInstallerPackagePath(
    [string] $PayloadRoot,
    [string] $AppInstallerPath,
    [string] $RelativePath,
    [string] $Description
) {
    $payloadRootFull = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\', '/')
    $appInstallerDirectory = [IO.Path]::GetDirectoryName(
        [IO.Path]::GetFullPath($AppInstallerPath)).TrimEnd('\', '/')
    $payloadPrefix = $payloadRootFull + [IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals($appInstallerDirectory, $payloadRootFull,
            [StringComparison]::OrdinalIgnoreCase) -and
        -not $appInstallerDirectory.StartsWith($payloadPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description AppInstaller is outside payload root"
    }
    return Resolve-PayloadPackagePath $appInstallerDirectory $RelativePath $Description
}

function Get-AppxPayloadGraph(
    [string] $MainPath,
    [ValidateSet('msix', 'msixbundle', 'appinstaller')] [string] $Format,
    [string] $PayloadRoot,
    [string] $WorkRoot,
    [object[]] $CandidatePackages = @()
) {
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $mainPackagePath = [IO.Path]::GetFullPath($MainPath)
    $mainFormat = $Format
    $appInstallerRequirements = New-Object 'System.Collections.Generic.List[object]'
    $allCandidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in @($CandidatePackages)) { $allCandidates.Add($candidate) }
    $appInstallerIdentity = $null

    if ($Format -ceq 'appinstaller') {
        $appInstallerPath = $mainPackagePath
        [xml] $appInstaller = Get-Content -LiteralPath $mainPackagePath -Raw
        $mainNode = $appInstaller.SelectSingleNode(
            "/*[local-name()='AppInstaller']/*[local-name()='MainBundle' or local-name()='MainPackage']")
        if ($null -eq $mainNode) { throw 'AppInstaller main package is missing' }
        $mainPackagePath = Resolve-AppInstallerPackagePath $PayloadRoot $appInstallerPath `
            ([string] $mainNode.Uri) `
            'AppInstaller main package'
        $mainFormat = switch ([IO.Path]::GetExtension($mainPackagePath).ToLowerInvariant()) {
            '.msix' { 'msix' }
            '.msixbundle' { 'msixbundle' }
            default { throw 'AppInstaller main package format is unsupported' }
        }
        $appInstallerIdentity = [pscustomobject]@{
            Kind = [string] $mainNode.LocalName
            Name = [string] $mainNode.Name
            Publisher = [string] $mainNode.Publisher
            Version = [string] $mainNode.Version
            Architecture = [string] $mainNode.ProcessorArchitecture
        }
        foreach ($node in $appInstaller.SelectNodes(
            "/*[local-name()='AppInstaller']/*[local-name()='Dependencies']/*[local-name()='Package']")) {
            $path = Resolve-AppInstallerPackagePath $PayloadRoot $appInstallerPath `
                ([string] $node.Uri) `
                'AppInstaller dependency'
            $dependencyFormat = switch ([IO.Path]::GetExtension($path).ToLowerInvariant()) {
                '.msix' { 'msix' }
                '.msixbundle' { 'msixbundle' }
                default { throw 'AppInstaller dependency format is unsupported' }
            }
            $allCandidates.Add([pscustomobject]@{ Path = $path; Format = $dependencyFormat })
            $appInstallerRequirements.Add([pscustomobject]@{
                Name = [string] $node.Name
                Publisher = [string] $node.Publisher
                MinVersion = [string] $node.MinVersion
                Architecture = [string] $node.ProcessorArchitecture
            })
        }
    }

    $mainDescriptor = Get-AppxPayloadDescriptor $mainPackagePath $mainFormat `
        $PayloadRoot $WorkRoot
    if ($mainDescriptor.Identity.Architecture -cne 'x64') {
        throw 'main package must have x64 architecture'
    }
    if ($null -ne $appInstallerIdentity) {
        foreach ($property in @('Name', 'Publisher', 'Version')) {
            if ([string] $appInstallerIdentity.$property -cne
                [string] $mainDescriptor.Identity.$property) {
                throw "AppInstaller main $property does not match actual package identity"
            }
        }
        if ($appInstallerIdentity.Kind -ceq 'MainPackage' -and
            [string] $appInstallerIdentity.Architecture -cne
                [string] $mainDescriptor.Identity.Architecture) {
            throw 'AppInstaller main Architecture does not match actual package identity'
        }
    }

    $candidateByPath = @{}
    foreach ($candidate in $allCandidates.ToArray()) {
        $path = [IO.Path]::GetFullPath([string] $candidate.Path)
        if ($path -ceq $mainPackagePath) { throw 'main package cannot also be a dependency' }
        if ($candidateByPath.ContainsKey($path)) {
            if ($candidateByPath[$path].Format -cne [string] $candidate.Format) {
                throw "duplicate dependency package path has conflicting format: $path"
            }
            continue
        }
        $descriptor = Get-AppxPayloadDescriptor $path ([string] $candidate.Format) `
            $PayloadRoot $WorkRoot
        if ($descriptor.Identity.Architecture -notin @('x64', 'neutral')) {
            throw "dependency architecture must be x64 or neutral: $($descriptor.Identity.Name)"
        }
        $candidateByPath[$path] = [pscustomobject]@{
            Path = $path
            Format = [string] $candidate.Format
            Identity = $descriptor.Identity
            SignedPackages = @($descriptor.SignedPackages)
        }
    }

    $requirements = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($requirement in @($mainDescriptor.Identity.Dependencies)) {
        $requirements.Enqueue($requirement)
    }
    foreach ($requirement in $appInstallerRequirements.ToArray()) {
        $requirements.Enqueue($requirement)
    }
    $resolvedByName = @{}
    while ($requirements.Count -gt 0) {
        $requirement = $requirements.Dequeue()
        try { $minimumVersion = [Version] ([string] $requirement.MinVersion) }
        catch { throw "dependency has invalid MinVersion: $($requirement.Name)" }
        $matches = @($candidateByPath.Values | Where-Object {
            $_.Identity.Name -ceq [string] $requirement.Name -and
            $_.Identity.Publisher -ceq [string] $requirement.Publisher
        })
        if ($matches.Count -eq 0) {
            throw "missing dependency: $($requirement.Name)"
        }
        if ($matches.Count -ne 1) {
            throw "duplicate dependency package: $($requirement.Name)"
        }
        $match = $matches[0]
        if ([Version] $match.Identity.Version -lt $minimumVersion) {
            throw "dependency does not satisfy MinVersion: $($requirement.Name)"
        }
        if ($requirement.PSObject.Properties.Name -contains 'Architecture' -and
            -not [string]::IsNullOrWhiteSpace([string] $requirement.Architecture) -and
            [string] $requirement.Architecture -cne
                [string] $match.Identity.Architecture) {
            throw "dependency architecture does not match AppInstaller: $($requirement.Name)"
        }
        if ($resolvedByName.ContainsKey([string] $requirement.Name)) {
            $existing = $resolvedByName[[string] $requirement.Name]
            if ($existing.Path -cne $match.Path) {
                throw "dependency closure is ambiguous: $($requirement.Name)"
            }
            if ([Version] $existing.MinimumVersion -lt $minimumVersion) {
                $existing.MinimumVersion = $minimumVersion.ToString()
            }
            continue
        }
        $match | Add-Member -NotePropertyName MinimumVersion `
            -NotePropertyValue $minimumVersion.ToString()
        $resolvedByName[[string] $requirement.Name] = $match
        foreach ($nested in @($match.Identity.Dependencies)) {
            $requirements.Enqueue($nested)
        }
    }
    if ($resolvedByName.Count -ne $candidateByPath.Count) {
        $extra = @($candidateByPath.Values | Where-Object {
            -not $resolvedByName.ContainsKey([string] $_.Identity.Name)
        } | Select-Object -First 1)
        throw "extra dependency package is unrelated to closure: $($extra[0].Identity.Name)"
    }
    $main = [pscustomobject]@{
        Path = $mainPackagePath
        Format = $mainFormat
        Identity = $mainDescriptor.Identity
        SignedPackages = @($mainDescriptor.SignedPackages)
    }
    return [pscustomobject]@{
        Main = $main
        Dependencies = @($resolvedByName.Values | Sort-Object { $_.Identity.Name })
        SignedPackages = @(
            $main.SignedPackages
            @($resolvedByName.Values | ForEach-Object { $_.SignedPackages })
        )
    }
}

function Get-Sha256Hex([string] $Path) {
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace(
                '-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}

function Resolve-ActivePayloadRoot(
    [string] $OutputRoot,
    [switch] $FixtureMode
) {
    $output = [IO.Path]::GetFullPath($OutputRoot)
    Assert-ReparseFreeAbsolutePath $output 'payload container' | Out-Null
    if ($FixtureMode) {
        if (-not (Test-Path -LiteralPath $output -PathType Container)) {
            throw "fixture payload root is missing: $output"
        }
        return $output
    }
    $pointerPath = Join-Path $output 'current.json'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        throw "payload current pointer is missing: $pointerPath"
    }
    Assert-ReparseFreeAbsolutePath $pointerPath 'payload current pointer' | Out-Null
    try { $pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json }
    catch { throw "payload current pointer is invalid JSON: $($_.Exception.Message)" }
    if ([int] $pointer.schemaVersion -ne 1) {
        throw 'payload current pointer schemaVersion must be 1'
    }
    $generation = [string] $pointer.generation
    if ($generation -cnotmatch '^[a-z0-9][a-z0-9.-]{0,63}$' -or
        $generation -in @('.', '..') -or $generation.Contains('..')) {
        throw "payload current generation ID is unsafe: $generation"
    }
    $manifestSha = [string] $pointer.manifestSha256
    if ($manifestSha -cnotmatch '^[0-9a-f]{64}$') {
        throw 'payload current pointer manifest SHA256 is invalid'
    }
    $generationRoot = [IO.Path]::GetFullPath(
        (Join-Path $output "generations/$generation"))
    $generationPrefix = [IO.Path]::GetFullPath(
        (Join-Path $output 'generations')).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    if (-not $generationRoot.StartsWith(
            $generationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'payload current generation escapes generations root'
    }
    Assert-ReparseFreeAbsolutePath $generationRoot 'active payload generation' | Out-Null
    if (-not (Test-Path -LiteralPath $generationRoot -PathType Container)) {
        throw "active payload generation is missing: $generation"
    }
    $manifestPath = Join-Path $generationRoot 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        (Get-Sha256Hex $manifestPath) -cne $manifestSha) {
        throw 'active payload generation manifest SHA256 mismatch'
    }
    return $generationRoot
}

function Publish-PayloadGeneration(
    [string] $StageRoot,
    [string] $OutputRoot,
    [string] $GenerationId,
    [ValidateSet(
        '', 'PointerWrite', 'PointerFlush', 'BeforeCommit', 'PointerReplace',
        'AfterCommit', 'Cleanup', 'CrashBeforeCommit')]
    [string] $TestFault = ''
) {
    if ($GenerationId -cnotmatch '^[a-z0-9][a-z0-9.-]{0,63}$' -or
        $GenerationId -in @('.', '..') -or $GenerationId.Contains('..')) {
        throw "generation ID is unsafe: $GenerationId"
    }
    $stage = [IO.Path]::GetFullPath($StageRoot)
    $output = [IO.Path]::GetFullPath($OutputRoot)
    Assert-ReparseFreeAbsolutePath $stage 'stage generation' | Out-Null
    $manifestPath = Join-Path $stage 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'stage generation payload-manifest.json is missing'
    }
    $manifestSha = Get-Sha256Hex $manifestPath
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    Assert-ReparseFreeAbsolutePath $output 'payload container' | Out-Null
    $generations = Join-Path $output 'generations'
    New-Item -ItemType Directory -Path $generations -Force | Out-Null
    $generationRoot = Join-Path $generations $GenerationId
    if (Test-Path -LiteralPath $generationRoot) {
        throw "generation already exists: $GenerationId"
    }
    $pointerPath = Join-Path $output 'current.json'
    $pointerTemp = Join-Path $output ".current-$([Guid]::NewGuid().ToString('N')).tmp"
    $pointerBackup = Join-Path $output ".current-backup-$([Guid]::NewGuid().ToString('N')).json"
    $lockPath = Join-Path $output '.publish.lock'
    $lockStream = [IO.File]::Open(
        $lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $committed = $false
    $generationMoved = $false
    try {
        Move-Item -LiteralPath $stage -Destination $generationRoot
        $generationMoved = $true
        $pointerJson = ([ordered]@{
            schemaVersion = 1
            generation = $GenerationId
            manifestSha256 = $manifestSha
        } | ConvertTo-Json -Depth 5)
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($pointerJson)
        $stream = [IO.File]::Open(
            $pointerTemp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            if ($TestFault -eq 'PointerWrite') { throw 'publish fault: PointerWrite' }
            $stream.Write($bytes, 0, $bytes.Length)
            if ($TestFault -eq 'PointerFlush') { throw 'publish fault: PointerFlush' }
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ($TestFault -in @('BeforeCommit', 'CrashBeforeCommit')) {
            throw "publish fault: $TestFault"
        }
        if ($TestFault -eq 'PointerReplace') { throw 'publish fault: PointerReplace' }
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            [IO.File]::Replace($pointerTemp, $pointerPath, $pointerBackup)
        } else {
            [IO.File]::Move($pointerTemp, $pointerPath)
        }
        $committed = $true
        if ($TestFault -eq 'AfterCommit') { throw 'publish fault: AfterCommit' }
    } catch {
        $failure = $_
        if (-not $committed -and $generationMoved -and
            $TestFault -ne 'CrashBeforeCommit' -and
            (Test-Path -LiteralPath $generationRoot)) {
            Remove-Item -LiteralPath $generationRoot -Recurse -Force
        }
        throw $failure
    } finally {
        if (Test-Path -LiteralPath $pointerTemp) {
            Remove-Item -LiteralPath $pointerTemp -Force -ErrorAction SilentlyContinue
        }
        $lockStream.Dispose()
    }
    if (Test-Path -LiteralPath $pointerBackup) {
        try { Remove-Item -LiteralPath $pointerBackup -Force -ErrorAction Stop }
        catch {
            Write-Warning "published generation is committed; stale pointer backup retained: $pointerBackup"
        }
    }
    foreach ($old in @(Get-ChildItem -LiteralPath $generations -Directory -Force |
            Where-Object Name -CNE $GenerationId)) {
        try {
            if ($TestFault -eq 'Cleanup') { throw 'publish fault: Cleanup' }
            Remove-Item -LiteralPath $old.FullName -Recurse -Force
        } catch {
            Write-Warning "published generation is committed; stale generation retained: $($old.FullName)"
        }
    }
    try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop }
    catch { Write-Warning "published generation lock cleanup failed: $lockPath" }
}
