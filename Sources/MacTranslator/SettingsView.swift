import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchError: String?

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
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("AI 接口（OpenAI 兼容）") {
                LabeledContent("Base URL") {
                    TextField("", text: $settings.apiBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key") {
                    SecureField("", text: $settings.apiKey, prompt: Text("sk-..."))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型") {
                    TextField("", text: $settings.model, prompt: Text("gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Button(testing ? "测试中…" : "测试连接") { test() }
                        .disabled(testing || settings.apiKey.isEmpty)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.callout)
                            .lineLimit(2)
                    }
                }
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    private func reconfigure() {
        (NSApp.delegate as? AppDelegate)?.configureTriggers()
    }

    private func test() {
        testing = true
        testResult = nil
        let client = OpenAIClient(baseURL: settings.apiBaseURL, apiKey: settings.apiKey, model: settings.model)
        Task {
            do {
                _ = try await client.verify()
                testOK = true
                testResult = "连接成功"
            } catch {
                testOK = false
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
