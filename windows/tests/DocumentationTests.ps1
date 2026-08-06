#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) {
        throw "DocumentationTests: $Message"
    }
}

function Read-Required([string] $Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "missing $Path"
    (Get-Content -LiteralPath $Path -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Assert-Contains(
    [string] $Text,
    [string] $Value,
    [string] $Description
) {
    Assert-True $Text.Contains($Value) "$Description omitted '$Value'"
}

$rootReadmePath = Join-Path $RepositoryRoot 'README.md'
$windowsReadmePath = Join-Path $WindowsRoot 'README.md'
$windowsBeginnerPath = Join-Path $WindowsRoot `
    'docs/guides/Beginner-Guide.zh-CN.html'
$windowsOpenPath = Join-Path $WindowsRoot `
    'docs/guides/Open-Guide.zh-CN.txt'
$resourceBeginnerPath = Join-Path $RepositoryRoot `
    'Resources/guides/Beginner-Guide.zh-CN.html'
$resourceOpenPath = Join-Path $RepositoryRoot `
    'Resources/guides/Open-Guide.zh-CN.txt'

$rootReadme = Read-Required $rootReadmePath
$windowsReadme = Read-Required $windowsReadmePath
$windowsBeginner = Read-Required $windowsBeginnerPath
$windowsOpen = Read-Required $windowsOpenPath
$resourceBeginner = Read-Required $resourceBeginnerPath
$resourceOpen = Read-Required $resourceOpenPath
$windowsCorpus = @(
    $rootReadme,
    $windowsReadme,
    $windowsBeginner,
    $windowsOpen
) -join "`n"

foreach ($value in @(
    'Codex-One-Click-Windows-x64-Offline-Setup.exe',
    'SHA256SUMS.txt',
    'Windows 10',
    '1809',
    '17763',
    'x64',
    'unsigned',
    'SmartScreen'
)) {
    Assert-Contains $windowsCorpus $value 'formal Windows guidance'
}
foreach ($forbidden in @(
    'raw.githubusercontent.com/fancr-code/Uni-codex/main/windows',
    'codex-app-mirror',
    'Codex-Windows-Setup-{version}-payload.zip',
    'Codex-Windows-OneClick.ps1 -Provider',
    '从 codex-app-mirror 下载'
)) {
    Assert-True (-not $windowsCorpus.Contains($forbidden)) `
        "formal guidance retained forbidden legacy claim '$forbidden'"
}

foreach ($value in @(
    'DeepSeek',
    'Kimi 开放平台',
    'Kimi Code',
    '智谱 GLM',
    '阿里千问',
    'Xiaomi MiMo',
    'Kimi K3',
    '上游模型',
    '离线快照',
    '获取 OpenAI 授权',
    'OpenAI 账号 + 所选国产 API',
    '授权不等于 GPT API Key',
    'GPT API 额度',
    '账号未拥有'
)) {
    Assert-Contains $windowsCorpus $value 'provider and authorization guidance'
}
foreach ($url in @(
    'https://platform.deepseek.com/api_keys',
    'https://platform.moonshot.cn/console/api-keys',
    'https://www.kimi.com/code/console',
    'https://bigmodel.cn/usercenter/apikeys',
    'https://bailian.console.aliyun.com/cn-beijing?tab=model',
    'https://platform.xiaomimimo.com/'
)) {
    Assert-Contains $windowsCorpus $url 'official provider links'
}
foreach ($value in @(
    '健康',
    '不重复安装',
    'cross-provider-content-v1',
    '预配置 3 个市场',
    '9 个插件',
    '5 个插件离线实装',
    '4 个官方生产力插件',
    '完整脚本市场',
    'Context Used Meter',
    'Codex Token Usage',
    'API Key',
    'OAuth Token',
    '脱敏'
)) {
    Assert-Contains $windowsCorpus $value 'installed capability and privacy guidance'
}
foreach ($value in @(
    'Research Kit 是 macOS',
    '不随 Windows 安装包预装'
)) {
    Assert-Contains $windowsCorpus $value 'Windows Research Kit boundary'
}
foreach ($value in @(
    '更多信息',
    '仍要运行',
    '不匹配',
    '会话页左上角',
    '最新助手消息',
    'Scripts/脚本市场',
    '自动回滚',
    '%LOCALAPPDATA%\Codex One Click Installer\reports'
)) {
    Assert-Contains $windowsBeginner $value 'Windows beginner safety and operations'
}
foreach ($value in @(
    '1.',
    '2.',
    '3.',
    '4.',
    '5.',
    '更多信息',
    '仍要运行',
    '自动回滚',
    '%LOCALAPPDATA%\Codex One Click Installer\reports'
)) {
    Assert-Contains $windowsOpen $value 'Windows open guide steps'
}
foreach ($value in @(
    '.github/workflows/online-release.yml',
    'macos/',
    'windows/',
    'Resources/',
    '.github/workflows/'
)) {
    Assert-Contains $rootReadme $value 'root maintainer documentation'
}
$developerDocs = [ordered]@{
    windows = $windowsReadme
}
foreach ($entry in $developerDocs.GetEnumerator()) {
    foreach ($value in @(
        '.NET 8',
        'Node.js 22',
        'Rust stable',
        'NSIS',
        'Inno Setup 7.0.2',
        'build-codex-plus-compatibility-payload.ps1',
        'v1.2.44-cross-provider-history.patch',
        '-OutputRoot $compat',
        'refresh-offline-payloads.ps1',
        '-CodexPlusPlusSetup',
        '-CodexPlusPlusSource',
        'offline-payload-supply.ps1',
        'Resolve-ActivePayloadRoot',
        'run-all-tests.ps1',
        '-PayloadRoot $active',
        '-BuiltRoot $compat',
        'build-installer.ps1',
        '-IsccPath $iscc',
        '-OutputDir dist'
    )) {
        Assert-Contains $entry.Value $value `
            "developer chain in $($entry.Key) README"
    }
    Assert-True (
        $entry.Value -notmatch
            '-PayloadRoot\s+(windows/vendor/offline-payloads|\.\\vendor\\offline-payloads)'
    ) "$($entry.Key) README passes the payload container directly"
}
foreach ($value in @(
    '-Patch ..\patches\CodexPlusPlus\v1.2.44-cross-provider-history.patch',
    '-OutputRoot .\vendor\offline-payloads',
    "GetFullPath('.\vendor\offline-payloads')",
    '-TestResultsRoot .\test-results\full'
)) {
    Assert-Contains $windowsReadme $value 'windows-directory checkout-relative chain'
}

$guides = [ordered]@{
    windowsBeginner = $windowsBeginner
    windowsOpen = $windowsOpen
    resourceBeginner = $resourceBeginner
    resourceOpen = $resourceOpen
}
foreach ($entry in $guides.GetEnumerator()) {
    foreach ($value in @(
        'DeepSeek',
        'Kimi 开放平台',
        'Kimi Code',
        '智谱 GLM',
        '阿里千问',
        'Xiaomi MiMo',
        '所选服务商',
        'Uni-Scholar',
        'Research Kit',
        'Zotero',
        'Obsidian',
        '本地知识库',
        'Codex/Codex++',
        '连续科研工作流',
        'https://uni-scholar.asia',
        'https://uni-scholar.asia/research-kit'
    )) {
        Assert-Contains $entry.Value $value "guide $($entry.Key)"
    }
    Assert-True (
        $entry.Value -notmatch '默认[：:]\s*DeepSeek\s*/\s*Kimi'
    ) "guide $($entry.Key) still claims a DeepSeek/Kimi-only default"
    Assert-True (
        $entry.Value -notmatch '仅支持.{0,20}DeepSeek.{0,20}Kimi'
    ) "guide $($entry.Key) still claims only DeepSeek/Kimi support"
}
foreach ($value in @(
    'ad-hoc',
    '尚未经过 Apple Developer ID 公证',
    'Finder',
    'Control',
    '右键打开',
    'SHA-256',
    '不要关闭',
    '受管设备',
    '联系管理员'
)) {
    Assert-Contains $resourceOpen $value 'macOS first-open safety'
}
foreach ($value in @(
    'Apple Silicon',
    'Intel Mac',
    '离线安装',
    '健康 Codex',
    '成对复用',
    '成对升级',
    '跨供应商旧会话',
    '本机转换',
    '不记录消息正文',
    '恢复最近备份',
    '自动回滚',
    '会话页左上角',
    '最新助手消息',
    'Scripts/脚本市场'
)) {
    Assert-Contains $resourceBeginner $value 'macOS beginner operations'
}

$legacyScripts = @(
    (Join-Path $WindowsRoot 'Codex-Windows-OneClick.ps1'),
    (Join-Path $WindowsRoot 'scripts/installer-core.ps1'),
    (Join-Path $WindowsRoot 'scripts/installer-core-install.ps1')
)
$allowedCommands = @('Write-Warning', 'Write-Host')
$hostExecutable = (Get-Process -Id $PID).Path
foreach ($script in $legacyScripts) {
    $text = Read-Required $script
    foreach ($value in @(
        '已弃用',
        'https://apps.microsoft.com/detail/9PLM9XGG6VKS',
        '暂不镜像官方 Codex 离线安装文件'
    )) {
        Assert-Contains $text $value "legacy entry $script"
    }

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $script,
        [ref] $tokens,
        [ref] $errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parse failed for $script"
    $commands = @($ast.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        },
        $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        Assert-True ($allowedCommands -contains $name) `
            "legacy entry invokes side-effect command '$name': $script"
    }
    $exits = @($ast.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.ExitStatementAst]
        },
        $true))
    Assert-True ($exits.Count -eq 1) "legacy entry must contain one exit: $script"
    Assert-True ($exits[0].Pipeline.Extent.Text.Trim() -ceq '64') `
        "legacy entry does not exit exactly 64: $script"

    $output = & $hostExecutable -NoLogo -NoProfile -File $script `
        -Provider legacy -Silent 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 64) `
        "legacy entry runtime exit was ${exitCode}: $script"
    $outputText = @($output | ForEach-Object { "$_" }) -join "`n"
    Assert-Contains $outputText 'https://apps.microsoft.com/detail/9PLM9XGG6VKS' `
        "legacy runtime output $script"
    Assert-Contains $outputText '暂不镜像官方 Codex 离线安装文件' `
        "legacy runtime output $script"
}

$global:LASTEXITCODE = 0
Write-Host 'DocumentationTests: PASS'
