# 项目技术详解 & Swift 学习指南

> 这份文档面向「想通过本项目学习 Swift / macOS 开发」的你。它把项目里用到的每个技术点拆开讲，
> 每个知识点都配上**本项目的真实代码**和「该注意什么」。同时覆盖 Git 开发流程、CI、安全检测等工程实践。
>
> 配套阅读：[README.md](README.md)（功能与使用）。本文件是「内部原理 + 学习」。

---

## 目录

1. [项目概览与整体架构](#1-项目概览与整体架构)
2. [构建系统：SPM + Makefile + .app 打包](#2-构建系统spm--makefile--app-打包)
3. [文件逐个详解](#3-文件逐个详解)
4. [Swift 语言核心概念（对照本项目）](#4-swift-语言核心概念对照本项目)
5. [SwiftUI 概念](#5-swiftui-概念)
6. [SwiftUI ↔ AppKit 互操作](#6-swiftui--appkit-互操作)
7. [并发：async/await 与 actor](#7-并发asyncawait-与-actor)
8. [macOS 系统集成细节](#8-macos-系统集成细节)
9. [翻译引擎：OpenAI 兼容 + SSE 流式](#9-翻译引擎openai-兼容--sse-流式)
10. [Git 开发流程](#10-git-开发流程)
11. [CI 与自动化测试](#11-ci-与自动化测试)
12. [安全检测](#12-安全检测)
13. [本项目踩过的坑（真实案例）](#13-本项目踩过的坑真实案例)
14. [用本项目练 Swift：进阶练习](#14-用本项目练-swift进阶练习)
15. [术语速查表](#15-术语速查表)

---

## 1. 项目概览与整体架构

**Text Selection Translation** 是一个常驻 macOS 菜单栏的「划词翻译」工具：选中任意文字 → AI 翻译浮窗。

- **语言/框架**：Swift 6 工具链（语言模式 5）、SwiftUI（界面）+ AppKit（窗口/系统集成）
- **形态**：菜单栏 accessory app（无 Dock 图标）
- **规模**：13 个 Swift 文件，约 1300 行

### 数据流（一次划词翻译）

```
用户选中文字
   │
   ├─(A) 按全局快捷键 ⌥D ──────────────┐
   │                                    │
   └─(B) 鼠标拖选 → SelectionWatcher    │
          → 浮出小图标 → 点击 ──────────┤
                                        ▼
                              AppDelegate.translate(at:)
                                        │
                         检查辅助功能权限 (AXIsProcessTrusted)
                                        │
                              TextCapture.captureSelectedText
                              （模拟 ⌘C → 读 NSPasteboard → 还原）
                                        │
                              PopupController.show(text:)
                                        │
                              TranslationSession.start(text:)
                                        │
                              OpenAIClient.translateStream  ← URLSession SSE
                                        │ （AsyncThrowingStream 逐字 yield）
                                        ▼
                              PopupView 逐字显示译文（@Published 驱动）
```

### 模块职责一览

| 层 | 文件 | 职责 |
|---|---|---|
| 入口/场景 | `App.swift` | `@main`、菜单栏、设置场景 |
| 协调器 | `AppDelegate.swift` | 生命周期、把各触发源接到翻译入口、权限 |
| 配置 | `AppSettings.swift` | UserDefaults 持久化的设置（含多个 AI 后端列表） |
| 配置 | `Backend.swift` | 单个 AI 后端的数据模型（`Codable`） |
| 触发 | `HotKeyManager.swift` | Carbon 全局快捷键 |
| 触发 | `SelectionWatcher.swift` | 全局鼠标监听（判断"可能选中了文字"） |
| 取词 | `TextCapture.swift` | 模拟 ⌘C + 剪贴板读写/还原 |
| 翻译 | `OpenAIClient.swift` | OpenAI 兼容客户端（SSE 流式） |
| 翻译状态 | `TranslationSession.swift` | 一次翻译里**多个后端并行**的可观察状态 |
| UI | `Popup.swift` | 贴光标的翻译浮窗 |
| UI | `FloatingIcon.swift` | 选中后的浮动小按钮 |
| UI | `SettingsView.swift` | 设置界面 + 快捷键录制 + 窗口辅助 |
| 工具 | `KeyCodes.swift` | 键码 → 显示字符 |
| 系统 | `LoginItem.swift` | 开机自启动（SMAppService） |

---

## 2. 构建系统：SPM + Makefile + .app 打包

本项目**不用 Xcode 工程文件**，而是用 Swift Package Manager（SPM）+ 一个 Makefile 把可执行文件包装成 `.app`。好处：纯命令行可构建、可读、可进 git。

### 2.1 `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTranslator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacTranslator", path: "Sources/MacTranslator")
    ],
    swiftLanguageModes: [.v5]
)
```

要点：
- `// swift-tools-version: 6.0`：**必须是第一行**，声明用哪个版本的 SPM 清单语法。
- `platforms: [.macOS(.v14)]`：最低 macOS 14（为了用 `MenuBarExtra`、`SettingsLink`、`SMAppService`、`.windowResizability` 等新 API）。
- `.executableTarget`：这是个**可执行程序**（不是库）。
- `swiftLanguageModes: [.v5]`：**关键**。用 Swift 6 编译器，但按 **语言模式 5** 编译——这样 Swift 6 的「严格并发检查」从「编译错误」降级为「警告/关闭」。对一个大量与 C（Carbon）、AppKit 回调打交道的 app，这能避免一堆 `Sendable`/actor 隔离的报错。等你 Swift 熟了，可以试着切到 `.v6` 体会严格并发。

### 2.2 `Makefile`

```make
BUNDLE  = Text Selection Translation.app
BIN     = MacTranslator
CONFIG ?= release
SIGN_ID ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q "MacTranslator Dev" && echo "MacTranslator Dev" || echo "-")

build:
	swift build -c $(CONFIG)

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp ".build/$(CONFIG)/$(BIN)" "$(BUNDLE)/Contents/MacOS/$(BIN)"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" "$(BUNDLE)" || true
```

要点：
- `swift build` 只产出一个**裸可执行文件**（在 `.build/release/`）。它不是 `.app`，没有 Info.plist，菜单栏 app 跑不正常。
- 一个 macOS `.app` 本质就是一个**目录**（bundle），结构固定：
  ```
  Foo.app/Contents/MacOS/可执行文件
  Foo.app/Contents/Info.plist
  Foo.app/Contents/Resources/...
  ```
  Makefile 的 `app` 目标就是手工拼这个结构。
- `SIGN_ID ?= $(shell ...)`：用 `?=`（仅当未设置时赋值）+ `$(shell ...)`（构建时执行命令）**自动探测**有没有自签名证书，有就用、没有就退回 ad-hoc（`-`）。详见[第 8.7 节](#87-代码签名为什么它和权限挂钩)。

### 2.3 `Info.plist`

`.app` 的「身份证」。关键键：
- `CFBundleExecutable`：可执行文件名（必须和 `Contents/MacOS/` 里的一致）。
- `CFBundleIdentifier`：`com.example.mactranslator`，TCC（权限系统）用它认 app。
- `LSUIElement = true`：**让 app 不出现在 Dock 和 ⌘Tab**——这是菜单栏 app 的关键开关。

---

## 3. 文件逐个详解

下面按「读代码的顺序」过一遍，每个文件挑出它教你的 Swift / macOS 知识点。

### `App.swift` — 程序入口
- `@main struct MacTranslatorApp: App`：SwiftUI 的程序入口。`App` 是个协议，`@main` 标记它为入口。
- `@NSApplicationDelegateAdaptor(AppDelegate.self)`：把传统 AppKit 的 `NSApplicationDelegate` 接进 SwiftUI 生命周期（很多系统级操作仍需要 AppDelegate）。
- `var body: some Scene`：App 的 body 返回 **Scene**（场景）不是 View。
- `MenuBarExtra(...)`：菜单栏图标 + 下拉菜单（macOS 13+）。
- `Settings { ... }`：标准设置窗口场景，自动绑定 ⌘, 和「App 名 → 设置…」菜单。
- `.windowResizability(.contentMinSize)`：让设置窗口可被用户缩放（内容定下限，往大随便拉）。

### `AppDelegate.swift` — 协调器
- `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`：整个类跑在主线程（见[第 7 节](#7-并发asyncawait-与-actor)）。
- `applicationDidFinishLaunching`：启动时设 `NSApp.setActivationPolicy(.accessory)`、接线、申请权限。
- `translate(at:)`：翻译总入口——先查权限，再异步取词，再弹窗。
- 把 4 个组件（hotKey / watcher / popup / icon）用闭包接到一起，是「依赖注入 + 回调」的范式。

### `AppSettings.swift` — 配置中心
- 单例 `static let shared`。
- `@Published var x { didSet { defaults.set(...) } }`：**属性观察器**模式——每次改动自动写 UserDefaults。
- `defaults.register(defaults:)`：注册默认值（key 不存在时返回它），这样 `bool(forKey:)` 默认能是 `true`。

### `HotKeyManager.swift` — C 互操作的范例
- 用 Carbon 的 `RegisterEventHotKey` 注册系统级快捷键。
- 教你 Swift ↔ C 互操作：`Unmanaged`、裸指针、**不能捕获上下文的 C 函数指针回调**。详见[第 4.8 节](#48-与-c-互操作carbon-快捷键)。

### `TextCapture.swift` — 合成事件 + 剪贴板
- `enum TextCapture`：用 **enum 当命名空间**（只有静态方法，无实例）——Swift 常见技巧。
- `CGEvent` 合成 ⌘C；`NSPasteboard` 读写；轮询 `changeCount` 判断复制完成。

### `SelectionWatcher.swift` — 全局事件监听
- `NSEvent.addGlobalMonitorForEvents`：监听**其他 app**的鼠标事件（被动观察，不拦截）。
- 用「按下位置 vs 抬起位置 + 点击次数」启发式判断是否发生了选中。

### `OpenAIClient.swift` — 网络 + 错误模型
- `struct` 值类型客户端。
- `enum TranslationError: LocalizedError`：**带关联值的枚举**做错误模型，`errorDescription` 给中文提示。
- `AsyncThrowingStream` + `URLSession.bytes` 做 SSE 流式（[第 9 节](#9-翻译引擎openai-兼容--sse-流式)）。

### `Backend.swift` — 后端数据模型
- `struct Backend: Identifiable, Codable, Equatable`：一个 AI 后端（名称/URL/key/模型/是否启用）。
- `Codable` → 整个 `[Backend]` 以 JSON 存进 UserDefaults；`Identifiable`（`id: UUID`）→ 直接用于 SwiftUI `ForEach` 和「按 id 更新对应结果」。

### `TranslationSession.swift` — 可观察状态
- `@MainActor final class ... : ObservableObject`。
- `@Published` 属性驱动 SwiftUI 刷新。
- **多后端并行**：持有 `[Result]`（每个启用后端一条），为每个后端开一个 `Task`、各自 `for try await` 流式更新自己的 `Result`，互不阻塞。

### `Popup.swift` — 自定义窗口
- `final class FloatingPanel: NSPanel { override var canBecomeKey: Bool { true } }`：子类化重写属性。
- `PopupController`：管理 `NSPanel` 生命周期、定位、随内容增高、可拖动、点外部关闭。
- `PopupView`：SwiftUI 卡片，`GeometryReader` 测高回传给控制器。

### `FloatingIcon.swift` — 小浮窗
- 和 Popup 类似但更简单：一个 28×28 的非激活面板 + 一个 SwiftUI 按钮。

### `SettingsView.swift` — 表单 + 自定义控件
- `Form` / `Section` / `LabeledContent` / `Toggle` / `SecureField` / `TextEditor`。
- `ShortcutRecorder`：用 `NSEvent.addLocalMonitorForEvents` 录快捷键。
- `WindowAccessor: NSViewRepresentable`：从 SwiftUI 里拿到底层 `NSWindow`（[第 6 节](#6-swiftui--appkit-互操作)）。

### `KeyCodes.swift` — 纯数据
- 用 `static let` 字典做键码→字符映射；`enum` 当命名空间。

### `LoginItem.swift` — 系统服务
- `SMAppService.mainApp`（macOS 13+）实现开机自启动（[第 8.6 节](#86-开机自启动-smappservice)）。

---

## 4. Swift 语言核心概念（对照本项目）

### 4.1 值类型 vs 引用类型（struct vs class）
- **struct（值类型）**：复制语义，常用于数据/视图。本项目：`OpenAIClient`、所有 SwiftUI `View`、`AppSettings.Keys`。
- **class（引用类型）**：共享语义，用于有「身份」和生命周期的对象。本项目：`AppDelegate`、`AppSettings`、各 `Controller`、`NSPanel` 子类。
- 经验法则：默认用 struct；需要共享可变状态、继承、或被 ObjC/AppKit 引用时用 class。

### 4.2 可选值 Optional（`?` / `if let` / `guard let` / `??`）
Swift 用 `Optional` 显式表达「可能没有值」。本项目大量出现：
```swift
// OpenAIClient.swift —— guard let 做「提前返回」
guard let http = response as? HTTPURLResponse else {
    throw TranslationError.invalidResponse
}
// AppSettings.swift —— ?? 提供默认值
apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
```
- `if let` / `guard let`：安全解包。`guard` 解包后变量在**后续作用域可用**，适合「不满足就早退」。
- `as?`：条件类型转换，失败返回 nil。

### 4.3 闭包与捕获列表（`[weak self]`）
闭包是「能捕获上下文的匿名函数」。在 app 里，闭包常被长期持有（回调、监听），容易形成**循环引用**（self 持有闭包、闭包又强引用 self → 都释放不掉）。解法是捕获列表 `[weak self]`：
```swift
// AppDelegate.swift
hotKey.register(keyCode: ..., modifiers: ...) { [weak self] in
    guard let self else { return }
    self.translate(at: NSEvent.mouseLocation)
}
```
- `[weak self]`：弱引用，self 可能变 nil。
- `guard let self else { return }`：把 weak 的可选 self 安全转成强引用用一会儿。

### 4.4 协议与扩展（protocol / extension）
- 协议定义「能力契约」：`App`、`View`、`Scene`、`ObservableObject`、`NSApplicationDelegate`、`LocalizedError`、`NSViewRepresentable` 都是协议。
- 遵循协议 = 实现它要求的成员。例如 `OpenAIClient` 的 `TranslationError` 遵循 `LocalizedError`，只要实现 `errorDescription`。

### 4.5 枚举与关联值（enum with associated values）
Swift 的枚举非常强大，能带「关联值」：
```swift
// OpenAIClient.swift
enum TranslationError: LocalizedError {
    case invalidURL
    case http(status: Int, body: String)   // 关联值
    case emptyResult
}
// 内部 SSE 解析也用 enum 表达三种结果
private enum Chunk { case delta(String); case done; case none }
```
配合 `switch` 做穷尽匹配，编译器会强制你处理每种情况——比「字符串/魔数」健壮得多。

### 4.6 错误处理（throws / try / do-catch）
```swift
func endpoint() throws -> URL { ... throw TranslationError.invalidURL ... }

do {
    for try await delta in client.translateStream(...) { self.output += delta }
} catch is CancellationError {
    // 被新翻译取消，忽略
} catch {
    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
```
- `throws` 声明会抛错；`try` 调用它；`do-catch` 捕获。
- `catch is XxxError`：按类型分支捕获。

### 4.7 属性观察器与属性包装器
- **属性观察器** `didSet`/`willSet`：值变化时触发。本项目用来「设置一改就存盘」：
  ```swift
  @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: Keys.apiKey) } }
  ```
- **属性包装器** `@Published`、`@State`、`@StateObject`…：用 `@` 语法给属性附加行为。`@Published` 让属性变化自动通知订阅者（Combine）。

### 4.8 与 C 互操作（Carbon 快捷键）
`HotKeyManager.swift` 是学 Swift↔C 互操作的好例子：
```swift
let selfPtr = Unmanaged.passUnretained(self).toOpaque()   // self → 裸指针
InstallEventHandler(GetEventDispatcherTarget(),
    { _, event, userData -> OSStatus in                    // C 回调：不能捕获上下文！
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
        DispatchQueue.main.async { manager.handler?() }
        return noErr
    },
    1, &eventSpec, selfPtr, &eventHandler)
```
要点：
- C 函数指针**不能是捕获了变量的闭包**，所以要把 `self` 转成裸指针经 `userData` 传进去，再在回调里转回来。
- `Unmanaged`：手动管理引用计数的桥接工具，与 C API 打交道时常见。
- `&eventSpec`：`inout`，把 Swift 变量地址传给 C。

---

## 5. SwiftUI 概念

### 5.1 View 是值类型、声明式
SwiftUI 的 `View` 是 struct，`body` 描述「此刻界面长什么样」。状态一变，SwiftUI 重新求值 `body` 并最小化更新真实视图。

### 5.2 状态管理三件套（本项目都用到了）
| 包装器 | 用途 | 本项目位置 |
|---|---|---|
| `@State` | 视图私有的小状态 | `SettingsView` 的 `testing`、`launchAtLogin`、`hostWindow` |
| `@Binding` | 把父视图的状态「借」给子视图读写 | `ShortcutRecorder(keyCode: $settings.hotkeyKeyCode)` 里的 `@Binding var keyCode` |
| `@StateObject` | 视图**拥有**一个引用型可观察对象（只创建一次） | `App.swift` 的 `@StateObject var settings` |
| `@ObservedObject` | 视图**观察**一个外部传入的可观察对象 | `PopupView` 的 `@ObservedObject var session` |
| `@EnvironmentObject` | 从环境注入的可观察对象 | `SettingsView`/`MenuContent` 的 `@EnvironmentObject var settings` |

配套：被观察的类要 `: ObservableObject`，可变状态用 `@Published`。
```swift
@MainActor final class TranslationSession: ObservableObject {
    @Published var output: String = ""   // 一变，所有显示它的 View 自动刷新
}
```
- `$` 前缀拿到 **Binding**：`$settings.apiKey` 传给 `SecureField`，实现双向绑定。

### 5.3 常用控件与修饰符
- 容器/布局：`VStack`/`HStack`/`ScrollView`/`Form`/`Section`/`LabeledContent`。
- 控件：`Button`/`Toggle`/`TextField`/`SecureField`/`TextEditor`/`ProgressView`/`Label`。
- 修饰符链：`.padding()`、`.frame(...)`、`.background(...)`、`.foregroundStyle(...)`、`.onChange(of:)`、`.onAppear`、`.textSelection(.enabled)`。
- `GeometryReader`：拿到容器尺寸。本项目用它测浮窗内容高度回传：
  ```swift
  .background(GeometryReader { proxy in
      Color.clear.onChange(of: proxy.size.height, initial: true) { _, h in onHeightChange(h) }
  })
  ```

---

## 6. SwiftUI ↔ AppKit 互操作

SwiftUI 还不能做所有事（自定义无边框浮窗、拿 NSWindow、系统级面板），这时下沉到 AppKit。本项目的关键桥接：

- **`@NSApplicationDelegateAdaptor`**：把 `AppDelegate` 接进来。
- **`NSHostingView(rootView:)`**：把一个 SwiftUI `View` 塞进 AppKit 的 `NSView`/`NSPanel`。
  ```swift
  panel.contentView = NSHostingView(rootView: PopupView(session: session, ...))
  ```
- **`NSViewRepresentable`**：反过来，把 AppKit 视图包成 SwiftUI View。本项目用它「曲线」拿到承载窗口：
  ```swift
  struct WindowAccessor: NSViewRepresentable {
      var onResolve: (NSWindow) -> Void
      func makeNSView(context: Context) -> NSView {
          let v = NSView()
          DispatchQueue.main.async { if let w = v.window { onResolve(w) } }  // 等挂到窗口后回调
          return v
      }
      func updateNSView(_ nsView: NSView, context: Context) {}
  }
  ```
  为什么要 `DispatchQueue.main.async`？因为 `makeNSView` 返回的瞬间，view 还没被加进窗口层级，`v.window` 还是 nil；推迟到下一轮 runloop 再取就有了。

---

## 7. 并发：async/await 与 actor

### 7.1 `async/await`
异步函数用 `async` 标记，调用处 `await`：
```swift
// TextCapture.swift
static func captureSelectedText(restore: Bool) async -> String? {
    ...
    try? await Task.sleep(nanoseconds: 15_000_000)  // 非阻塞地等 15ms
    ...
}
```
`await` 处函数可能「挂起」，让出线程，不会卡住 UI。

### 7.2 `Task`
开一个异步任务：
```swift
// AppDelegate.translate(at:)
Task {
    guard let text = await TextCapture.captureSelectedText(restore: settings.restoreClipboard) else { return }
    popup.show(text: text, ...)
}
```

### 7.3 `AsyncThrowingStream`（流式的关键）
把「逐步到达的数据 + 可能抛错」表达成一个可 `for await` 的序列。`OpenAIClient` 用它把 SSE 增量喂给 UI：
```swift
func translateStream(...) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            ...
            for try await line in bytes.lines {
                continuation.yield(delta)         // 推一段增量
            }
            continuation.finish()                 // 结束
        }
        continuation.onTermination = { _ in task.cancel() }  // 消费方取消时，连带取消网络
    }
}
```
消费方就能：
```swift
for try await delta in client.translateStream(...) { self.output += delta }
```

### 7.4 `@MainActor` 与隔离
UI 必须在主线程更新。`@MainActor` 把类型/方法「钉」在主线程：
```swift
@MainActor final class TranslationSession: ObservableObject { ... }
```
- 标了 `@MainActor` 的类型，其方法默认在主 actor 执行，里面改 `@Published` 就天然安全。
- 网络在后台跑（`OpenAIClient` 是普通 struct，其内部 `Task` 非隔离），`for try await` 的每次回到 `TranslationSession`（MainActor）才更新 UI——线程安全且顺序正确。
- 本项目用**语言模式 5**，所以编译器对 `Sendable`/隔离不那么严格；升到模式 6 你会被迫处理更多并发标注（这是进阶练习）。

---

## 8. macOS 系统集成细节

### 8.1 菜单栏 accessory app
- `Info.plist` 里 `LSUIElement = true` + 代码里 `NSApp.setActivationPolicy(.accessory)`：无 Dock 图标、不进 ⌘Tab、只在菜单栏。

### 8.2 全局快捷键（Carbon）
- 用 `RegisterEventHotKey`（Carbon），它**不需要辅助功能权限**就能全局捕获，且会「吃掉」该组合键。
- NSEvent 的修饰键（`NSEvent.ModifierFlags`）和 Carbon 的修饰键是两套常量，需转换（见 `AppSettings.hotkeyCarbonModifiers`）。

### 8.3 取词：合成 ⌘C + 剪贴板
核心思路（`TextCapture.swift`）：
1. 记下 `pasteboard.changeCount` 和当前内容快照；
2. 用 `CGEvent` 合成一次 ⌘C；
3. 轮询 `changeCount` 变化（最多 ~450ms）拿到新文本；
4. 还原原剪贴板（不污染用户剪贴板）。
- 合成按键（`CGEvent.post`）**需要辅助功能权限**，否则静默失败（这正是早期"点了没反应"的原因，见[第 13 节](#13-本项目踩过的坑真实案例)）。

### 8.4 浮窗：NSPanel 的门道
- `FloatingPanel: NSPanel`，`styleMask` 用 `.nonactivatingPanel`（点它**不抢**前台 app 的焦点——这样合成 ⌘C 仍作用于源 app）+ `.borderless`。
- `level = .floating`：浮在普通窗口之上。
- 重写 `canBecomeKey` 让无边框面板也能接收键盘（选中/复制译文）。
- `collectionBehavior`：
  - 浮窗用 `.canJoinAllSpaces`（所有桌面都显示）。
  - 设置窗口用 `.moveToActiveSpace`（跟随到你当前桌面，而不是把你拽走）。
- `isMovableByWindowBackground = true`：拖背景即可移动窗口。
- 随流式文本增高：用 `GeometryReader` 测高 → `setContentSize` + `setFrameTopLeftPoint`（钉住左上角，向下长）。

### 8.5 辅助功能权限（TCC）
- `AXIsProcessTrusted()` 查是否已授权；`AXIsProcessTrustedWithOptions([... Prompt: true])` 弹系统授权框。
- 授权信息存在系统 TCC 数据库，**按 app 的代码签名身份**记账——所以签名一变（见下），授权会失效。

### 8.6 开机自启动（SMAppService）
`LoginItem.swift`：
```swift
import ServiceManagement
SMAppService.mainApp.register()     // 开
SMAppService.mainApp.unregister()   // 关
SMAppService.mainApp.status         // .enabled / .notRegistered / .requiresApproval ...
```
- macOS 13+ 官方 API，取代老旧的 `SMLoginItemSetEnabled` 和登录项 AppleScript hack。
- 登记的是**当前 .app 的路径**——移动 app 后要重开一次。

### 8.7 代码签名：为什么它和权限挂钩
这是 macOS 开发最容易踩的工程点：
- **ad-hoc 签名**（`codesign -s -`）：没有稳定身份，每次重新构建 `cdhash` 都变。TCC 按 `cdhash` 记账 → **每次重建都要重新授权**。
- **自签名证书**：本项目用 `scripts/create-signing-cert.sh` 建了个本地证书 `MacTranslator Dev`，签出来的「指定要求（designated requirement）」是：
  ```
  identifier "com.example.mactranslator" and certificate leaf = H"<证书hash>"
  ```
  它**基于证书、不随重建变化** → 授权一次后，反复 `make app` 也不掉权限。
- 证书脚本的两个坑（已规避）：必须用系统 `/usr/bin/openssl`（LibreSSL，Homebrew 的 OpenSSL 3 导出的 p12 钥匙串认不了）；p12 传输密码不能为空。
- 首次用证书签名会弹「钥匙串授权」框，点一次「始终允许」后永久静默。

---

## 9. 翻译引擎：OpenAI 兼容 + SSE 流式

### 9.1 请求
- 端点：`{baseURL}/chat/completions`（代码会自动去掉 baseURL 尾部 `/` 再拼）。
- 头：`Authorization: Bearer <key>`、`Content-Type: application/json`。
- 体：`{ model, stream: true, temperature, messages: [{role:system,...},{role:user,...}] }`。
- 因为是 OpenAI **标准**接口，所以 OpenAI / DeepSeek / Kimi / Ollama / LM Studio 等都能接，只改 baseURL / key / model。

### 9.2 SSE 流式解析
服务端按 `text/event-stream` 一行行推：
```
data: {"choices":[{"delta":{"content":"你"}}]}
data: {"choices":[{"delta":{"content":"好"}}]}
data: [DONE]
```
解析（`OpenAIClient.parse`）：取 `data:` 前缀的行 → 去前缀 → `[DONE]` 即结束 → 否则 JSON 解出 `choices[0].delta.content` → `yield`。

### 9.3 Prompt 设计
`AppSettings.effectiveSystemPrompt()`：默认「翻译成目标语言；若已是目标语言则翻成英文；只输出译文」。允许用户用自定义 prompt 完全覆盖。

### 9.4 多后端并行对比
- `AppSettings.backends: [Backend]`，每个后端独立的 URL/key/模型/启用开关；以 JSON 存 UserDefaults（旧的单配置会自动迁移成第一个后端）。
- 翻译时 `TranslationSession` 对**所有启用的后端**各开一个 `Task`，每个独立流式；浮窗里每个后端一张 `ResultCard`，可分别复制、各自显示加载/错误。
- 这是「同一输入 → 多模型并行 → 同屏对比」的范式：因为接口都是 OpenAI 兼容，加一个后端只是多一条配置，不用改翻译逻辑。设置界面用 `ForEach($settings.backends)`（**绑定遍历**）实现增删改。

---

## 10. Git 开发流程

本项目实际采用的流程（你已经全程参与）：

### 10.1 分支与 PR
- `main` 是受保护主干。**所有改动走 feature 分支 → PR → 合并**。
- 命名：`feat/xxx`（新功能）、`fix/xxx`（修复）。
- 典型一轮：
  ```bash
  git checkout -b fix/settings-window
  git add <具体文件>            # 精确 add，别误带无关改动
  git commit -m "标题" -m "正文" -m "Co-Authored-By: ..."
  git push -u origin fix/settings-window
  gh pr create --base main --head fix/settings-window --title "..." --body "..."
  gh pr merge <PR#> --squash --delete-branch
  ```

### 10.2 `gh` CLI
- `gh repo create <name> --private --source=. --remote=origin --push`：建仓 + 关联 + 首推。
- `gh pr create / merge / view`、`gh api ...`（直接调 GitHub REST API）。
- `gh repo edit --visibility public`：改可见性。

### 10.3 分支保护（要求必须 PR）
公开仓库免费。本项目设的规则（通过 `gh api PUT .../branches/main/protection`）：
- `required_pull_request_reviews.required_approving_review_count = 0`：**必须走 PR**，但 0 审批 → 自己能自合。
- `enforce_admins = true`：管理员也强制走 PR。
- `allow_force_pushes = false`、`allow_deletions = false`：禁强推、禁删 main。

### 10.4 提交规范
- 标题祈使句、简短；正文用要点列改了什么/为什么。
- 本项目所有由 AI 协作的提交结尾带：`Co-Authored-By: Claude ...`。

### 10.5 Git 身份管理（重要一课）
**「谁建仓/开 PR」和「谁是 commit 作者」是两套独立身份**：
- 仓库归属 / PR：由 `gh auth`（token）决定 → 本项目是 `jinyu-cai`。
- commit 作者：由 `git config user.email` 决定，GitHub 按**邮箱**反查账号。

本项目早期出过岔子：机器的**全局** `git config` 是另一个账号的邮箱，而此仓库没本地覆盖，导致 commit 全挂到了错的账号。修法：
```bash
# 仓库级覆盖（只影响本仓库）
git config --local user.name "Jinyu"
git config --local user.email "jinyucai021@gmail.com"
# 让推送也走对的账号
git config --local credential.https://github.com.helper "!gh auth git-credential"
```
> 教训：多账号时，约定「全局用主账号，副账号项目里设 local 覆盖」。本地覆盖**不随 clone 走**，换机器要重设。

### 10.6 历史改写（慎用）
本项目把早期错账号的提交全部改写成正确账号：
```bash
git filter-branch -f --env-filter '
  if [ "$GIT_AUTHOR_EMAIL" = "旧邮箱" ]; then
    export GIT_AUTHOR_NAME="Jinyu"; export GIT_AUTHOR_EMAIL="新邮箱"
  fi
  # committer 同理
' -- main fix/settings-window
git push --force origin main fix/settings-window
```
注意：
- 改写会**改变所有 commit 哈希**，必须 `--force` 推送，且要先临时摘掉 main 分支保护、推完再装回。
- 公共仓库改写历史**有风险**（别人拉过就会冲突）；本项目因为是全新、单人、无人克隆，才低风险可行。
- 已**关闭的 PR** 里的旧记录不会被改写（GitHub 限制）。
- `git filter-branch` 已被官方标记 deprecated，更推荐 `git filter-repo`（需另装）。

---

## 11. CI 与自动化测试

> ⚠️ **现状**：本项目**目前还没有 CI、也没有单元测试**。下面是「建议的搭建方式」，可作为练习。

### 11.1 加单元测试
SPM 加一个测试 target。两种框架：
- **Swift Testing**（新，Swift 6 推荐，`import Testing` + `@Test`）。
- **XCTest**（老牌，`import XCTest`）。

`Package.swift` 加：
```swift
.testTarget(name: "MacTranslatorTests", dependencies: ["MacTranslator"], path: "Tests/MacTranslatorTests")
```
适合先测的纯逻辑（不依赖 UI/系统）：
- `OpenAIClient` 的 SSE 行解析、endpoint 拼接；
- `AppSettings.effectiveSystemPrompt()`；
- `KeyCodeNames.string(...)`。
> 提示：为了可测，把 `OpenAIClient.parse(line:)` 这类纯函数保持 `static` / 无副作用，很好测。`@testable import MacTranslator` 可访问 internal 成员。

跑测试：`swift test`。

### 11.2 加 GitHub Actions CI
新建 `.github/workflows/ci.yml`（示例）：
```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
jobs:
  build-test:
    runs-on: macos-15          # Apple Silicon runner，自带 Xcode/Swift
    steps:
      - uses: actions/checkout@v4
      - name: Show Swift
        run: swift --version
      - name: Build
        run: swift build -c release
      - name: Test
        run: swift test          # 有测试后启用
```
说明：
- macOS app 必须用 **macOS runner**（Linux 上没有 AppKit/SwiftUI）。
- 纯命令行 `swift build`/`swift test` 即可；要产 `.app` 可再跑 `make app`（CI 上一般 ad-hoc 签名）。

### 11.3 让 CI 成为合并门槛
CI 跑起来后，可在分支保护里把这个 check 设成 **required status check**：
```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'JSON'
{ "required_status_checks": { "strict": true, "contexts": ["build-test"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null }
JSON
```
这样「CI 不过 → PR 合不了」。

---

## 12. 安全检测

### 12.1 不把密钥写进代码/历史
- 本项目 API Key 存在 `UserDefaults`（运行时），**从不进 git**。
- `.gitignore` 排除 `.build/`、`*.app/`，避免误提交产物。
- **公开前做了全历史密钥扫描**（人工 + grep 高可信特征：`sk-...`、`gh[pousr]_...`、`AKIA...`、私钥、JWT、Slack token）。建议日后用工具：
  - `gitleaks detect`（专门扫密钥）。
  - 公开仓库 GitHub 自带 **Secret Scanning + Push Protection**（提交含密钥会被拦），可在仓库 Settings → Security 打开。

### 12.2 依赖与供应链
- 本项目零第三方依赖（只用系统框架），供应链面很小。
- 一旦引入 SPM 依赖，开启 **Dependabot**（GitHub Settings → Security）自动报漏洞/升级。

### 12.3 代码审查 / 安全审查
- 你这套环境里有两个可用技能：
  - `/code-review`：审查当前分支 diff（正确性 + 简化），可贴 PR 评论或直接改。
  - `/security-review`：对当前改动做安全审查。
- 习惯：**合并前**对 PR 跑一次审查。

### 12.4 签名与公证（分发时）
- 自用/本机：ad-hoc 或自签名即可。
- 要给别人用、过 Gatekeeper：需要 **Apple Developer ID** 证书签名 + **公证（notarization）**（`xcrun notarytool`）。本项目目前是本地自签名，**不可被他人直接信任运行**。

### 12.5 权限最小化
- 只申请必需的「辅助功能」（取词需要）。
- 取词后**还原剪贴板**，不留痕。
- 合成事件只在用户主动触发时进行。

---

## 13. 本项目踩过的坑（真实案例）

这些是开发本项目时**真实遇到并解决**的问题，特别值得记住：

1. **划词点了没反应** → 取词靠合成 ⌘C，需要辅助功能权限；没授权时 `CGEvent.post` **静默失败**。
   修法：先 `AXIsProcessTrusted()` 判断，没权限就弹**可见提示**（别静默），引导去授权。

2. **每次重建都要重新授权** → ad-hoc 签名 `cdhash` 每次都变，TCC 失效。
   修法：建**自签名证书**稳定签名身份（[8.7](#87-代码签名为什么它和权限挂钩)）。

3. **后台签名又退回 ad-hoc / codesign 卡住** → 在「后台 shell」里 `codesign` 用证书会触发钥匙串授权弹窗，后台点不了 → 卡住或退回 ad-hoc。
   修法：在**前台终端**跑 `make app`，对钥匙串弹窗点一次「始终允许」（之后永久静默）。

4. **设置窗口跑到别的显示器 / 别的桌面** → SwiftUI `Settings` 场景会恢复到上次位置/主屏，且不跟随 Space。
   修法：出现时 `setFrame` 拉到鼠标所在屏 + `collectionBehavior` 加 `.moveToActiveSpace`。

5. **设置窗口不能缩放** → `.fixedSize` + 固定 `.frame` 把它锁死了。
   修法：`.windowResizability(.contentMinSize)` + 放开 `.frame(minWidth:…maxHeight:.infinity)`。

6. **commit 挂到了错的 GitHub 账号** → 全局 `git config` 邮箱是另一个账号（见 [10.5](#105-git-身份管理重要一课)）。

7. **OpenSSL 3 导出的 p12 钥匙串认不了** → 用系统 `/usr/bin/openssl`（LibreSSL）+ 非空 p12 密码。

---

## 14. 用本项目练 Swift：进阶练习

由易到难，每条都能在本项目里练到具体知识点：

1. **改默认快捷键/目标语言**（改 `AppSettings` 默认值）—— 熟悉项目结构。
2. **给译文加「朗读」按钮**（`NSSpeechSynthesizer` 或 `AVSpeechSynthesizer`）—— 练 AppKit/AVFoundation API + SwiftUI 按钮。
3. **加「翻译历史」**：新建一个 `@MainActor ObservableObject` 存最近 N 条，新窗口展示 —— 练状态管理、列表、持久化（`Codable` + 文件/UserDefaults）。
4. **给纯逻辑加单元测试**（[11.1](#111-加单元测试)）—— 练 `swift test`、依赖解耦。
5. **加 CI**（[11.2](#112-加-github-actions-ci)）并设为合并门槛 —— 练工程化。
6. **多服务商一键切换**：把 `OpenAIClient` 抽象成协议，支持多套预设 —— 练协议、抽象。
7. **切到语言模式 6**（`Package.swift` 改 `.v6`）—— 直面严格并发，学 `Sendable`/actor 隔离（有挑战）。
8. **截图 OCR 翻译**（`Vision` 框架 `VNRecognizeTextRequest`）—— 练系统框架 + 异步。

每做一个，建议：开 feature 分支 → 实现 → `swift build` → `make app` 验证 → PR。

---

## 15. 术语速查表

| 术语 | 一句话 |
|---|---|
| SPM | Swift Package Manager，Swift 官方构建/依赖工具 |
| `.app` bundle | 一个目录伪装成「应用」，内含可执行文件 + Info.plist |
| `LSUIElement` | Info.plist 开关，让 app 不进 Dock（菜单栏 app 必备） |
| accessory app | `NSApp.setActivationPolicy(.accessory)`，无 Dock 的后台型 app |
| `@main` | 程序入口标记 |
| Scene / View | SwiftUI 的「窗口/场景」与「界面片段」 |
| `ObservableObject` / `@Published` | 可被 SwiftUI 观察的引用对象 / 其可变属性 |
| `@State`/`@Binding`/`@StateObject`/`@ObservedObject`/`@EnvironmentObject` | SwiftUI 状态包装器家族 |
| `@MainActor` | 把代码钉在主线程（UI 安全） |
| `async/await` / `Task` / `AsyncThrowingStream` | Swift 并发：异步函数 / 任务 / 异步序列 |
| `NSHostingView` / `NSViewRepresentable` | SwiftUI↔AppKit 双向桥接 |
| `NSPanel` / `nonactivatingPanel` | 辅助型窗口 / 点击不抢焦点 |
| TCC | macOS 的隐私权限系统（辅助功能等就在这） |
| `CGEvent` | 合成/读取底层输入事件（本项目用来发 ⌘C） |
| `NSPasteboard` | 剪贴板 |
| Carbon `RegisterEventHotKey` | 注册全局快捷键的老 C API |
| `SMAppService` | 现代登录项/后台服务 API（开机自启动） |
| codesign / designated requirement | 代码签名 / 系统识别 app 身份的规则（影响权限留存） |
| SSE | Server-Sent Events，服务端逐行推流（流式翻译） |
| 分支保护 / required status check | GitHub 强制「必须 PR / CI 必过」的规则 |

---

*本文档随项目演进，如有改动请同步更新。配合 `git log` 和各文件源码阅读效果最佳。*
