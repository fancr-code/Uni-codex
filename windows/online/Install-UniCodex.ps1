#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $SkipCodex,
    [switch] $SkipCodexPlusPlus,
    [switch] $Quiet,
    [string] $BundledCodexPlusPlus = '',
    [ValidateSet('preset-gothic-void-crusade', 'none')]
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
    Write-Step "Installing Codex Dream Skin v$DreamSkinVersion (Gothic Void Crusade)"
    Invoke-VerifiedDownload ([uri]$DreamSkinInstallerUrl) $installer "sha256:$DreamSkinInstallerSha256"
    $bytes = [IO.File]::ReadAllBytes($installer)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw 'Codex Dream Skin download is not a PE executable'
    }
    $process = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Codex Dream Skin installer failed: $($process.ExitCode)" }
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
    Install-SkillCollections
    Write-Step 'Uni-codex installation completed'
} finally {
    if (Test-Path -LiteralPath $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
