import SwiftUI

@main
struct MacTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra("Text Selection Translation", systemImage: "character.bubble") {
            MenuContent()
                .environmentObject(settings)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Text(appVersionLabel)
            .foregroundStyle(.secondary)

        Divider()

        Button("翻译剪贴板内容") {
            (NSApp.delegate as? AppDelegate)?.translateClipboard()
        }

        Button("截图 OCR 翻译…") {
            (NSApp.delegate as? AppDelegate)?.translateScreenshotOCR()
        }

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",")

        Button("退出 Text Selection Translation") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "版本 \(version) (\(build))"
    }
}
