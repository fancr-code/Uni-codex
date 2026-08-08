#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $SkipCodex,
    [switch] $SkipCodexPlusPlus,
    [switch] $Quiet,
    [string] $BundledCodexPlusPlus = '',
    [ValidateSet('preset-gothic-void-crusade', 'gallery', 'none')]
    [string] $DreamSkinPreset = 'preset-gothic-void-crusade'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProductId = '9PLM9XGG6VKS'
$OfficialWindowsInstaller = 'https://get.microsoft.com/installer/download/9PLM9XGG6VKS?cid=website_cta_psi'
$CodexPlusRepository = 'BigPizzaV3/CodexPlusPlus'
$DreamSkinVersion = '1.5.11'
$DreamSkinInstallerUrl = "https://github.com/Fei-Away/Codex-Dream-Skin/releases/download/v$DreamSkinVersion/CodexDreamSkin-Setup-v$DreamSkinVersion.exe"
$DreamSkinInstallerSha256 = 'b63aab7339fddd677db48d83b3a1b2f465851b886640989bce6b649cba407934'
$DreamSkinThemeIds = @(
    'ver_ab667004dad5bfec326d',
    'ver_6fac938806981a73cb51',
    'ver_f2b255d03e6ac7f91ada',
    'ver_a5a7c185610e6ccee928',
    'ver_4367ae5c3ef91daf8efa',
    'ver_1f00673afb67fd30f91e',
    'ver_5c32fdc7b685ede6fd07',
    'ver_2b3bc79cfe2e5141c7a2',
    'ver_4e1216c88d5cb2a39c53',
    'ver_dd3882239f93b014ba65'
)
$DreamSkinThemeSha256 = @(
    'b2892300bdfb1229a092c140c5fd5de41fa27b97db6ec7e827c3ae0f9d75af44',
    '00f6adab28a022bad16c5ff8139dd3b11a59415ad7912034dff372b68baa56ef',
    'fcbdc5efebbf43db7cdbbe9ae213b71da6daa33ef59e36e1b8567a6a20cabdc0',
    '607c5c6bc6989aa5113446a5beac3fdecff4dcc8123b430c242b9827ab2c0cd5',
    '5b7e72fa46f9da7a42be45a9689342c1506158e19f40a8c8fe9f747b707195cc',
    '058ab04d118bd66da7be082ebd8dba81dd0a285e6b68b356287ff870caff9ff9',
    '2c820302ab365aa364b8aed2c6e5395ba3e1f6baec9d06ee04c68c6e699e8b67',
    'a1c7e626121cf32693f2ec46dceaa8e1592bdb054c25a9ae50daf87710223996',
    'cd6c95bfe5bf6079ef450c3c552ad0f52fafe594aa16196ce8645d9ad7916e67',
    '20bd5ef48ad62ebbf6e35810399c7b86986a7594468a8b507188a13dbbec5b3c'
)
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) "uni-codex-$([Guid]::NewGuid().ToString('N'))"

function Write-Step([string] $Message) {
    if (-not $Quiet) { Write-Host "==> $Message" -ForegroundColor Cyan }
}

function Assert-HttpsGitHubUri([uri] $Uri) {
    if ($Uri.Scheme -cne 'https' -or
        ($Uri.Host -cne 'github.com' -and
         $Uri.Host -cne 'objects.githubusercontent.com' -and
         -not $Uri.Host.EndsWith('.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase))) {
        throw "Untrusted GitHub download URI: $Uri"
    }
}

function Invoke-VerifiedDownload([uri] $Uri, [string] $Destination, [string] $ExpectedDigest) {
    Assert-HttpsGitHubUri $Uri
    Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 -Uri $Uri.AbsoluteUri -OutFile $Destination
    $item = Get-Item -LiteralPath $Destination
    if ($item.Length -eq 0) { throw "Downloaded file is empty: $Uri" }
    if ($ExpectedDigest -match '^sha256:([0-9a-fA-F]{64})$') {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($actual -cne $Matches[1].ToUpperInvariant()) {
            throw "SHA-256 mismatch for $($item.Name)"
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Destination
    if ($signature.Status -notin @(
            [Management.Automation.SignatureStatus]::Valid,
            [Management.Automation.SignatureStatus]::NotSigned)) {
        throw "Invalid Authenticode signature status: $($signature.Status)"
    }
}

function Install-CodexDesktop {
    if ($SkipCodex) { return }
    if (Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue) {
        Write-Step 'Codex desktop is already installed'
        return
    }
    $officialInstaller = Join-Path $WorkRoot 'OpenAI-Codex-Installer.exe'
    try {
        Write-Step 'Downloading the official OpenAI Windows installer'
        $uri = [uri] $OfficialWindowsInstaller
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'get.microsoft.com') {
            throw "Untrusted OpenAI installer URI: $uri"
        }
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 `
            -Uri $uri.AbsoluteUri -OutFile $officialInstaller
        $bytes = [IO.File]::ReadAllBytes($officialInstaller)
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
            throw 'Official Windows installer response is not a PE executable'
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $officialInstaller
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "Official Windows installer signature is not trusted: $($signature.Status)"
        }
        $process = Start-Process -FilePath $officialInstaller -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Official Windows installer failed: $($process.ExitCode)" }
        return
    } catch {
        Write-Warning "Official OpenAI installer failed; falling back to Microsoft Store: $($_.Exception.Message)"
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Start-Process "ms-windows-store://pdp/?ProductId=$ProductId"
        throw 'Microsoft Store was opened. Install Codex, then run Uni-codex again.'
    }
    Write-Step 'Installing Codex desktop from Microsoft Store fallback'
    & $winget.Source install --id $ProductId --exact --source msstore `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "Microsoft Store install failed: $LASTEXITCODE" }
}

function Resolve-CodexPlusPlusInstaller {
    if ($BundledCodexPlusPlus) {
        $resolved = [IO.Path]::GetFullPath($BundledCodexPlusPlus)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Bundled Codex++ installer is missing: $resolved"
        }
        return $resolved
    }
    Write-Step 'Resolving the latest Codex++ GitHub release'
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Uni-codex' }
    $release = Invoke-RestMethod -Headers $headers `
        -Uri "https://api.github.com/repos/$CodexPlusRepository/releases/latest"
    $assets = @($release.assets | Where-Object {
        $_.name -match 'windows-x64-setup\.exe$'
    })
    if ($assets.Count -ne 1) { throw 'Expected exactly one Windows x64 Codex++ installer asset' }
    $asset = $assets[0]
    $destination = Join-Path $WorkRoot ([string] $asset.name)
    Invoke-VerifiedDownload ([uri] $asset.browser_download_url) $destination ([string] $asset.digest)
    return $destination
}

function Install-CodexPlusPlus {
    if ($SkipCodexPlusPlus) { return }
    $installer = Resolve-CodexPlusPlusInstaller
    Write-Step 'Installing Codex++'
    $process = Start-Process -FilePath $installer -ArgumentList @('/S') -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Codex++ installer failed: $($process.ExitCode)" }
}

function Install-DreamSkin {
    if ($DreamSkinPreset -eq 'none') {
        Write-Step 'Keeping the official Codex appearance'
        return
    }
    $installer = Join-Path $WorkRoot "CodexDreamSkin-Setup-v$DreamSkinVersion.exe"
    if ($DreamSkinPreset -eq 'gallery') {
        Write-Step "Installing Codex Dream Skin v$DreamSkinVersion and preparing 10 curated themes"
    } else {
        Write-Step "Installing Codex Dream Skin v$DreamSkinVersion (Gothic Void Crusade)"
    }
    Invoke-VerifiedDownload ([uri]$DreamSkinInstallerUrl) $installer "sha256:$DreamSkinInstallerSha256"
    $bytes = [IO.File]::ReadAllBytes($installer)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw 'Codex Dream Skin download is not a PE executable'
    }
    $process = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Codex Dream Skin installer failed: $($process.ExitCode)" }
}

function Invoke-VerifiedDreamSkinThemeDownload([string] $VersionId, [string] $Destination, [string] $ExpectedSha256) {
    $url = "https://api.dreamskin.cc/v1/themes/$VersionId/download"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        & $curl.Source '--fail' '--location' '--retry' '3' '--connect-timeout' '20' '--max-time' '600' `
            '--user-agent' 'Uni-codex DreamSkin theme seeder' '--output' $Destination $url
        if ($LASTEXITCODE -ne 0) { throw "DreamSkin.cc theme download failed: $VersionId" }
    } else {
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 10 -Uri $url -OutFile $Destination
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedSha256) {
        throw "DreamSkin.cc theme SHA-256 mismatch: $VersionId"
    }
}

function Import-DreamSkinThemeArchive([string] $ArchivePath) {
    $extractRoot = Join-Path $WorkRoot ("theme-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force
    $manifestPath = Join-Path $extractRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "DreamSkin.cc theme manifest is missing: $ArchivePath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($manifest.platforms) -notcontains 'windows' -or
        [string]::IsNullOrWhiteSpace([string]$manifest.themeId) -or
        [string]$manifest.themeId -notmatch '\A[A-Za-z0-9._-]+\z') {
        throw "DreamSkin.cc theme does not support Windows: $ArchivePath"
    }
    foreach ($required in @('theme.json', 'theme.css')) {
        if (-not (Test-Path -LiteralPath (Join-Path $extractRoot $required) -PathType Leaf)) {
            throw "DreamSkin.cc theme is missing ${required}: $ArchivePath"
        }
    }
    $themesRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\themes'
    New-Item -ItemType Directory -Path $themesRoot -Force | Out-Null
    $destination = Join-Path $themesRoot ([string]$manifest.themeId)
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -Path (Join-Path $extractRoot '*') -Destination $destination -Recurse -Force
}

function Install-DreamSkinThemes {
    $index = 0
    foreach ($id in $DreamSkinThemeIds) {
        $archive = Join-Path $WorkRoot "$id.zip"
        Write-Step "Downloading DreamSkin.cc theme $($index + 1)/$($DreamSkinThemeIds.Count)"
        Invoke-VerifiedDreamSkinThemeDownload $id $archive $DreamSkinThemeSha256[$index]
        Import-DreamSkinThemeArchive $archive
        $index++
    }
    Write-Step "Installed $($DreamSkinThemeIds.Count) curated DreamSkin.cc themes"
}

function Install-SkillCollections {
    $installer = Join-Path $PSScriptRoot 'Install-SkillCollections.ps1'
    $manifest = Join-Path $PSScriptRoot 'skills/collections.json'
    if (-not (Test-Path -LiteralPath $installer) -or -not (Test-Path -LiteralPath $manifest)) {
        throw 'Uni-codex skill collection resources are missing'
    }
    Write-Step 'Installing Nature, scientific-agent, and research skills'
    & $installer -ManifestPath $manifest
}

try {
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    Install-CodexDesktop
    Install-CodexPlusPlus
    Install-DreamSkin
    if ($DreamSkinPreset -ne 'none') {
        Install-DreamSkinThemes
        if ($DreamSkinPreset -eq 'gallery') {
            Start-Process 'https://dreamskin.cc/gallery'
        }
    }
    Install-SkillCollections
    Write-Step 'Uni-codex installation completed'
} finally {
    if (Test-Path -LiteralPath $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
