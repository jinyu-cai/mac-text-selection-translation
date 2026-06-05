import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchError: String?
    @State private var hostWindow: NSWindow?

    // Per-backend "test connection" state, keyed by backend id.
    @State private var testingIDs: Set<UUID> = []
    @State private var testOutcomes: [UUID: TestOutcome] = [:]

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
                            launchAtLogin = LoginItem.isEnabled // revert to real state
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
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

            Section("划词") {
                Toggle("启用全局快捷键", isOn: $settings.enableHotkey)
                    .onChange(of: settings.enableHotkey) { reconfigure() }

                LabeledContent("快捷键") {
                    ShortcutRecorder(keyCode: $settings.hotkeyKeyCode, modifiers: $settings.hotkeyModifiers)
                        .onChange(of: settings.hotkeyKeyCode) { reconfigure() }
                        .onChange(of: settings.hotkeyModifiers) { reconfigure() }
                        .disabled(!settings.enableHotkey)
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
                Text("划词取词需要「辅助功能」权限（用于模拟 ⌘C 复制选中文字）。授权后请重新启动本 App。")
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
            launchAtLogin = LoginItem.isEnabled
            // The SwiftUI Settings scene restores its last position (often on
            // another display). Pull it onto the screen the user is using and
            // bring it to the front on open.
            DispatchQueue.main.async {
                repositionToActiveScreen()
                bringToFront()
            }
        }
    }

    // MARK: - Per-backend connection test

    private func test(_ backend: Backend) {
        testingIDs.insert(backend.id)
        testOutcomes[backend.id] = nil
        let client = OpenAIClient(baseURL: backend.baseURL, apiKey: backend.apiKey, model: backend.model)
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

    private func reconfigure() {
        (NSApp.delegate as? AppDelegate)?.configureTriggers()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
            SecureField("API Key", text: $backend.apiKey, prompt: Text("sk-...（本地服务可留空）"))
                .textFieldStyle(.roundedBorder)
            TextField("模型", text: $backend.model, prompt: Text("gpt-4o-mini"))
                .textFieldStyle(.roundedBorder)
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

/// Click to record, then press a modifier + key combo.
private struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "请按下快捷键…" : KeyCodeNames.string(forKeyCode: keyCode, modifiers: flags))
                .monospaced()
                .frame(minWidth: 96)
        }
        .onDisappear { stop() }
    }

    private var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers))
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Esc cancels recording
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil } // require a modifier
            keyCode = Int(event.keyCode)
            modifiers = Int(mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
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
