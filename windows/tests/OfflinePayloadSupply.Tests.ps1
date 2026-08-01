#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $WindowsRoot 'scripts/offline-payload-supply.ps1')
$TestRoot = Join-Path $PSScriptRoot ".offline-payload-supply-$([Guid]::NewGuid().ToString('N'))"

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) { throw "$Message (actual=$Actual expected=$Expected)" }
}

function Assert-ThrowsLike([scriptblock] $Action, [string] $Pattern, [string] $Message) {
    try {
        & $Action
        throw "$Message (no exception)"
    } catch {
        if ($_.Exception.Message -notlike $Pattern) {
            throw "$Message (actual=$($_.Exception.Message) expected=$Pattern)"
        }
    }
}

function New-TestMsix(
    [string] $Path,
    [string] $Name,
    [string] $Publisher,
    [string] $Version,
    [string] $Architecture,
    [object[]] $Dependencies = @()
) {
    $source = Join-Path $TestRoot "msix-source-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $source | Out-Null
    $dependencyXml = @($Dependencies | ForEach-Object {
        "<PackageDependency Name=`"$($_.Name)`" Publisher=`"$($_.Publisher)`" MinVersion=`"$($_.MinVersion)`" />"
    }) -join ''
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$Name" Publisher="$Publisher" Version="$Version" ProcessorArchitecture="$Architecture" />
  <Dependencies>$dependencyXml</Dependencies>
  <Properties><DisplayName>fixture</DisplayName><PublisherDisplayName>fixture</PublisherDisplayName><Logo>logo.png</Logo></Properties>
</Package>
"@
    Write-Utf8NoBomText $xml (Join-Path $source 'AppxManifest.xml')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $Path)
    return $Path
}

function New-TestBundle(
    [string] $Path,
    [object[]] $Packages
) {
    $source = Join-Path $TestRoot "bundle-source-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $source 'AppxMetadata') -Force | Out-Null
    $packageXml = New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in $Packages) {
        $inner = Join-Path $source $package.FileName
        New-TestMsix $inner $package.Name $package.Publisher $package.Version `
            $package.Architecture @($package.Dependencies) | Out-Null
        $packageXml.Add("<Package Type=`"application`" Architecture=`"$($package.Architecture)`" FileName=`"$($package.FileName)`" />")
    }
    $bundle = @"
<?xml version="1.0" encoding="utf-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="Fixture.Bundle" Publisher="CN=Fixture" Version="1.0.0.0" />
  <Packages>$($packageXml -join '')</Packages>
</Bundle>
"@
    Write-Utf8NoBomText $bundle (Join-Path $source 'AppxMetadata/AppxBundleManifest.xml')
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $Path)
    return $Path
}

function New-PublishFixture([string] $Name) {
    $root = Join-Path $TestRoot $Name
    $output = Join-Path $root 'payload-container'
    $old = Join-Path $output 'generations/old-generation'
    $stage = Join-Path $root '.new-generation.stage'
    New-Item -ItemType Directory -Path $old, $stage -Force | Out-Null
    Write-Utf8NoBomText '{"schemaVersion":2,"files":[]}' `
        (Join-Path $old 'payload-manifest.json')
    Write-Utf8NoBomText '{"schemaVersion":2,"files":[]}' `
        (Join-Path $stage 'payload-manifest.json')
    [IO.File]::WriteAllText((Join-Path $old 'value.txt'), 'old')
    [IO.File]::WriteAllText((Join-Path $stage 'value.txt'), 'new')
    $oldHash = (Get-FileHash -LiteralPath (Join-Path $old 'payload-manifest.json') `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBomJson ([ordered]@{
        schemaVersion = 1
        generation = 'old-generation'
        manifestSha256 = $oldHash
    }) (Join-Path $output 'current.json')
    return [pscustomobject]@{ Root = $root; Output = $output; Stage = $stage }
}

try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null

    Assert-Equal `
        (Get-PackagePublisherId `
            'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') `
        '8wekyb3d8bbwe' 'Microsoft PublisherId known vector is incorrect'
    Assert-Equal `
        (Get-PackagePublisherId 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') `
        '2p2nqsd0c76g0' 'OpenAI PublisherId known vector is incorrect'
    $payloadFixture = Join-Path $PSScriptRoot 'fixtures/payload-root'
    $descriptorWork = Join-Path $TestRoot 'appx'
    $descriptor = Get-AppxPayloadDescriptor `
        (Join-Path $payloadFixture 'apps/Codex.msix') 'msix' `
        $payloadFixture $descriptorWork
    Assert-Equal $descriptor.Identity.Name 'OpenAI.Codex' `
        'MSIX manifest package name was not read'
    Assert-Equal $descriptor.Identity.Architecture 'x64' `
        'MSIX manifest architecture was not read'
    Assert-Equal $descriptor.Identity.PackageFamilyName `
        'OpenAI.Codex_2p2nqsd0c76g0' 'MSIX manifest PFN was not calculated'

    $graphRoot = Join-Path $TestRoot 'graph'
    New-Item -ItemType Directory -Path $graphRoot | Out-Null
    $mainPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
    $dependencyPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $dependencyRequirement = [pscustomobject]@{
        Name = 'Microsoft.VCLibs.140.00'
        Publisher = $dependencyPublisher
        MinVersion = '14.0.0.0'
    }
    $directMain = New-TestMsix (Join-Path $graphRoot 'main.msix') 'OpenAI.Codex' `
        $mainPublisher '26.7.27.0' 'x64' @($dependencyRequirement)
    $directDependency = New-TestMsix (Join-Path $graphRoot 'vclibs.msix') `
        'Microsoft.VCLibs.140.00' $dependencyPublisher '14.0.1.0' 'neutral'
    $directGraph = Get-AppxPayloadGraph -MainPath $directMain -Format 'msix' `
        -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-direct') `
        -CandidatePackages @([pscustomobject]@{ Path = $directDependency; Format = 'msix' })
    Assert-Equal $directGraph.Main.Identity.Name 'OpenAI.Codex' `
        'direct MSIX graph main identity is wrong'
    Assert-Equal @($directGraph.Dependencies).Count 1 `
        'direct MSIX dependency closure is not exact'
    Assert-Equal $directGraph.Dependencies[0].Identity.Architecture 'neutral' `
        'neutral dependency was not accepted'

    Assert-ThrowsLike {
        Get-AppxPayloadGraph -MainPath $directMain -Format 'msix' `
            -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-missing') `
            -CandidatePackages @() | Out-Null
    } '*missing dependency*' 'missing dependency was accepted'
    $oldDependency = New-TestMsix (Join-Path $graphRoot 'vclibs-old.msix') `
        'Microsoft.VCLibs.140.00' $dependencyPublisher '13.0.0.0' 'neutral'
    Assert-ThrowsLike {
        Get-AppxPayloadGraph -MainPath $directMain -Format 'msix' `
            -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-old') `
            -CandidatePackages @([pscustomobject]@{ Path = $oldDependency; Format = 'msix' }) |
            Out-Null
    } '*MinVersion*' 'dependency below MinVersion was accepted'
    $extraDependency = New-TestMsix (Join-Path $graphRoot 'extra.msix') `
        'Unrelated.Valid.Package' $dependencyPublisher '1.0.0.0' 'x64'
    Assert-ThrowsLike {
        Get-AppxPayloadGraph -MainPath $directMain -Format 'msix' `
            -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-extra') `
            -CandidatePackages @(
                [pscustomobject]@{ Path = $directDependency; Format = 'msix' },
                [pscustomobject]@{ Path = $extraDependency; Format = 'msix' }) | Out-Null
    } '*extra dependency*' 'unrelated valid dependency package was accepted'

    $bundle = New-TestBundle (Join-Path $graphRoot 'main.msixbundle') @(
        [pscustomobject]@{
            FileName = 'main-x64.msix'; Name = 'OpenAI.Codex'
            Publisher = $mainPublisher; Version = '26.7.27.0'; Architecture = 'x64'
            Dependencies = @($dependencyRequirement)
        },
        [pscustomobject]@{
            FileName = 'main-arm64.msix'; Name = 'OpenAI.Codex'
            Publisher = $mainPublisher; Version = '26.7.27.0'; Architecture = 'arm64'
            Dependencies = @()
        })
    $bundleGraph = Get-AppxPayloadGraph -MainPath $bundle -Format 'msixbundle' `
        -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-bundle') `
        -CandidatePackages @([pscustomobject]@{ Path = $directDependency; Format = 'msix' })
    Assert-Equal $bundleGraph.Main.Identity.Architecture 'x64' `
        'bundle did not select the exactly-one x64 main'
    $duplicateBundle = New-TestBundle (Join-Path $graphRoot 'duplicate.msixbundle') @(
        [pscustomobject]@{
            FileName = 'main-one.msix'; Name = 'OpenAI.Codex'
            Publisher = $mainPublisher; Version = '26.7.27.0'; Architecture = 'x64'
            Dependencies = @()
        },
        [pscustomobject]@{
            FileName = 'main-two.msix'; Name = 'OpenAI.Codex'
            Publisher = $mainPublisher; Version = '26.7.27.0'; Architecture = 'x64'
            Dependencies = @()
        })
    Assert-ThrowsLike {
        Get-AppxPayloadGraph -MainPath $duplicateBundle -Format 'msixbundle' `
            -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-duplicate') `
            -CandidatePackages @() | Out-Null
    } '*exactly one x64*' 'bundle with multiple x64 mains was accepted'
    $neutralBundle = New-TestBundle (Join-Path $graphRoot 'neutral.msixbundle') @(
        [pscustomobject]@{
            FileName = 'main-neutral.msix'; Name = 'OpenAI.Codex'
            Publisher = $mainPublisher; Version = '26.7.27.0'; Architecture = 'neutral'
            Dependencies = @()
        })
    Assert-ThrowsLike {
        Get-AppxPayloadGraph -MainPath $neutralBundle -Format 'msixbundle' `
            -PayloadRoot $graphRoot -WorkRoot (Join-Path $graphRoot 'work-neutral') `
            -CandidatePackages @() | Out-Null
    } '*exactly one x64*' 'neutral bundle application was accepted as the main'

    $storeRoot = Join-Path $graphRoot 'store'
    New-Item -ItemType Directory -Path $storeRoot | Out-Null
    Copy-Item -LiteralPath $directMain -Destination (Join-Path $storeRoot 'main.msix')
    Copy-Item -LiteralPath $directDependency -Destination (Join-Path $storeRoot 'vclibs.msix')
    $appInstaller = Join-Path $storeRoot 'Codex.appinstaller'
    Write-Utf8NoBomText @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2018" Version="1.0.0.0">
  <MainPackage Name="OpenAI.Codex" Publisher="$mainPublisher" Version="26.7.27.0" ProcessorArchitecture="x64" Uri="main.msix" />
  <Dependencies>
    <Package Name="Microsoft.VCLibs.140.00" Publisher="$dependencyPublisher" MinVersion="14.0.0.0" ProcessorArchitecture="neutral" Uri="vclibs.msix" />
  </Dependencies>
</AppInstaller>
"@ $appInstaller
    $appInstallerGraph = Get-AppxPayloadGraph -MainPath $appInstaller `
        -Format 'appinstaller' -PayloadRoot $graphRoot `
        -WorkRoot (Join-Path $graphRoot 'work-appinstaller') -CandidatePackages @()
    Assert-Equal @($appInstallerGraph.Dependencies).Count 1 `
        'AppInstaller dependency closure was not parsed'

    $caseRoot = Join-Path $TestRoot 'case-root'
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $casePackage = Join-Path $caseRoot 'main.msix'
    [IO.File]::WriteAllText($casePackage, 'fixture')
    $caseAppInstaller = Join-Path $caseRoot 'Codex.appinstaller'
    [IO.File]::WriteAllText($caseAppInstaller, 'fixture')
    $caseResolved = Resolve-AppInstallerPackagePath $caseRoot.ToUpperInvariant() `
        $caseAppInstaller 'main.msix' 'case-insensitive AppInstaller package'
    Assert-Equal $caseResolved $casePackage `
        'AppInstaller directory case variation was rejected'
    $outsideAppInstaller = Join-Path $TestRoot 'outside/Codex.appinstaller'
    Assert-ThrowsLike {
        Resolve-AppInstallerPackagePath $caseRoot $outsideAppInstaller 'main.msix' `
            'outside AppInstaller package' | Out-Null
    } '*outside payload root*' 'outside AppInstaller directory was accepted'

    $compiledFixturePolicy = Get-WindowsPayloadPolicy -FixtureMode
    $mutatedLock = Get-Content -LiteralPath (
        Join-Path $payloadFixture 'payload-lock.json') -Raw | ConvertFrom-Json
    $mutatedLock.components.'model-catalog'.relativePath = 'metadata/decoy.json'
    Assert-ThrowsLike {
        Assert-PayloadLockMatchesPolicy $mutatedLock $compiledFixturePolicy
    } '*compiled policy*' 'joint lock/manifest decoy could bypass compiled policy'

    $signaturePolicyPayload = Join-Path $TestRoot 'signature-policy-payload'
    Copy-Item -LiteralPath $payloadFixture -Destination $signaturePolicyPayload -Recurse
    $signatureManifestPath = Join-Path $signaturePolicyPayload 'payload-manifest.json'
    $signatureManifest = Get-Content -LiteralPath $signatureManifestPath -Raw |
        ConvertFrom-Json
    @($signatureManifest.files | Where-Object {
        $_.id -ceq 'codex-plus-plus-windows-x64'
    })[0].authenticodePolicy = 'valid'
    Write-Utf8NoBomJson $signatureManifest $signatureManifestPath
    Assert-ThrowsLike {
        & (Join-Path $WindowsRoot 'scripts/validate-offline-payloads.ps1') `
            -PayloadRoot $signaturePolicyPayload -FixtureMode | Out-Null
    } '*Codex++ Authenticode policy must be unsigned*' `
        'validator accepted a signed policy for the deliberately unsigned Codex++ build'

    $dependencyPayload = Join-Path $TestRoot 'dependency-payload'
    Copy-Item -LiteralPath $payloadFixture -Destination $dependencyPayload -Recurse
    $dependencyMain = Join-Path $dependencyPayload 'apps/Codex.msix'
    Move-Item -LiteralPath $dependencyMain -Destination (
        Join-Path $dependencyPayload 'apps/original-Codex.msix')
    New-TestMsix $dependencyMain 'OpenAI.Codex' $mainPublisher '26.7.27.0' `
        'x64' @($dependencyRequirement) | Out-Null
    $dependencyPath = Join-Path $dependencyPayload `
        'apps/dependencies/Codex-dependency-0.msix'
    New-TestMsix $dependencyPath 'Microsoft.VCLibs.140.00' $dependencyPublisher `
        '14.0.1.0' 'neutral' | Out-Null
    Remove-Item -LiteralPath (Join-Path $dependencyPayload 'apps/original-Codex.msix')
    $payloadManifestPath = Join-Path $dependencyPayload 'payload-manifest.json'
    $payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Raw |
        ConvertFrom-Json
    $codexEntry = @($payloadManifest.files | Where-Object id -CEQ 'codex-windows-x64')[0]
    $codexEntry.sha256 = Get-Sha256Hex $dependencyMain
    $codexEntry.size = [long] (Get-Item -LiteralPath $dependencyMain).Length
    $dependencyEntry = [pscustomobject]@{
        id = 'codex-dependency-0'
        version = '14.0.1.0'
        architecture = 'neutral'
        relativePath = 'apps/dependencies/Codex-dependency-0.msix'
        sha256 = Get-Sha256Hex $dependencyPath
        size = [long] (Get-Item -LiteralPath $dependencyPath).Length
        sourceURL = 'https://example.invalid/vclibs.msix'
        format = 'msix'
        packageName = 'Microsoft.VCLibs.140.00'
        packageFamilyName = "Microsoft.VCLibs.140.00_$(Get-PackagePublisherId $dependencyPublisher)"
        publisher = $dependencyPublisher
        minimumVersion = '14.0.0.0'
    }
    $payloadManifest.files = @($payloadManifest.files) + @($dependencyEntry)
    Write-Utf8NoBomJson $payloadManifest $payloadManifestPath
    & (Join-Path $WindowsRoot 'scripts/validate-offline-payloads.ps1') `
        -PayloadRoot $dependencyPayload -FixtureMode | Out-Null
    $payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Raw |
        ConvertFrom-Json
    @($payloadManifest.files | Where-Object id -CEQ 'codex-dependency-0')[0].publisher =
        'CN=Decoy'
    Write-Utf8NoBomJson $payloadManifest $payloadManifestPath
    Assert-ThrowsLike {
        & (Join-Path $WindowsRoot 'scripts/validate-offline-payloads.ps1') `
            -PayloadRoot $dependencyPayload -FixtureMode | Out-Null
    } '*dependency entry identity*' `
        'dependency manifest identity was trusted instead of actual MSIX identity'

    $matrix = Resolve-ImmutableScriptSource `
        -ScriptUrl 'https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/main/scripts/Codex%20Model%20Matrix.js' `
        -Id 'codex-native-matrix-selector' `
        -Commit 'b3c1d16d7d75145b9cf5b0e34000316436d905dd' `
        -Overrides @()
    Assert-Equal $matrix.SourceUrl `
        'https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/b3c1d16d7d75145b9cf5b0e34000316436d905dd/scripts/Codex%20Model%20Matrix.js' `
        'matrix selector must preserve the real upstream filename'
    Assert-Equal $matrix.LocalPath 'scripts/codex-native-matrix-selector.js' `
        'matrix selector local mapping is not canonical'

    $zhOverride = [pscustomobject]@{
        mode = 'pinned'
        id = 'codex-zhcn-translate'
        upstreamURL = 'https://raw.githubusercontent.com/hL091015/CodexPlusPlusScriptMarket/main/scripts/zh_CN%E6%B1%89%E5%8C%96.user.js'
        pinnedURL = 'https://raw.githubusercontent.com/hL091015/CodexPlusPlusScriptMarket/482076e76af9c78f18e3998bd99a96dc6033eb5d/scripts/zh_CN%E6%B1%89%E5%8C%96.user.js'
        pinnedSHA256 = 'be19a7930116dfe8fa1c68571d6a3bb3130714f77c7e32a6c1da543a182270f5'
        sourceCommit = '482076e76af9c78f18e3998bd99a96dc6033eb5d'
    }
    $zh = Resolve-ImmutableScriptSource -ScriptUrl $zhOverride.upstreamURL `
        -Id $zhOverride.id -Commit 'b3c1d16d7d75145b9cf5b0e34000316436d905dd' `
        -Overrides @($zhOverride)
    Assert-Equal $zh.SourceUrl $zhOverride.pinnedURL `
        'external translation script must use its pinned immutable URL'

    $managedCommit = '8f47a2b20bc7fd16b771ca51d5e409219f0fd7df'
    $managedOverride = [pscustomobject]@{
        mode = 'managed'
        id = 'codex-token-usage'
        upstreamURL = 'https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/main/scripts/codex-token-usage.js'
        upstreamSHA256 = '03808d22f53da374837227636ebd9f1ba593fe5aba6219e90e636d7ed7c806eb'
        managedSource = 'script-market-sources/codex-token-usage.js'
        managedURL = "https://raw.githubusercontent.com/fancr-code/Uni-codex/$managedCommit/Resources/script-market-sources/codex-token-usage.js"
        managedSHA256 = 'bf233607f8e60f56b3c68d29c15bbd5ed5d7582fc488380f56b8d2f553bb4ddd'
        sourceCommit = $managedCommit
        provenance = 'codex-token-usage-dedupe-v1'
    }
    $managed = Resolve-ImmutableScriptSource `
        -ScriptUrl $managedOverride.upstreamURL `
        -Id $managedOverride.id `
        -Commit 'b3c1d16d7d75145b9cf5b0e34000316436d905dd' `
        -Overrides @($managedOverride)
    Assert-Equal $managed.SourceKind 'managed' `
        'managed monitor override must be copied from the reviewed repository source'
    Assert-Equal $managed.SourceUrl $managedOverride.managedURL `
        'managed monitor override must publish immutable provenance'
    Assert-Equal $managed.SourceCommit $managedCommit `
        'managed monitor override must publish its reviewed source commit'
    Assert-Equal $managed.Sha256 $managedOverride.managedSHA256 `
        'managed monitor override must pin the reviewed bytes'
    Assert-Equal ([IO.Path]::GetFileName($managed.SourcePath)) `
        'codex-token-usage.js' 'managed monitor source path is wrong'

    $managedOverride.managedSHA256 =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    Assert-ThrowsLike {
        Resolve-ImmutableScriptSource -ScriptUrl $managedOverride.upstreamURL `
            -Id $managedOverride.id `
            -Commit 'b3c1d16d7d75145b9cf5b0e34000316436d905dd' `
            -Overrides @($managedOverride)
    } '*managed script hash mismatch*' `
        'managed monitor override accepted bytes outside its reviewed hash'

    $jsonPath = Join-Path $TestRoot 'no-bom.json'
    Write-Utf8NoBomJson -InputObject ([ordered]@{ schemaVersion = 2 }) -Path $jsonPath
    $bytes = [IO.File]::ReadAllBytes($jsonPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw 'UTF-8 JSON writer emitted a BOM'
    }

    foreach ($fault in @(
            'PointerWrite', 'PointerFlush', 'BeforeCommit', 'PointerReplace')) {
        $fixture = New-PublishFixture $fault
        Assert-ThrowsLike {
            Publish-PayloadGeneration -StageRoot $fixture.Stage `
                -OutputRoot $fixture.Output -GenerationId "new-$($fault.ToLowerInvariant())" `
                -TestFault $fault
        } '*publish fault*' "publish fault was not raised: $fault"
        $active = Resolve-ActivePayloadRoot $fixture.Output
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $active 'value.txt'))) `
            'old' "old pointer changed before commit for $fault"
    }

    $firstRoot = Join-Path $TestRoot 'first-publish'
    $firstOutput = Join-Path $firstRoot 'payload-container'
    $firstStage = Join-Path $firstRoot '.first.stage'
    New-Item -ItemType Directory -Path $firstStage -Force | Out-Null
    Write-Utf8NoBomText '{"schemaVersion":2,"files":[]}' `
        (Join-Path $firstStage 'payload-manifest.json')
    [IO.File]::WriteAllText((Join-Path $firstStage 'value.txt'), 'first')
    Publish-PayloadGeneration $firstStage $firstOutput 'first-generation'
    $firstActive = Resolve-ActivePayloadRoot $firstOutput
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $firstActive 'value.txt'))) `
        'first' 'initial pointer move did not publish the first generation'
    $pointerBytes = [IO.File]::ReadAllBytes((Join-Path $firstOutput 'current.json'))
    if ($pointerBytes.Length -ge 3 -and $pointerBytes[0] -eq 0xef -and
        $pointerBytes[1] -eq 0xbb -and $pointerBytes[2] -eq 0xbf) {
        throw 'current.json contains a UTF-8 BOM'
    }

    $afterCommit = New-PublishFixture 'AfterCommit'
    Assert-ThrowsLike {
        Publish-PayloadGeneration $afterCommit.Stage $afterCommit.Output `
            'new-after-commit' -TestFault 'AfterCommit'
    } '*publish fault*' 'after-commit crash was not injected'
    $afterActive = Resolve-ActivePayloadRoot $afterCommit.Output
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $afterActive 'value.txt'))) `
        'new' 'after-commit crash did not leave the new pointer authoritative'

    $cleanup = New-PublishFixture 'Cleanup'
    Publish-PayloadGeneration $cleanup.Stage $cleanup.Output `
        'new-cleanup' -TestFault 'Cleanup'
    $cleanupActive = Resolve-ActivePayloadRoot $cleanup.Output
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $cleanupActive 'value.txt'))) `
        'new' 'cleanup failure changed a committed pointer'

    $crashBefore = New-PublishFixture 'CrashBeforeCommit'
    Assert-ThrowsLike {
        Publish-PayloadGeneration $crashBefore.Stage $crashBefore.Output `
            'new-crash-before' -TestFault 'CrashBeforeCommit'
    } '*publish fault*' 'before-commit crash was not injected'
    Assert-Equal (Split-Path -Leaf (Resolve-ActivePayloadRoot $crashBefore.Output)) `
        'old-generation' 'before-commit crash changed current generation'

    $invalid = New-PublishFixture 'InvalidPointer'
    foreach ($generation in @('../escape', '/absolute', 'bad\\path', '.')) {
        $pointer = Get-Content -LiteralPath (Join-Path $invalid.Output 'current.json') -Raw |
            ConvertFrom-Json
        $pointer.generation = $generation
        Write-Utf8NoBomJson $pointer (Join-Path $invalid.Output 'current.json')
        Assert-ThrowsLike {
            Resolve-ActivePayloadRoot $invalid.Output | Out-Null
        } '*generation*' "unsafe current generation was accepted: $generation"
    }
    $invalidHash = New-PublishFixture 'InvalidPointerHash'
    $pointer = Get-Content -LiteralPath (Join-Path $invalidHash.Output 'current.json') -Raw |
        ConvertFrom-Json
    $pointer.manifestSha256 = 'not-a-sha'
    Write-Utf8NoBomJson $pointer (Join-Path $invalidHash.Output 'current.json')
    Assert-ThrowsLike {
        Resolve-ActivePayloadRoot $invalidHash.Output | Out-Null
    } '*SHA256*' 'invalid current pointer SHA256 was accepted'
    $mismatch = New-PublishFixture 'PointerManifestMismatch'
    [IO.File]::AppendAllText(
        (Join-Path $mismatch.Output 'generations/old-generation/payload-manifest.json'),
        ' ')
    Assert-ThrowsLike {
        Resolve-ActivePayloadRoot $mismatch.Output | Out-Null
    } '*manifest SHA256 mismatch*' 'pointer did not bind the active manifest hash'

    Write-Output 'offline-payload-supply-tests: PASS'
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
