# Codex Windows 离线安装器

Codex + Codex++ 的正式 Windows x64 离线安装方案。默认使用纯 API 模式；OpenAI 账号授权是可选增强项。

## 公开源码与安装方式

公开仓库暂不提供包含官方 Codex 桌面 MSIX 的离线 Release。请先从
[Microsoft Store 官方页面](https://apps.microsoft.com/detail/9PLM9XGG6VKS)
安装 Codex，再使用源码构建的 Uni-codex；安装器会复用健康的现有 Codex。

只有取得官方 Codex 桌面包的书面再分发授权后，项目才会重新发布完整离线 EXE。
本项目不提供 PowerShell 一键下载或第三方镜像安装。

系统最低要求：Windows 10 版本 1809（Build 17763）或更高版本，x64 架构。

自行构建安装器后，在文件所在目录核对 SHA-256：

```powershell
Get-FileHash .\Codex-One-Click-Windows-x64-Offline-Setup.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

只有哈希与 `SHA256SUMS.txt` 完全一致时才继续。当前安装器为 unsigned；Windows 可能显示 SmartScreen。哈希匹配只能证明文件与该 Release 一致，不能替代发布者身份签名或消除运行未知软件的风险。若来源或哈希不可信，请取消运行。

## API 与 OpenAI 授权

默认模式是纯 API，支持以下六类服务商。安装器内“申请 API Key”按钮打开服务商官方页面：

| 服务商 | 官方申请入口 |
|---|---|
| DeepSeek | https://platform.deepseek.com/api_keys |
| Kimi 开放平台 | https://platform.moonshot.cn/console/api-keys |
| Kimi Code | https://www.kimi.com/code/console |
| 智谱 GLM | https://bigmodel.cn/usercenter/apikeys |
| 阿里千问 | https://bailian.console.aliyun.com/cn-beijing?tab=model |
| Xiaomi MiMo | https://platform.xiaomimimo.com/ |

Kimi 开放平台的离线快照包含 Kimi K3。安装器优先通过所选服务商的官方模型接口刷新上游模型列表；断网或刷新失败时使用随包校验的离线模型快照。实际模型调用、账号授权和上游模型刷新均需要网络，并由所选服务商按其规则计费。

推荐模式是“OpenAI 账号 + 所选国产 API”：在安装器内点击“获取 OpenAI 授权”，完成浏览器或设备码流程，同时仍由所选国产 API 执行模型调用。OpenAI 授权不等于 GPT API Key，不赠送 GPT API 额度，也不会授予账号原本没有的模型、插件或组织权限。

API Key、OAuth Token 与设备码不会写入安装报告；界面日志和报告会脱敏。请不要把包含密钥的截图或配置文件公开。

## 安装内容与增量行为

- 检测到健康的 Codex 时直接复用，不重复安装、不降级。
- Codex++ 使用 `cross-provider-content-v1` 兼容修订，在跨服务商切换时规范化历史内容；正文不进入转换日志。
- 预配置 3 个市场和 9 个插件；离线实装 2 个市场的 5 个可再分发插件（官方随包 4 个 + 公开仓库 GitHub 插件）。
- `documents`、`pdf`、`spreadsheets`、`presentations` 由 Codex 官方运行时在联网且权限满足时供应；安装器不会把受限运行时内容伪装成离线插件。
- 默认启用 `Context Used Meter` 与 `Codex Token Usage`，可在脚本市场关闭。
- 安装失败或取消时按事务报告回滚；报告不包含 API Key、OAuth Token、设备码或对话正文。

## 连续科研工作流：生态优势

本安装器是 Uni-Scholar 生态的 Windows 执行层入口：

1. [Uni-Scholar 云端工作站](https://uni-scholar.asia)承接云端检索、协作与长流程科研任务。
2. [Research Kit 本地中枢](https://uni-scholar.asia/research-kit)连接 Zotero、Obsidian 与本地知识库。
3. Codex/Codex++ 执行层完成代码、文档、数据与自动化操作。

三层组合形成从资料沉淀、研究推理到执行交付的连续科研工作流。Research Kit 当前是 macOS 生态链接与可选配套，**不随 Windows 安装包预装**。

## 使用步骤

1. 核对系统版本、x64 架构与 SHA-256。
2. 双击 `Codex-One-Click-Windows-x64-Offline-Setup.exe`。
3. 选择服务商、模型与认证模式；按需打开官方 API Key 申请页。
4. 检查完成页中的应用、3 个已配置市场/9 个已配置插件、5 个离线插件、4 个运行时待供应插件、完整脚本市场和监控状态。
5. 妥善保存脱敏安装报告；密钥只在受信任的本机界面输入。

更适合新手的说明见 [Beginner-Guide.zh-CN.html](docs/guides/Beginner-Guide.zh-CN.html)，纯文本入口见 [Open-Guide.zh-CN.txt](docs/guides/Open-Guide.zh-CN.txt)。

## 开发者构建

从新 checkout 开始，在 `windows` 目录运行。前置安装 .NET 8 SDK、Node.js 22、
Rust stable、NSIS 与 Inno Setup 7.0.2，并确保 `dotnet`、`node`、`cargo`、
`makensis`、`ISCC.exe` 均可从 PATH 发现：

```powershell
# tools/StorePackageResolver 会从微软 DisplayCatalog/FE3 解析并校验当前官方 x64 MSIX。
dotnet restore .\CodexOneClickInstaller.sln --locked-mode
$compat = '.\build\codex-plus-compat'
.\scripts\build-codex-plus-compatibility-payload.ps1 `
  -Tag v1.2.44 `
  -Patch ..\patches\CodexPlusPlus\v1.2.44-cross-provider-history.patch `
  -OutputRoot $compat

.\scripts\refresh-offline-payloads.ps1 `
  -OutputRoot .\vendor\offline-payloads `
  -CodexPlusPlusSetup "$compat\CodexPlusPlus-1.2.44-codexkit.1-windows-x64-setup.exe" `
  -CodexPlusPlusSource "$compat\CodexPlusPlus-v1.2.44-codexkit.1-source.tar.gz"

. .\scripts\offline-payload-supply.ps1
$active = Resolve-ActivePayloadRoot (
  [IO.Path]::GetFullPath('.\vendor\offline-payloads'))
$iscc = (Get-Command ISCC.exe -ErrorAction Stop).Source

.\tests\run-all-tests.ps1 `
  -PayloadRoot $active `
  -BuiltRoot $compat `
  -TestResultsRoot .\test-results\full
.\scripts\build-installer.ps1 `
  -PayloadRoot $active -OutputDir dist -IsccPath $iscc
```

正式输出是 `Codex-One-Click-Windows-x64-Offline-Setup.exe`。旧的 `Codex-Windows-OneClick.ps1`、`scripts/installer-core.ps1` 与 `scripts/installer-core-install.ps1` 仅保留弃用提示，固定退出 64，不再下载或安装。
