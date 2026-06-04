import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared

    private let hotKey = HotKeyManager()
    private let watcher = SelectionWatcher()
    private let popup = PopupController()
    private let icon = FloatingIconController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        icon.onActivate = { [weak self] point in
            self?.translate(at: point)
        }
        watcher.onSelection = { [weak self] point in
            guard let self, self.settings.enableFloatingIcon else { return }
            self.icon.show(at: point)
        }
        watcher.onDismiss = { [weak self] in
            self?.icon.hide()
        }

        configureTriggers()
        requestAccessibilityIfNeeded()
    }

    /// (Re)wires the global hotkey and the selection watcher from current settings.
    /// Safe to call repeatedly — used both at launch and whenever settings change.
    func configureTriggers() {
        if settings.enableHotkey {
            hotKey.register(
                keyCode: UInt32(settings.hotkeyKeyCode),
                modifiers: settings.hotkeyCarbonModifiers
            ) { [weak self] in
                guard let self else { return }
                self.translate(at: NSEvent.mouseLocation)
            }
        } else {
            hotKey.unregister()
        }

        if settings.enableFloatingIcon {
            watcher.start()
        } else {
            watcher.stop()
            icon.hide()
        }
    }

    // MARK: - Translation entry points

    /// Captures the current selection (anywhere on screen) and shows the popup.
    func translate(at point: NSPoint) {
        icon.hide()

        // Capturing text posts a synthetic ⌘C, which silently does nothing
        // without Accessibility permission — surface that instead of failing quietly.
        guard AXIsProcessTrusted() else {
            popup.showNotice(
                "需要「辅助功能」权限才能取词。\n请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选「Text Selection Translation」，然后重启本应用。",
                at: point
            )
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }

        Task {
            guard let text = await TextCapture.captureSelectedText(restore: settings.restoreClipboard),
                  !text.isEmpty
            else {
                popup.showNotice("没有取到选中的文字。\n请先选中文本，或确认该应用允许复制（⌘C）。", at: point)
                return
            }
            popup.show(text: text, at: point, settings: settings)
        }
    }

    /// Translates whatever string is currently on the clipboard.
    func translateClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        popup.show(text: text, at: NSEvent.mouseLocation, settings: settings)
    }

    // MARK: - Accessibility permission

    private func requestAccessibilityIfNeeded() {
        // Capturing the selection posts a synthetic ⌘C, which requires the
        // Accessibility permission. Prompt the user the first time.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
