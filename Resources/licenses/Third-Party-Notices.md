# 第三方许可与来源说明

“Codex 一键安装”是独立社区安装工具，不是 OpenAI 产品，也未获得 OpenAI 对本安装器的背书。仓库根 MIT License 只覆盖 Uni-codex 原创代码，第三方组件保持各自条款。

## OpenAI 官方 Codex macOS 应用

来源锁定在 `upstream-sources.json` 的 OpenAI 官方下载地址。OpenAI 应用的权利、商标和使用条件归其权利人所有。本公开源码仓库不镜像该应用，也不主张授予其再分发权；公开发布包含该应用的镜像前，发布者必须取得书面授权。

## Codex++

项目：BigPizzaV3/CodexPlusPlus

来源：https://github.com/BigPizzaV3/CodexPlusPlus

上游版本：v1.2.44。安装包使用 `codexkit.1` / `cross-provider-content-v1` 下游兼容修订，修复 DeepSeek/Kimi 与 OpenAI 模型之间切换时旧历史消息 `content` 类型不兼容的问题。

许可证：AGPL-3.0-only。DMG 的“第三方许可与源码”目录同时包含与二进制版本一致的完整修订源码归档、`CODEXKIT-PATCH.md`、可单独审计的补丁文件和许可证文本。

## Codex 插件

安装器管理以下插件；各平台实际离线携带的范围见下文，具体版本、来源和插件自行声明的许可证会在构建时追加到最终说明：

- `browser@openai-bundled`
- `chrome@openai-bundled`
- `computer-use@openai-bundled`
- `latex@openai-bundled`
- `pdf@openai-primary-runtime`
- `documents@openai-primary-runtime`
- `spreadsheets@openai-primary-runtime`
- `presentations@openai-primary-runtime`
- `github@openai-curated`

当前 Windows Store MSIX 只随包提供 `openai-bundled`。Windows 安装包离线
复制其中 4 个插件；`github` 从公开仓库
https://github.com/openai/plugins 的固定提交
`11c74d6ba24d3a6d48f54a194cd00ef3beea18f9` 取得，插件版本 `0.1.6`，
目录哈希、文件数、总大小与清单许可声明由
`windows/vendor/plugin-seed-lock.json` 锁定。该插件清单声明 MIT，内部技能
随附的许可证文本保持原样；安装包另附一份清单所声明 MIT License 的完整文本。

Windows 安装包不复制或再分发 `openai-primary-runtime` 的
`documents`、`pdf`、`spreadsheets`、`presentations` 内容；只预先启用这些
插件条目，由 Codex 在联网且账号/运行时具备权限时在线供应。断网或未获相应
权限时，这 4 个插件保持等待状态。

## Codex++ 脚本市场

索引来源：https://github.com/BigPizzaV3/CodexPlusPlusScriptMarket 。当前索引和脚本没有明确的开源许可证声明，因此公开仓库不镜像脚本源码。用户可以选择从作者的固定上游地址直接获取；未取得许可前不得发布包含这些脚本的离线镜像。

## Microsoft Store 包解析器

Windows 构建期工具 `StorePackageResolver` 改编自
https://github.com/Wangnov/codex-app-mirror 的 Store 链接解析实现（固定参考提交
`62b99b9c2872bbb0979a8dab192a37a639ae6465`），按 MIT License 使用。完整许可文本位于
`windows/tools/StorePackageResolver/LICENSE.codex-app-mirror.txt`。该工具只参与构建，不随最终安装器运行。
