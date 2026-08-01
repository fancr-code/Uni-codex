#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StageRoot,
    [Parameter(Mandatory)] [string] $Output
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string] $Message) { throw "generate-sbom: $Message" }
function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}
function Normalize-Relative([string] $Root, [string] $Path) {
    return $Path.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    Fail "stage root is missing: $StageRoot"
}
$root = (Resolve-Path -LiteralPath $StageRoot).Path
foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "stage contains a symbolic link or reparse point: $($item.FullName)"
    }
}
$files = New-Object 'System.Collections.Generic.List[object]'
$verificationHashes = New-Object 'System.Collections.Generic.List[string]'
$stageDigestStream = New-Object IO.MemoryStream
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($item in @(
    Get-ChildItem -LiteralPath $root -Force -Recurse -File |
        Sort-Object { Normalize-Relative $root $_.FullName }
)) {
    $relative = Normalize-Relative $root $item.FullName
    $sha256 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash).
        ToLowerInvariant()
    $sha1 = ((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA1).Hash).
        ToLowerInvariant()
    $verificationHashes.Add($sha1)
    $record = "$relative`0$sha256`0$($item.Length)`n"
    $recordBytes = $utf8.GetBytes($record)
    $stageDigestStream.Write($recordBytes, 0, $recordBytes.Length)
    $idSha = [Security.Cryptography.SHA256]::Create()
    try {
        $spdxId = 'SPDXRef-File-' + (
            [BitConverter]::ToString($idSha.ComputeHash($utf8.GetBytes($relative)))
        ).Replace('-', '').ToLowerInvariant()
    } finally {
        $idSha.Dispose()
    }
    $files.Add([ordered]@{
        SPDXID = $spdxId
        fileName = './' + $relative
        checksums = @(
            [ordered]@{ algorithm = 'SHA1'; checksumValue = $sha1 },
            [ordered]@{ algorithm = 'SHA256'; checksumValue = $sha256 }
        )
        licenseConcluded = 'NOASSERTION'
        licenseInfoInFiles = @('NOASSERTION')
        copyrightText = 'NOASSERTION'
    })
}
$stageDigestStream.Position = 0
$stageSha = [Security.Cryptography.SHA256]::Create()
try {
    $namespaceSeed = ([BitConverter]::ToString(
        $stageSha.ComputeHash($stageDigestStream))).Replace('-', '').ToLowerInvariant()
} finally {
    $stageSha.Dispose()
    $stageDigestStream.Dispose()
}
$verificationText = (@($verificationHashes.ToArray()) | Sort-Object) -join ''
$verificationBytes = $utf8.GetBytes($verificationText)
$verificationSha = [Security.Cryptography.SHA1]::Create()
try {
    $packageVerificationCode = ([BitConverter]::ToString(
        $verificationSha.ComputeHash($verificationBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $verificationSha.Dispose()
}
$created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$relationships = New-Object 'System.Collections.Generic.List[object]'
$relationships.Add([ordered]@{
    spdxElementId = 'SPDXRef-DOCUMENT'
    relationshipType = 'DESCRIBES'
    relatedSpdxElement = 'SPDXRef-Package'
})
foreach ($file in $files) {
    $relationships.Add([ordered]@{
        spdxElementId = 'SPDXRef-Package'
        relationshipType = 'CONTAINS'
        relatedSpdxElement = $file.SPDXID
    })
}
$document = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = 'Codex-One-Click-Windows-x64-Offline'
    documentNamespace = "https://codex-kit.invalid/spdx/$namespaceSeed"
    creationInfo = [ordered]@{
        created = $created
        creators = @('Tool: windows/scripts/generate-sbom.ps1')
    }
    packages = @(
        [ordered]@{
            name = 'Codex One Click Windows Offline Installer Stage'
            SPDXID = 'SPDXRef-Package'
            versionInfo = '1.0.0'
            downloadLocation = 'NOASSERTION'
            filesAnalyzed = $true
            packageVerificationCode = [ordered]@{
                packageVerificationCodeValue = $packageVerificationCode
            }
            licenseConcluded = 'NOASSERTION'
            licenseDeclared = 'NOASSERTION'
            copyrightText = 'NOASSERTION'
        }
    )
    files = @($files.ToArray())
    relationships = @($relationships.ToArray())
}
$outputPath = [IO.Path]::GetFullPath($Output)
$outputParent = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
$temporary = Join-Path $outputParent ('.sbom-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    Write-Utf8NoBom $temporary (($document | ConvertTo-Json -Depth 12) + "`n")
    Move-Item -LiteralPath $temporary -Destination $outputPath -Force
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
Write-Host "generate-sbom: wrote $outputPath"
