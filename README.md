# Codex 一键安装生态

本仓库提供 macOS 与 Windows 的 Codex/Codex++ 部署工具，并连接 Uni-Scholar 科研生态。

## 生态优势：连续科研工作流

- [Uni-Scholar 云端工作站](https://uni-scholar.asia)：云端检索、协作与长流程科研任务。
- [Research Kit 本地中枢](https://uni-scholar.asia/research-kit)：连接 Zotero、Obsidian 与本地知识库。
- Codex/Codex++ 执行层：完成代码、文档、数据处理与自动化。

三层共同构成从知识沉淀、研究推理到执行交付的连续科研工作流。Research Kit 当前为 macOS 生态产品；Windows 用户可把它作为生态链接和可选配套，但它不随 Windows 安装包预装。

## 公开仓库状态

本仓库公开的是 Uni-codex 源码，不公开镜像分发官方 Codex 桌面应用、Microsoft Store
包或未声明许可证的脚本市场源码。请先从
[Microsoft Store 官方页面](https://apps.microsoft.com/detail/9PLM9XGG6VKS)
安装 Codex；Uni-codex 会复用健康的现有安装。

包含官方 Codex 桌面安装文件的完整离线 Release，只有在取得书面再分发授权后才会发布。
最低系统仍为 Windows 10 版本 1809（Build 17763），仅支持 x64。

完整说明见 [Windows 文档](windows/README.md)。

## Windows 能力

默认纯 API，支持 DeepSeek、Kimi 开放平台、Kimi Code、智谱 GLM、阿里千问、Xiaomi MiMo。安装器内提供各服务商官方 API Key 申请入口，并优先刷新上游模型；断网或刷新失败时回退到随包校验的离线快照，Kimi 开放平台快照包含 Kimi K3。

推荐“OpenAI 账号 + 所选国产 API”：可在安装器内点击“获取 OpenAI 授权”，但实际模型调用仍由所选服务商完成。OpenAI 授权不等于 GPT API Key，不赠送 GPT API 额度，也不会获得账号未拥有的权限。

安装器会复用健康 Codex，不重复安装或降级。Codex++ 带有 `cross-provider-content-v1`；同时配置 3 个插件市场和 9 个插件。用户可从作者的上游地址直接获取 `Context Used Meter` 与 `Codex Token Usage`；本公开仓库不镜像这些未声明许可证的脚本源码。API Key、OAuth Token、设备码、对话正文与敏感报告字段都会被排除或脱敏。

## macOS

macOS 安装器支持 Apple Silicon 与 Intel。构建入口：

```bash
bash build-codex-one-click-installer.sh
```

macOS 同样默认使用所选 API 服务商，可选 OpenAI 账号授权，并复用健康应用。具体构建、签名、硬件烟测和分发边界以仓库内 macOS 脚本及安装包引导为准。

### 开发构建与测试

```bash
# macOS 构建与测试
bash build-codex-one-click-installer.sh
bash tests/run-all-tests.sh
```

```powershell
# Windows 开发构建与测试（从仓库根目录，在 Windows x64）
# 前置：.NET 8 SDK、Node.js 22、Rust stable、NSIS、Inno Setup 7.0.2，
# 并确保 dotnet、node、cargo、makensis、ISCC.exe 均在 PATH。
# StorePackageResolver 会按 ProductId 从微软 DisplayCatalog/FE3 解析当前官方 MSIX；
# 构建不会信任会变化为联网引导 EXE 的 get.microsoft.com 下载响应。
dotnet restore windows/CodexOneClickInstaller.sln --locked-mode
$compat = 'windows/build/codex-plus-compat'
pwsh windows/scripts/build-codex-plus-compatibility-payload.ps1 `
  -Tag v1.2.43 `
  -Patch patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch `
  -OutputRoot $compat

pwsh windows/scripts/refresh-offline-payloads.ps1 `
  -OutputRoot windows/vendor/offline-payloads `
  -CodexPlusPlusSetup "$compat/CodexPlusPlus-1.2.43-codexkit.1-windows-x64-setup.exe" `
  -CodexPlusPlusSource "$compat/CodexPlusPlus-v1.2.43-codexkit.1-source.tar.gz"

. windows/scripts/offline-payload-supply.ps1
$active = Resolve-ActivePayloadRoot (
  [IO.Path]::GetFullPath('windows/vendor/offline-payloads'))
$iscc = (Get-Command ISCC.exe -ErrorAction Stop).Source

pwsh windows/tests/run-all-tests.ps1 `
  -PayloadRoot $active `
  -BuiltRoot $compat `
  -TestResultsRoot windows/test-results/full
pwsh windows/scripts/build-installer.ps1 `
  -PayloadRoot $active -OutputDir dist -IsccPath $iscc
```

### 项目结构

```text
.
├── README.md
├── Resources/                  # macOS 资源与安装包指南
├── scripts/                    # macOS 构建、验证与烟测
├── tests/                      # macOS 测试
├── windows/
│   ├── README.md
│   ├── installer/              # Inno Setup 外层安装器
│   ├── src/                    # WPF GUI 与 InstallerCore
│   ├── scripts/                # Windows 构建与载荷工具
│   ├── tests/                  # Windows 契约与运行时测试
│   └── docs/guides/            # Windows 随包指南
└── .github/workflows/          # Windows CI 与正式发布工作流
```

## 安全边界

- 只从明确的官方服务商页面或已取得再分发授权的项目 Release 获取文件与凭据。
- API Key、OAuth Token、设备码不应进入日志、报告、截图或公开配置。
- 模型调用、OpenAI 授权和上游模型刷新需要网络，并受所选服务商与账号权限约束。
- 本项目不是 OpenAI 产品；公开分发前应核对适用的许可、商标与再分发条款。

## 开源许可证

Uni-codex 原创安装器代码采用 [MIT License](LICENSE)。MIT 仅适用于本项目拥有
版权的原创部分，不会重新授权 Codex、Codex++、插件、脚本、图标或商标。

- OpenAI Codex CLI：Apache-2.0。
- Codex++ 及其兼容补丁：AGPL-3.0-only。
- 其他组件：保持各自上游许可证；未声明许可证的内容不由本仓库镜像分发。

完整边界见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和
[`LICENSES/`](LICENSES/)。
