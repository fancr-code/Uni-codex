# Uni-codex

<div align="center">

**给普通用户准备的 Codex + Codex++ 一键安装器**

不用 Git，不用命令行，不用配置开发环境。下载、双击，跟着提示完成安装。

[![Windows](https://img.shields.io/badge/Windows-下载安装包-0078D4?style=for-the-badge&logo=windows11&logoColor=white)](https://github.com/fancr-code/Uni-codex/releases/download/v1.1.0-online/Uni-codex-Windows-x64-Online-Setup.exe)
[![macOS](https://img.shields.io/badge/macOS-下载安装包-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/fancr-code/Uni-codex/releases/download/v1.1.0-online/Uni-codex-macOS-Online.dmg)

[查看最新版本](https://github.com/fancr-code/Uni-codex/releases/latest) · [问题反馈](https://github.com/fancr-code/Uni-codex/issues)

</div>

## 为什么用 Uni-codex？

官方 Codex 很强，但第一次安装、寻找正确版本、安装 Codex++，对新手并不直观。Uni-codex 把这些步骤放进一个图形化安装包里。

| 自己配置 | 使用 Uni-codex |
| --- | --- |
| 查找适合系统的 Codex 下载来源 | 自动获取对应平台的官方 Codex |
| 手动下载并安装 Codex++ | 安装器统一处理 |
| 分辨 Windows、Apple Silicon、Intel 版本 | 自动识别或提供正确入口 |
| 阅读多份安装说明 | 跟着安装向导操作即可 |
| 容易重复安装或覆盖已有版本 | 优先复用已安装且可用的 Codex |

> Uni-codex 是轻量的**在线安装器**：安装时从官方来源获取最新组件，因此安装包体积小，使用时需要联网。

## 一键安装

### Windows

支持 **Windows 10 1809 及以上版本、Windows 11（x64）**。

1. 下载 [Windows 一键安装包](https://github.com/fancr-code/Uni-codex/releases/download/v1.1.0-online/Uni-codex-Windows-x64-Online-Setup.exe)。
2. 双击 `Uni-codex-Windows-x64-Online-Setup.exe`。
3. 按安装向导提示完成安装。

安装器会通过微软官方渠道获取 Codex，并完成 Codex++ 的安装或集成。

### macOS

支持 **Apple Silicon（M 系列）和 Intel Mac**。

1. 下载 [macOS 一键安装包](https://github.com/fancr-code/Uni-codex/releases/download/v1.1.0-online/Uni-codex-macOS-Online.dmg)。
2. 打开 `Uni-codex-macOS-Online.dmg`。
3. 按窗口中的说明完成安装。

安装器会识别 Mac 的芯片类型，从 OpenAI 官方地址获取适合的 Codex，并安装 Codex++。

## 你会得到什么？

- **Codex 桌面版**：由官方来源下载，不在本仓库重复打包。
- **Codex++**：随引导流程安装，减少手动配置步骤。
- **Codex Dream Skin**：在线版与离线版均提供 v1.5.11、Gothic Void Crusade，以及 10 套从 DreamSkin.cc Gallery 按热度筛选的跨平台精选主题。
- **211 个科研 Skills**：在线版与离线版都预装 Nature Skills、Scientific Agent Skills 和 Research Skills。
- **跨平台支持**：一个项目同时覆盖 Windows 和 macOS。
- **已有安装保护**：检测到健康的 Codex 时优先复用，避免无意义地重复安装或降级。
- **更适合中文用户**：下载入口、安装说明和常见问题集中在同一页面。

## 可选模型与科研生态

Windows 配置工具支持 DeepSeek、Kimi 开放平台、Kimi Code、智谱 GLM、阿里千问和 Xiaomi MiMo 等 API 服务商，并提供相应的官方 API Key 申请入口。

Uni-codex 也可以配合以下工具形成连续科研工作流：

- [Uni-Scholar 云端工作站](https://uni-scholar.asia)：检索、协作与长流程科研任务。
- [Research Kit](https://uni-scholar.asia/research-kit)：连接 Zotero、Obsidian 与本地知识库，目前主要面向 macOS。
- Codex / Codex++：执行代码、文档、数据处理与自动化任务。

这些功能均为可选项。只想安装 Codex 的用户，直接使用上方安装包即可。

### 开箱即用的科研 Skills

安装完成后，Codex 会自动获得三套经过固定版本管理的开源技能合集：

- [Nature Skills](https://github.com/Yuan1z0825/nature-skills)：Nature 风格论文写作、润色、审稿、作图和投稿工作流，共 19 个技能。
- [Scientific Agent Skills](https://github.com/K-Dense-AI/scientific-agent-skills)：覆盖生物、化学、医学、数据分析和科研数据库等场景，共 158 个技能。
- [Research Skills](https://github.com/neuromechanist/research-skills)：研究规划、实验设计、文献与图表处理、工程化研究流程，共 34 个技能。

三套合集合计 **211 个技能**。在线安装包在安装时获取锁定版本；离线安装包在构建时已将同一版本完整打包。安装器会保留用户自己维护的同名技能，不会静默覆盖。
三套合集的 MIT 许可证会随技能一并保留在 `.codex/skills/.uni-codex-licenses/`。

### 预设皮肤

安装界面提供三种选择：`Gothic Void Crusade`、`DreamSkin.cc 主题库（安装时连接 API）`和“官方默认外观”。前两项会预装同一份精选主题目录；选择主题库时，离线安装器也会尝试连接 DreamSkin.cc API 缓存可用主题清单，并自动打开 [DreamSkin.cc Gallery](https://dreamskin.cc/gallery)，可继续浏览、试用和下载 200+ 个社区主题。网络不可用时仍可使用包内主题。

离线包把 10 套精选主题直接放入本地主题库；在线包在安装时从 DreamSkin.cc 固定 API 下载并逐个校验 SHA-256。精选清单、作者、声明许可证和冻结哈希见 [`Resources/dream-skin/catalog.json`](Resources/dream-skin/catalog.json)。主题素材仍受各自作者声明的许可证约束，详见 [第三方许可说明](Resources/licenses/Third-Party-Notices.md)。

Dream Skin 是非 OpenAI 官方项目，采用其上游 MIT 软件许可，且不会修改官方 Codex 安装包本体。

## 常见问题

### 为什么安装包这么小？

因为它是在线安装器，不把体积较大的官方 Codex 应用重复塞进仓库。运行安装器后，才会从 OpenAI、Microsoft 和相关项目的官方地址下载所需组件。

### 安装时必须联网吗？

是。下载 Codex、Codex++，以及刷新上游模型信息都需要网络。

### Release 里的 Source code 是安装包吗？

不是。`Source code (zip)` 和 `Source code (tar.gz)` 是 GitHub 为每个版本标签自动生成的源码快照。普通用户只需下载 `.exe` 或 `.dmg`。

### OpenAI 授权等于 API Key 吗？

不等于。OpenAI 账号授权不会赠送 GPT API 额度，也不会获得账号原本没有的权限。选择第三方 API 服务商时，实际模型调用及费用由相应服务商负责。

### 这是 OpenAI 官方项目吗？

不是。Uni-codex 是社区项目，与 OpenAI 没有隶属关系。Codex 的名称、商标和官方应用归其各自权利人所有。

## 安全与隐私

- Codex 桌面应用只从 OpenAI 或 Microsoft 官方渠道获取。
- Codex++ 从其 GitHub Release 获取，或由安装引导器集成。
- 本仓库不镜像分发官方 Codex 桌面应用、Microsoft Store 包或许可证不明确的脚本源码。
- API Key、OAuth Token、设备码、对话正文等敏感内容不会作为公开构建产物上传。
- 请不要在 Issue、日志、截图或公开配置中提交任何密钥和令牌。

## 给开发者

普通用户不需要阅读本节。项目的在线发布入口是 [`.github/workflows/online-release.yml`](.github/workflows/online-release.yml)，版本标签格式为 `v*-online`。

```text
.
├── macos/                      # macOS 在线安装器
├── windows/                    # Windows 安装器与配置工具
├── scripts/                    # 构建、验证与烟雾测试
├── tests/                      # 自动化测试
├── Resources/                  # macOS 资源
└── .github/workflows/          # CI 与 Release 工作流
```

Windows 的完整构建说明见 [windows/README.md](windows/README.md)。第三方组件和再分发边界见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [LICENSES](LICENSES)。

## 开源许可证

Uni-codex 原创安装器代码采用 [MIT License](LICENSE)。该许可证只适用于本项目拥有版权的原创部分，不会重新授权 Codex、Codex++、插件、脚本、图标或商标；第三方组件继续遵循各自的上游许可证。

---

<div align="center">

如果 Uni-codex 帮你省下了配置时间，欢迎点一个 ⭐，也欢迎通过 [Issue](https://github.com/fancr-code/Uni-codex/issues) 提交建议。

</div>
