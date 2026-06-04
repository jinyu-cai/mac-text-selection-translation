# Text Selection Translation (MacTranslator)

一个简约的 macOS 划词翻译工具：选中任意文字 → 弹出 AI 翻译。常驻菜单栏，无 Dock 图标，安装包仅一个原生可执行文件（运行时内存约 ~25MB）。

翻译走 **OpenAI 兼容接口**，因此可以接入任何兼容 `/chat/completions` 的服务：OpenAI、Azure OpenAI、DeepSeek、Moonshot/Kimi、智谱、SiliconFlow、Ollama、LM Studio、OpenRouter、One-API 中转……只要填上对应的 Base URL / API Key / 模型名即可。

## 功能

- **两种触发方式**（可在设置里各自开关）：
  - 全局快捷键（默认 `⌥D`）：选中文字后按快捷键弹出翻译。
  - 选中浮标：拖选或双击文字后，旁边浮出一个小按钮，点它翻译。
- **流式输出**：译文逐字显示。
- **自动语向**：默认翻译成中文；如果原文已经是中文，则翻译成英文（目标语言可改）。
- **自定义提示词**：可用自己的 system prompt 完全覆盖默认翻译指令。
- **取词后恢复剪贴板**：默认开启，不污染你的剪贴板。
- **浮窗可拖动**：按住浮窗空白处（或顶部「翻译」标题栏）即可拖到任意位置；翻译流式增长时也会保持在你放的位置。
- 译文可一键复制 / 选中复制；`Esc` 或点击别处关闭浮窗。

## 构建与运行

需要 Xcode（命令行工具）/ Swift 6 工具链。

```bash
# 一次性：创建本地自签名证书，让「辅助功能」授权只需做一次（见下方「授权」）
./scripts/create-signing-cert.sh

make run      # 编译 + 打包成 .app + 启动
# 或分步：
make build    # 仅编译
make app      # 打包出「Text Selection Translation.app」
make clean
```

也可以直接 `open "Text Selection Translation.app"`，或拖到「应用程序」里。

> 签名身份：`make app` 会自动使用上面创建的 `MacTranslator Dev` 证书（找不到则退回 ad-hoc `-`）；也可手动指定 `make app SIGN_ID="Your Identity"`。

## 授权（重要）

划词取词靠模拟 `⌘C` 实现，需要 **辅助功能** 权限：

1. 首次启动会弹出授权提示；或打开 **系统设置 → 隐私与安全性 → 辅助功能**。
2. 把「Text Selection Translation」加进列表并打开开关。
3. **重新启动 App**（授权后必须重启进程才生效）。

> 只要用 `MacTranslator Dev` 证书签名（默认即是），授权**一次**就够了——之后 `make app` 重新打包也不会掉权限，因为签名的「指定要求」基于证书而非每次都变的代码哈希。
> 若改回 ad-hoc 签名（`-`），则每次重新打包后都要重新授权。
> 改过名/换过签名方式后，记得先在列表里**删掉旧的残留条目**再重新授权。

## 配置

点菜单栏图标 → **设置…**：

| 项 | 说明 |
| --- | --- |
| Base URL | 接口前缀，会自动拼上 `/chat/completions`。如 `https://api.openai.com/v1`、`http://localhost:11434/v1`（Ollama） |
| API Key | `Bearer` 鉴权；本地服务可留空 |
| 模型 | 如 `gpt-4o-mini`、`deepseek-chat`、`qwen2.5:7b` |
| 目标语言 | 默认「中文」 |
| 自定义提示词 | 留空用内置提示；填了则完全覆盖 |
| 快捷键 | 点一下开始录制，按下组合键即可 |

「测试连接」按钮会发一次最小请求校验 Base URL / Key / 模型是否可用。

## 项目结构

```
Sources/MacTranslator/
├─ App.swift              入口：菜单栏 (MenuBarExtra) + 设置场景
├─ AppDelegate.swift      生命周期、把快捷键/浮标接到翻译入口、辅助功能授权
├─ AppSettings.swift      UserDefaults 持久化的配置
├─ HotKeyManager.swift    Carbon 全局快捷键
├─ SelectionWatcher.swift 全局鼠标监听，判断“可能选中了文字”
├─ TextCapture.swift      模拟 ⌘C 取词 + 恢复剪贴板
├─ OpenAIClient.swift     OpenAI 兼容客户端（SSE 流式）
├─ TranslationSession.swift  单次翻译的可观察状态
├─ Popup.swift            贴光标的翻译浮窗
├─ FloatingIcon.swift     选中后的浮动小按钮
├─ SettingsView.swift     设置界面 + 快捷键录制
└─ KeyCodes.swift         键码 → 显示字符
```

## 已知限制 / 可继续做

- 取词用模拟 `⌘C`，极少数 App（如某些终端/安全输入框）可能取不到。
- 浮标基于“拖选/双击”启发式判断，并不知道是否真的选中了文字；点了之后若取词为空则不弹窗。
- 未做翻译历史、多服务商一键切换、朗读(TTS)、OCR 截图翻译——都可后续扩展。
