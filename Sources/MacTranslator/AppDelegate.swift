import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared

    private let hotKey = HotKeyManager(id: 1)
    private let ocrHotKey = HotKeyManager(id: 2)
    private let watcher = SelectionWatcher()
    private let popup = PopupController()
    private let icon = FloatingIconController()
    private let ocr = OCRTextCapture.shared

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

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.flush()
    }

    /// Temporarily releases the global hotkeys while the settings window is
    /// recording a new shortcut — otherwise the current combo is swallowed
    /// system-wide by the live registration and can never be re-recorded.
    func setHotkeysPaused(_ paused: Bool) {
        if paused {
            hotKey.unregister()
            ocrHotKey.unregister()
        } else {
            configureTriggers()
        }
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

        if settings.enableOCRHotkey {
            ocrHotKey.register(
                keyCode: UInt32(settings.ocrHotkeyKeyCode),
                modifiers: settings.ocrHotkeyCarbonModifiers
            ) { [weak self] in
                self?.translateScreenshotOCR()
            }
        } else {
            ocrHotKey.unregister()
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
                popup.showNotice("没有取到选中的文字。\n请先选中文本，或改用菜单栏里的「截图 OCR 翻译…」。", at: point)
                return
            }
            guard hasLookupProvider(at: point) else { return }
            popup.show(text: text, at: point, settings: settings)
        }
    }

    /// Translates whatever string is currently on the clipboard.
    func translateClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        guard hasLookupProvider(at: NSEvent.mouseLocation) else { return }
        popup.show(text: text, at: NSEvent.mouseLocation, settings: settings)
    }

    /// Lets the user draw a screen region, OCRs it locally, then translates the recognized text.
    func translateScreenshotOCR() {
        icon.hide()
        let startPoint = NSEvent.mouseLocation
        guard hasLookupProvider(at: startPoint) else { return }

        Task {
            do {
                let text = try await ocr.captureRecognizedText()
                popup.show(text: text, at: NSEvent.mouseLocation, settings: settings)
            } catch OCRCaptureError.cancelled {
                return
            } catch OCRCaptureError.screenRecordingDenied {
                popup.showNotice(
                    "需要「屏幕录制」权限才能截图 OCR。\n请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选「Text Selection Translation」，然后重试。",
                    at: startPoint
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                popup.showNotice("截图 OCR 失败：\(message)", at: startPoint)
            }
        }
    }

    private func hasLookupProvider(at point: NSPoint) -> Bool {
        guard settings.hasEnabledLookupProvider else {
            popup.showNotice("还没有启用任何 AI 后端或微软词典。\n请在设置里添加并启用至少一个。", at: point)
            return false
        }
        return true
    }

    // MARK: - Accessibility permission

    private func requestAccessibilityIfNeeded() {
        // Capturing the selection posts a synthetic ⌘C, which requires the
        // Accessibility permission. Prompt the user the first time.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
