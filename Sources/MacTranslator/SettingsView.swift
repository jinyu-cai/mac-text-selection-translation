import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchRequiresApproval = LoginItem.requiresApproval
    @State private var launchError: String?
    @State private var hostWindow: NSWindow?

    // Per-backend "test connection" state, keyed by backend id.
    @State private var testingIDs: Set<UUID> = []
    @State private var testOutcomes: [UUID: TestOutcome] = [:]
    @State private var dictionaryTesting = false
    @State private var dictionaryTestOutcome: TestOutcome?

    struct TestOutcome { let ok: Bool; let message: String }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                        refreshLaunchState()
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                if launchRequiresApproval {
                    HStack {
                        Text("登录项已注册，但需要在系统设置中批准。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开登录项设置") { LoginItem.openSystemSettings() }
                    }
                }
                if let credentialError = settings.credentialError {
                    Label(credentialError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if settings.backends.isEmpty {
                    Text("还没有后端，点下方「添加后端」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.backends) { $backend in
                    BackendRow(
                        backend: $backend,
                        isTesting: testingIDs.contains(backend.id),
                        outcome: testOutcomes[backend.id],
                        onTest: { test(backend) },
                        onDelete: { settings.removeBackend(backend) }
                    )
                }
                Button {
                    settings.addBackend()
                } label: {
                    Label("添加后端", systemImage: "plus.circle")
                }
            } header: {
                Text("AI 后端（OpenAI 兼容，可启用多个并行对比）")
            } footer: {
                Text("勾选「启用」的后端会在每次翻译时**并行**调用，浮窗里每个后端一张结果卡。Base URL 会自动拼上 /chat/completions。")
                    .font(.caption)
            }

            Section {
                Toggle("启用微软词典", isOn: $settings.enableMicrosoftDictionary)

                if settings.enableMicrosoftDictionary {
                    TextField("Endpoint", text: $settings.microsoftTranslatorEndpoint, prompt: Text("https://api.cognitive.microsofttranslator.com"))
                        .textFieldStyle(.roundedBorder)
                    SecretTextField(
                        title: "Translator Key",
                        text: $settings.microsoftTranslatorKey,
                        prompt: "Azure Translator key"
                    )
                    TextField("Region", text: $settings.microsoftTranslatorRegion, prompt: Text("eastus / global 资源可按需留空"))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        TextField("源语言", text: $settings.microsoftDictionaryFromLanguage, prompt: Text("en"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 88)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("目标语言", text: $settings.microsoftDictionaryToLanguage, prompt: Text("zh-Hans"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 108)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button(dictionaryTesting ? "测试中…" : "测试词典") {
                            testDictionary()
                        }
                        .disabled(dictionaryTesting)
                        if let dictionaryTestOutcome {
                            Label(
                                dictionaryTestOutcome.message,
                                systemImage: dictionaryTestOutcome.ok ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(dictionaryTestOutcome.ok ? .green : .red)
                            .font(.callout)
                            .lineLimit(2)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("微软词典与读音")
            } footer: {
                Text("词典使用 Azure AI Translator Dictionary Lookup。读音按钮使用 macOS 本机语音，并按语言代码选择声音。")
                    .font(.caption)
            }

            Section("翻译") {
                LabeledContent("目标语言") {
                    TextField("", text: $settings.targetLanguage, prompt: Text("中文"))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义提示词（可选，留空使用内置翻译提示）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.customPrompt)
                        .font(.callout)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
            }

            Section("笔记") {
                Toggle("启用保存笔记", isOn: $settings.enableNotes)
                Text("开启后，翻译浮窗会显示保存按钮；笔记保存在本机 Application Support 目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("划词") {
                Toggle("启用全局快捷键", isOn: $settings.enableHotkey)
                    .onChange(of: settings.enableHotkey) { reconfigure() }

                LabeledContent("快捷键") {
                    ShortcutRecorder(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: $settings.hotkeyModifiers,
                        conflictKeyCode: settings.ocrHotkeyKeyCode,
                        conflictModifiers: settings.ocrHotkeyModifiers,
                        onRecordingChanged: setHotkeysPaused
                    )
                    .onChange(of: settings.hotkeyKeyCode) { reconfigure() }
                    .onChange(of: settings.hotkeyModifiers) { reconfigure() }
                    .disabled(!settings.enableHotkey)
                }
                if let error = settings.hotkeyRegistrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("启用截图 OCR 快捷键", isOn: $settings.enableOCRHotkey)
                    .onChange(of: settings.enableOCRHotkey) { reconfigure() }

                LabeledContent("OCR 快捷键") {
                    ShortcutRecorder(
                        keyCode: $settings.ocrHotkeyKeyCode,
                        modifiers: $settings.ocrHotkeyModifiers,
                        conflictKeyCode: settings.hotkeyKeyCode,
                        conflictModifiers: settings.hotkeyModifiers,
                        onRecordingChanged: setHotkeysPaused
                    )
                    .onChange(of: settings.ocrHotkeyKeyCode) { reconfigure() }
                    .onChange(of: settings.ocrHotkeyModifiers) { reconfigure() }
                    .disabled(!settings.enableOCRHotkey)
                }
                if let error = settings.ocrHotkeyRegistrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("选中文字后显示浮动翻译按钮", isOn: $settings.enableFloatingIcon)
                    .onChange(of: settings.enableFloatingIcon) { reconfigure() }
                Toggle("翻译后恢复剪贴板内容", isOn: $settings.restoreClipboard)
            }

            Section("权限") {
                HStack {
                    Label(
                        accessibilityTrusted ? "辅助功能权限：已授权" : "辅助功能权限：未授权",
                        systemImage: accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Spacer()
                    Button("打开系统设置") { openAccessibilitySettings() }
                }
                HStack {
                    Label(
                        screenRecordingAllowed ? "屏幕录制权限：已授权" : "屏幕录制权限：未授权",
                        systemImage: screenRecordingAllowed ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(screenRecordingAllowed ? .green : .orange)
                    Spacer()
                    Button("打开屏幕录制") { openScreenRecordingSettings() }
                }
                Text("划词取词需要「辅助功能」权限；截图 OCR 需要「屏幕录制」权限。授权后如仍不可用，请重启本 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 820, minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        .background(WindowAccessor { window in
            hostWindow = window
            configureSettingsWindow(window)
        })
        .onAppear {
            refreshLaunchState()
            // The SwiftUI Settings scene restores its last position (often on
            // another display). Pull it onto the screen the user is using and
            // bring it to the front on open.
            DispatchQueue.main.async {
                repositionToActiveScreen()
                bringToFront()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchState()
        }
    }

    // MARK: - Per-backend connection test

    private func test(_ backend: Backend) {
        testingIDs.insert(backend.id)
        testOutcomes[backend.id] = nil
        let client = OpenAIClient(baseURL: backend.baseURL, apiKey: backend.apiKey, model: backend.model, reasoning: backend.reasoning)
        Task {
            do {
                _ = try await client.verify()
                testOutcomes[backend.id] = TestOutcome(ok: true, message: "连接成功")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testOutcomes[backend.id] = TestOutcome(ok: false, message: message)
            }
            testingIDs.remove(backend.id)
        }
    }

    private func testDictionary() {
        dictionaryTesting = true
        dictionaryTestOutcome = nil
        let config = settings.microsoftDictionaryConfig
        let term = Self.sampleTerm(for: config.fromLanguage)
        let client = MicrosoftDictionaryClient(
            endpoint: config.endpoint,
            apiKey: config.apiKey,
            region: config.region
        )
        Task {
            do {
                let lookup = try await client.lookup(text: term, from: config.fromLanguage, to: config.toLanguage)
                let count = lookup.translations.count
                let message = count == 0 ? "连接成功，但未查到 \(term)" : "连接成功，返回 \(count) 个词条"
                dictionaryTestOutcome = TestOutcome(ok: true, message: message)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                dictionaryTestOutcome = TestOutcome(ok: false, message: message)
            }
            dictionaryTesting = false
        }
    }

    private static func sampleTerm(for language: String) -> String {
        let code = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if code.hasPrefix("zh") { return "你好" }
        if code.hasPrefix("ja") { return "猫" }
        if code.hasPrefix("ko") { return "안녕" }
        if code.hasPrefix("fr") { return "bonjour" }
        if code.hasPrefix("de") { return "hallo" }
        if code.hasPrefix("es") { return "hola" }
        return "hello"
    }

    // MARK: - Window behavior

    /// Brings the window to the front when it opens. It does NOT pin the window
    /// on top — once you click another window it can be covered normally.
    private func bringToFront() {
        guard let window = hostWindow ?? NSApp.keyWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// One-time window tweaks: make it user-resizable, and let it follow the
    /// user to whichever Desktop/Space is active instead of yanking them away.
    private func configureSettingsWindow(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    /// Moves the settings window to the screen under the cursor (centered),
    /// but only if it isn't already there — so a position the user chose is kept.
    private func repositionToActiveScreen() {
        guard let window = hostWindow ?? NSApp.keyWindow,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }
        if window.screen === screen { return }

        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = (visible.minX + visible.maxX - frame.width) / 2
        frame.origin.y = (visible.minY + visible.maxY - frame.height) / 2
        window.setFrame(frame, display: true)
    }

    private var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    private var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    private func reconfigure() {
        (NSApp.delegate as? AppDelegate)?.configureTriggers()
    }

    private func refreshLaunchState() {
        launchAtLogin = LoginItem.isEnabled
        launchRequiresApproval = LoginItem.requiresApproval
    }

    private func setHotkeysPaused(_ paused: Bool) {
        (NSApp.delegate as? AppDelegate)?.setHotkeysPaused(paused)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Editable row for one backend.
private struct BackendRow: View {
    @Binding var backend: Backend
    var isTesting: Bool
    var outcome: SettingsView.TestOutcome?
    var onTest: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $backend.isEnabled)
                    .labelsHidden()
                    .help("启用此后端")
                TextField("名称", text: $backend.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除此后端")
            }
            TextField("Base URL", text: $backend.baseURL, prompt: Text("https://api.openai.com/v1"))
                .textFieldStyle(.roundedBorder)
            SecretTextField(
                title: "API Key",
                text: $backend.apiKey,
                prompt: "sk-...（本地服务可留空）"
            )
            TextField("模型", text: $backend.model, prompt: Text("gpt-4o-mini"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("思考能力")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $backend.reasoning) {
                    ForEach(ReasoningMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 8) {
                Button(isTesting ? "测试中…" : "测试连接", action: onTest)
                    .disabled(isTesting)
                if let outcome {
                    Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(outcome.ok ? .green : .red)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .opacity(backend.isEnabled ? 1 : 0.55)
    }
}

/// Password-style text field with explicit reveal and copy controls.
private struct SecretTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    @State private var isRevealed = false
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text, prompt: Text(prompt))
                } else {
                    SecureField(title, text: $text, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "隐藏 \(title)" : "显示 \(title)")

            Button {
                copyToPasteboard()
            } label: {
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(text.isEmpty ? "\(title) 为空" : "复制 \(title)")
            .disabled(text.isEmpty)
        }
        .onChange(of: text) {
            didCopy = false
        }
    }

    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

/// Click to record, then press a modifier + key combo.
private struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var conflictKeyCode: Int?
    var conflictModifiers: Int?
    var onRecordingChanged: ((Bool) -> Void)?

    @State private var recording = false
    @State private var showsConflict = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .monospaced()
                .frame(minWidth: 96)
        }
        .onDisappear { stop() }
        .help(recording ? "按下新的组合键，Esc 取消" : "点击录制新的快捷键")
    }

    private var label: String {
        if showsConflict { return "与另一快捷键相同" }
        if recording { return "请按下快捷键…" }
        return KeyCodeNames.string(forKeyCode: keyCode, modifiers: flags)
    }

    private var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers))
    }

    private func start() {
        recording = true
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Esc cancels recording
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil } // require a modifier
            if Int(event.keyCode) == conflictKeyCode, Int(mods.rawValue) == conflictModifiers {
                flashConflict()
                return nil
            }
            keyCode = Int(event.keyCode)
            modifiers = Int(mods.rawValue)
            stop()
            return nil
        }
    }

    private func flashConflict() {
        showsConflict = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            showsConflict = false
        }
    }

    private func stop() {
        if recording {
            recording = false
            onRecordingChanged?(false)
        }
        showsConflict = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Hands back the `NSWindow` hosting this SwiftUI view, once it is attached.
private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
