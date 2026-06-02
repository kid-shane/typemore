# Typemore

Type more，让表达更丰富。

Typemore 是一个轻量级 macOS 状态栏写作助手。你可以在任意应用中选中文字，或直接把光标停在正在输入的段落里，双击右 `Option` 触发改写；Typemore 会用一个极简胶囊状态提示完成处理，并把结果直接替换回原位置。

它适合经常在聊天、文档、邮件、浏览器、编辑器等不同应用里写作的人：不需要复制到网页、不需要切换上下文，只在原地完成润色。

## 功能特性

- 支持在几乎任意 macOS 应用中改写选中文本。
- 支持无选区时修正光标附近的当前段落，并用前 500 字、后 300 字作为上下文参考。
- 通过右 `Option` 双击触发，适合高频快速修正。
- 改写过程中显示一个紧凑的内联胶囊状态。
- 改写完成后只替换目标文本，不改动上下文。
- 支持从胶囊里快速撤回上一次替换。
- 使用你自己的模型服务和 API Key 完成改写。
- 支持火山方舟、OpenAI、OpenAI Compatible 等 Chat Completions 服务。
- 设置保存在本机，不依赖 Typemore 自建后端。

## 工作方式

Typemore 采用“选区优先，光标兜底”的流程：

1. 在任意 macOS 应用中选中一段文字，或把光标停在要修正的段落附近。
2. 双击右 `Option`。
3. 如果有选中文本，Typemore 只改写选区，并把前后文作为参考。
4. 如果没有选中文本，Typemore 会读取光标附近内容，优先修正当前段落。
5. Typemore 将目标文本和上下文发送给你配置的模型服务。
6. Typemore 把改写后的结果粘贴回原应用，只替换目标文本。
7. Typemore 会短暂显示“撤回”操作，方便你快速还原。

这个方案减少了手动全选/选中成本，同时尽量避免自动监听输入带来的不可控修改。

## 环境要求

- macOS 13 或更高版本。
- Xcode Command Line Tools，包含 Swift 编译工具链。
- 为 Typemore 开启 macOS 辅助功能和输入监控权限。
- 一个可用的模型服务 API Key。Typemore 本身不提供模型服务，改写能力依赖你在设置中配置的模型。

Typemore 当前只支持 macOS。它使用 Swift、AppKit、SwiftUI、CGEventTap、Accessibility API、系统剪贴板和状态栏 API 实现。

## 下载安装

如果你不想自己编译，可以直接从 [GitHub Releases](https://github.com/kid-shane/typemore/releases) 下载安装包：

1. 下载 `Typemore-<版本>-universal.dmg`（同时支持 Apple Silicon 和 Intel）。
2. 打开 DMG，把 `Typemore.app` 拖到 `Applications`。
3. 首次打开时右键 `Typemore.app` 选择「打开」，绕过 Gatekeeper（当前为 ad-hoc 签名，未做公证）。
4. 在系统设置里为 Typemore 开启「辅助功能」和「输入监控」权限。

## 快速开始

```bash
./scripts/run-in-terminal.sh
```

这个脚本会自动打开 macOS Terminal，并在 Terminal 里运行 `swift run --disable-sandbox`。这样辅助功能权限只需要给 Terminal 和 Typemore，避免 IDE sandbox 影响复制、粘贴和撤回。

启动后，在 macOS 状态栏中点击 `T+`，选择 `Settings`，然后配置你的模型服务。没有可用的模型服务和 API Key 时，Typemore 无法完成真实改写。

## 模型配置

Typemore 默认提供火山方舟预设：

- 服务：`火山方舟`
- Endpoint: `https://ark.cn-beijing.volces.com/api/coding/v3`
- Model: `deepseek-v4-pro`

你需要填写自己的 API Key 才能正常使用改写能力。

Typemore 也支持：

- `OpenAI`
- `OpenAI Compatible`
- `Demo`，仅用于开发和界面验证，不适合作为实际改写模式

API Key 会保存在本机 macOS 应用支持目录中，不会提交到这个代码仓库。

## macOS 权限

Typemore 需要监听右 `Option` 双击，并代你发送复制、粘贴、撤回等快捷键。macOS 会要求你开启输入监控和辅助功能权限。

如果改写失败，并提示权限相关问题，可以按下面步骤处理：

1. 打开 `系统设置`。
2. 进入 `隐私与安全性`。
3. 打开 `辅助功能`，为 `Typemore` 开启权限。
4. 打开 `输入监控`，为 `Typemore` 开启权限。
5. 开发运行时如果通过 Terminal 启动，也需要为 Terminal 开启辅助功能权限。
6. 重启 Typemore。

## 本地开发

```bash
./scripts/run-in-terminal.sh
```

也可以在 Finder 中双击根目录的 `run.command`。

构建验证：

```bash
swift build --disable-sandbox
```

本地打包：

```bash
scripts/package-local-app.sh
```

脚本会生成：

- `dist/Typemore.app`
- `dist/Typemore-local.zip`
- `dist/Typemore-local.dmg`

测试用户可以打开 `Typemore-local.dmg`，把 `Typemore.app` 拖到 `Applications`。首次打开时，需要右键 `Typemore.app` 选择 `打开`，并在系统设置里为 `Typemore` 开启辅助功能和输入监控权限。

两三百字改写耗时测试：

```bash
scripts/benchmark-rewrite.py --repeat 3
```

脚本会读取 Typemore 本地模型配置，也可以用 `TYPEMORE_BASE_URL`、`TYPEMORE_MODEL`、`TYPEMORE_API_KEY` 临时覆盖。

项目结构：

- `Package.swift`：Swift Package 配置。
- `Sources/Typemore/TypemoreApp.swift`：AppKit 应用入口、状态栏、触发器和主流程编排。
- `Sources/Typemore/RightOptionDoubleTapTrigger.swift`：右 `Option` 双击触发监听。
- `Sources/Typemore/SystemTextService.swift`：目标文本捕获、上下文读取、粘贴替换、撤回和辅助功能入口。
- `Sources/Typemore/RewriteService.swift`：模型服务调用、上下文改写请求和 Demo 改写。
- `Sources/Typemore/CapsuleController.swift`：原生胶囊浮窗和 loading 动效。
- `Sources/Typemore/SettingsWindow.swift`：SwiftUI 设置窗口。
- `Sources/Typemore/Settings.swift`：设置模型、本地读写和默认配置。
- `docs/`：产品笔记和隐私说明。

## 打包发布

当前仓库优先支持源码方式本地运行。后续计划提供可直接安装的 macOS 构建产物。

推荐的发布路线：

- 使用 Xcode 或 SwiftPM 生成 macOS `.app`。
- 生成 `.dmg` 和 `.zip` 安装包。
- 通过 GitHub Releases 发布构建产物。
- 增加 macOS 代码签名和 notarization，降低安装时的系统拦截。
- 可选：发布 Homebrew Cask。

## 隐私说明

Typemore 会处理你主动触发改写的文本。每次触发时，目标文本和必要的前后文会发送给你在设置中配置的模型服务；上下文只用于理解语义，替换时只改动目标文本。

Typemore 优先通过 macOS Accessibility API 读取和替换文本。部分应用不稳定时，Typemore 会临时使用系统剪贴板完成复制或粘贴，并在操作结束后恢复原剪贴板。若你使用第三方剪贴板管理器，中间内容可能被该管理器记录。请避免在敏感输入框中触发 Typemore。

Typemore 不包含自建后端，不收集 analytics，也不会把你的 API Key 上传到这个仓库。

完整隐私说明见 [docs/privacy.md](docs/privacy.md)。

## Roadmap

- 签名并 notarize 的 macOS 安装包。
- GitHub Releases 自动发布构建产物。
- 更多模型服务预设。
- 更好的首次启动和辅助功能权限引导。
- 可选的流式改写反馈。
- 可配置触发键和多套写作风格。

## 参与贡献

欢迎提交 Issue 和 Pull Request。请尽量保持改动聚焦、实用，并符合 Typemore 的核心原则：不离开正在输入的地方，也能快速获得写作辅助。

## 开源协议

MIT。详见 [LICENSE](LICENSE)。
