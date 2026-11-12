# Typemore

Type more，让表达更丰富。

Typemore 是一个轻量级 macOS 写作助手。你可以在任意应用中选中文字，或直接把光标停在正在输入的段落里，双击右 `Option` 触发改写；Typemore 会显示简洁的底部状态提示，并把结果直接替换回原位置。应用运行时常驻 Dock，点击图标即可打开设置。

它适合经常在聊天、文档、邮件、浏览器、编辑器等不同应用里写作的人：不需要复制到网页、不需要切换上下文，只在原地完成润色。

## 功能特性

- 支持在几乎任意 macOS 应用中改写选中文本。
- 支持无选区时读取并修正完整当前段落，附带少量前后文作为参考。
- 通过右 `Option` 双击触发，适合高频快速修正。
- 支持在设置中录制自定义组合键，保存后立即生效。
- 支持用纯文本自定义改写规则，不限于润色，也可以转换语言、调整格式或按规则添加颜文字。
- 设置分为通用、写作风格、模型服务和权限，支持系统深浅色外观。
- 改写过程中显示一个紧凑的内联胶囊状态。
- 读取或润色时可点击胶囊右侧的 × 停止任务，保留原文；取消后可再次触发。
- 长文本自动分段，限制每次请求的上下文大小；显示进度，校验完成后一次替换全文。
- 对分段截断、临时断连和关键字面内容遗漏进行重试；持续失败时保留原文并提示错误。
- 改写完成后只替换目标文本，不改动上下文。
- 支持从胶囊里快速撤回上一次替换。
- 支持使用 ChatGPT 账号、连接官方豆包 CLI，或配置自己的模型服务 API Key。
- 提供主流服务商预设、可用模型列表和真实连接试用；支持保存、切换和移除多份连接。
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

误触时，点击「读取中 / 润色中」右侧的 × 即可停止。结果开始写回后，使用完成胶囊中的「撤回」还原。

这个方案减少了手动全选/选中成本，同时尽量避免自动监听输入带来的不可控修改。

## 用纯文本定义你的规则

「我的文风」是一个开放的纯文本规则入口，不必局限于日常润色。在设置的「写作风格」页选择「我的文风」，写下希望如何处理文字，保存后就会在下一次触发时使用。你可以要求把口语转换成规范英文，或按明确规则添加颜文字；原意、事实和关键条件仍需保留。

下面两条规则可以分别复制使用：

**口语转规范英文**

```text
把我输入的口语整理成自然、规范的英文。保留原意、事实、语气强弱和条件，不补充信息；只返回英文正文。
```

**每句话都加颜文字**

```text
保留原意，用自然的中文表达。在每个句子的句末加一个颜文字，例如 (^▽^) 或 (≧▽≦)，不要新增事实；只返回处理后的正文。
```

规则由你配置的模型执行，具体结果会随模型和输入而变化。

## 环境要求

- macOS 13 或更高版本。
- 从源码编译时需要 Xcode Command Line Tools，安装构建包可直接运行。
- 为 Typemore 开启 macOS 辅助功能和输入监控权限。
- 模型连接可选择符合资格的 ChatGPT 账号、已登录的官方豆包 CLI、自备 API Key 或本机 Ollama 服务。

Typemore 当前只支持 macOS。它使用 Swift、AppKit、SwiftUI、CGEventTap、Accessibility API、系统剪贴板和 Dock 实现。

## 下载安装

如果你不想自己编译，可以直接从 [GitHub Releases](https://github.com/kid-shane/typemore/releases) 下载安装包：

1. 下载 `Typemore-<版本>-universal.dmg`（同时支持 Apple Silicon 和 Intel）。
2. 打开 DMG，把 `Typemore.app` 拖到 `Applications`。
3. 双击 `Typemore.app` 启动。v0.1.8 的正式安装包已完成 Developer ID 签名和 Apple 公证。
4. 在系统设置里为 Typemore 开启「辅助功能」和「输入监控」权限。

## 快速开始

```bash
./scripts/run-in-terminal.sh
```

这个脚本会自动打开 macOS Terminal，并在 Terminal 里运行 `swift run --disable-sandbox`。这样辅助功能权限只需要给 Terminal 和 Typemore，避免 IDE sandbox 影响复制、粘贴和撤回。

启动后，点击 Dock 中的 Typemore 图标打开设置，在「模型服务」页添加和配置模型连接。关闭窗口后应用继续运行，`⌘,` 也可打开设置。

设置修改后点击「保存」或按 `⌘S`；「取消」放弃未保存修改。「恢复默认」重置配置草稿，保留已有 API Key，点击保存后生效。

## 模型配置

在「模型服务」点击当前的服务名称，再选择「添加连接」。每个连接分别保存名称、模型与凭据，之后可从同一入口切换。

- **ChatGPT 账号登录**：点击「连接 ChatGPT」，在官方浏览器页面登录并授权使用套餐。应用会获取该账号可用的模型供你选择，具体额度和授权可在 ChatGPT 用量设置中管理。
- **豆包**：自动检测本机官方 `@bytedance/doubao-cli`，支持检测连接与扫码登录。用户单独安装 CLI；当前官方 macOS CLI 支持 Apple Silicon。留空模型名称时使用豆包默认模型。
- **API Key**：提供火山方舟、DeepSeek、阿里云百炼、Kimi、OpenAI API、Gemini、Claude、OpenRouter 与自定义兼容服务预设。新连接留空模型，粘贴 Key 后获取列表并选择，也可手动填写。OpenAI API 使用开发者 API Key，按 API 平台的额度与计费规则使用。服务地址放在高级设置中，自定义服务可直接填写地址。
- **本地模型**：连接 Ollama，默认地址 `http://localhost:11434/v1`。本机未启用认证时无需填写 API Key。

展开「测试连接」并点击「试用改写」会真实调用当前连接，返回改写结果和耗时；可随时停止。应用根据服务商接口传递思考参数；API 支持情况及模型额度以所连接的服务为准。

设置完成后点击「保存」或按 `⌘S`。凭据写入钥匙串失败时会明确提示，配置保留为未保存草稿。旧配置中的文风、快捷键和模型选择会保留，旧的自备 Key 连接迁移为一份独立连接。

API Key 与 ChatGPT OAuth 凭据保存在本机 macOS Keychain；模型地址、连接名称和文风保存在 `Application Support/Typemore/Public`。首次启动会读取旧配置，之后独立保存。豆包登录与任务记录由豆包 CLI 管理。安装包不携带用户的账号或凭据。

相关官方文档：[ChatGPT 账号接入](https://developers.openai.com/siwc/token-sharing-open-source)、[豆包 CLI](https://www.npmjs.com/package/@bytedance/doubao-cli)、[方舟 API](https://docs.volcengine.com/docs/ark/chat-api?lang=zh)。

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

本地脚本默认使用 ad-hoc 签名，便于开发验证。对外分发请使用 Developer ID 签名和 Apple 公证；正式下载包的辅助功能和输入监控权限需要在系统设置中开启。

两三百字改写耗时测试：

```bash
scripts/benchmark-rewrite.py --repeat 3
```

脚本会读取 Typemore 本地模型配置，也可以用 `TYPEMORE_BASE_URL`、`TYPEMORE_MODEL`、`TYPEMORE_API_KEY` 临时覆盖。

项目结构：

- `Package.swift`：Swift Package 配置。
- `Sources/Typemore/TypemoreApp.swift`：AppKit 应用入口、Dock 菜单、触发器和主流程编排。
- `Sources/Typemore/RightOptionDoubleTapTrigger.swift`：右 `Option` 双击触发监听。
- `Sources/Typemore/SystemTextService.swift`：目标文本捕获、上下文读取、粘贴替换、撤回和辅助功能入口。
- `Sources/Typemore/RewriteService.swift`：模型服务调用、上下文改写请求和 Demo 改写。
- `Sources/Typemore/CapsuleController.swift`：原生胶囊浮窗和 loading 动效。
- `Sources/Typemore/SettingsWindow.swift`：SwiftUI 设置窗口。
- `Sources/Typemore/Settings.swift`：设置模型、本地读写和默认配置。
- `docs/`：产品笔记和隐私说明。

## 打包发布

GitHub Releases 提供经过 Developer ID 签名和 Apple 公证的通用安装包。发布者使用 macOS 钥匙串中保存的证书与公证凭据运行：

```bash
UNIVERSAL=1 VERSION=0.1.8 BUILD_NUMBER=2026111204 \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 NOTARY_PROFILE="your-notary-profile" \
bash scripts/package-local-app.sh
```

发布前验证签名、公证票据及安装包内容，再上传 DMG 和 ZIP。证书、API Key、OAuth 令牌、本机配置和本地预览输出均不纳入仓库。GitHub Actions 负责测试和通用构建检查，发行附件由发布者上传已公证的构建产物。

## 隐私说明

Typemore 会处理你主动触发改写的文本。每次触发时，目标文本和必要的前后文会发送给你在设置中配置的模型服务；上下文只用于理解语义，替换时只改动目标文本。

Typemore 优先通过 macOS Accessibility API 读取和替换文本。部分应用不稳定时，Typemore 会临时使用系统剪贴板完成复制或粘贴，并在操作结束后恢复原剪贴板。若你使用第三方剪贴板管理器，中间内容可能被该管理器记录。请避免在敏感输入框中触发 Typemore。

Typemore 不包含自建后端，不收集 analytics，也不会把你的 API Key 上传到这个仓库。

完整隐私说明见 [docs/privacy.md](docs/privacy.md)。

## Roadmap

- 更好的首次启动和辅助功能权限引导。
- 更清楚的模型服务配置与错误提示。
- 更多写作偏好与常用输入场景支持。

## 参与贡献

欢迎提交 Issue 和 Pull Request。请尽量保持改动聚焦、实用，并符合 Typemore 的核心原则：不离开正在输入的地方，也能快速获得写作辅助。

## 开源协议

MIT。详见 [LICENSE](LICENSE)。
