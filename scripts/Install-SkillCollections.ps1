#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '../skills/collections.json'),
    [string] $BundleRoot = '',
    [string] $DestinationRoot = (Join-Path $HOME '.codex/skills'),
    [switch] $PrepareBundle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) "uni-codex-skills-$([Guid]::NewGuid().ToString('N'))"

function Copy-CollectionSkills([string] $Source, [string] $RepositoryRoot, [object] $Collection) {
    $collectionDestination = if ($PrepareBundle) {
        Join-Path $DestinationRoot "$($Collection.id)/skills"
    } else { $DestinationRoot }
    New-Item -ItemType Directory -Path $collectionDestination -Force | Out-Null
    $skills = @(Get-ChildItem -LiteralPath $Source -Recurse -Filter SKILL.md -File |
        ForEach-Object { $_.Directory } | Sort-Object FullName -Unique)
    if ($skills.Count -eq 0) { throw "No skills found for $($Collection.id)" }
    foreach ($skill in $skills) {
        $name = $skill.Name
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Unsafe skill name: $name" }
        $target = Join-Path $collectionDestination $name
        if (Test-Path -LiteralPath $target) {
            $marker = Join-Path $target '.uni-codex-collection.json'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
                Write-Warning "Keeping user-managed skill: $name"
                continue
            }
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        & robocopy.exe $skill.FullName $target /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Unable to copy skill: $name" }
        $global:LASTEXITCODE = 0
        [ordered]@{ collection = $Collection.id; repository = $Collection.repository; commit = $Collection.commit } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.uni-codex-collection.json') -Encoding UTF8
    }
    $license = Get-ChildItem -LiteralPath $RepositoryRoot -File |
        Where-Object { $_.Name -match '^(LICENSE|COPYING)(\..+)?$' } |
        Select-Object -First 1
    if ($null -eq $license) { throw "License missing for $($Collection.id)" }
    $licenseTarget = if ($PrepareBundle) {
        Join-Path $DestinationRoot "$($Collection.id)/LICENSE"
    } else {
        Join-Path $DestinationRoot ".uni-codex-licenses/$($Collection.id)/LICENSE"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $licenseTarget) -Force | Out-Null
    Copy-Item -LiteralPath $license.FullName -Destination $licenseTarget -Force
    return $skills.Count
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Path $DestinationRoot, $work -Force | Out-Null
    $total = 0
    foreach ($collection in @($manifest.collections)) {
        if ([string] $collection.commit -notmatch '^[0-9a-f]{40}$') { throw "Unpinned collection: $($collection.id)" }
        if ($BundleRoot) {
            $repositoryRoot = Join-Path $BundleRoot ([string] $collection.id)
            $source = Join-Path $repositoryRoot 'skills'
        } else {
            $zip = Join-Path $work "$($collection.id).zip"
            $expanded = Join-Path $work $collection.id
            $uri = "https://codeload.github.com/$($collection.repository)/zip/$($collection.commit)"
            $curl = Get-Command curl.exe -ErrorAction Stop
            & $curl.Source --fail --location --retry 3 --connect-timeout 20 `
                --output $zip $uri
            if ($LASTEXITCODE -ne 0) { throw "Unable to download $($collection.id)" }
            New-Item -ItemType Directory -Path $expanded -Force | Out-Null
            $tar = Get-Command tar.exe -ErrorAction Stop
            & $tar.Source -xf $zip -C $expanded
            if ($LASTEXITCODE -ne 0) { throw "Unable to extract $($collection.id)" }
            $repoRoot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
            $repositoryRoot = $repoRoot.FullName
            $source = Join-Path $repoRoot.FullName ([string] $collection.skillsRoot)
        }
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Missing collection root: $source" }
        $total += Copy-CollectionSkills $source $repositoryRoot $collection
    }
    Write-Host "Installed $total Codex skills into $DestinationRoot"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
