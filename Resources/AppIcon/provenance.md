# Codex 一键安装应用图标来源说明

- 设计日期：2026-07-22
- 视觉方案：蓝紫渐变 macOS 圆角方形，中央为白色电源/启动环与终端提示符 `>` 的组合。
- 渲染器：`scripts/generate-app-icon.swift`
- 导出脚本：`scripts/generate-app-icon.sh`
- 主源输出：`Resources/AppIcon/AppIcon-1024.png`
- 标准输出：
  - `Resources/AppIcon/AppIcon.iconset/icon_16x16.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_16x16@2x.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_32x32.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_32x32@2x.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_128x128.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_128x128@2x.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_256x256.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_256x256@2x.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_512x512.png`
  - `Resources/AppIcon/AppIcon.iconset/icon_512x512@2x.png`
  - `Resources/AppIcon/AppIcon.icns`

图标由项目内的 AppKit 矢量绘制代码离线生成，不使用在线服务、外部图像、字体、商标素材或下载内容。图形不包含文字、OpenAI 结形标志或其他产品商标的仿制几何。

在 `codex-one-click-installer` 项目目录执行以下命令即可重新生成全部资产：

```bash
bash scripts/generate-app-icon.sh
```
