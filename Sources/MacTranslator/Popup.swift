import AppKit
import SwiftUI

/// A borderless, non-activating panel that can still become key so the user
/// can select/scroll the translation without stealing focus from their app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupController {
    private let session = TranslationSession()
    private var panel: FloatingPanel?
    private var anchorTopLeft: NSPoint = .zero

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var isAdjusting = false

    private let width: CGFloat = 360
    private let maxHeight: CGFloat = 460

    func show(text: String, at point: NSPoint, settings: AppSettings) {
        let panel = ensurePanel()
        session.start(text: text, backends: settings.enabledBackends, prompt: settings.effectiveSystemPrompt())

        anchorTopLeft = anchor(near: point, height: 180)
        panel.setContentSize(NSSize(width: width, height: 180))
        panel.setFrameTopLeftPoint(anchorTopLeft)
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    /// Shows a one-off notice (e.g. a permission hint) instead of a translation.
    func showNotice(_ message: String, at point: NSPoint) {
        let panel = ensurePanel()
        session.presentNotice(message)

        anchorTopLeft = anchor(near: point, height: 140)
        panel.setContentSize(NSSize(width: width, height: 140))
        panel.setFrameTopLeftPoint(anchorTopLeft)
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    func close() {
        removeDismissMonitors()
        session.cancel()
        panel?.orderOut(nil)
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true // drag the popup by its background/header

        // When the user drags the popup, remember the new position so that
        // streaming height updates grow downward from there instead of snapping back.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, !self.isAdjusting else { return }
                self.anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            }
        }

        let root = PopupView(
            session: session,
            onClose: { [weak self] in self?.close() },
            onHeightChange: { [weak self] height in self?.updateHeight(height) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Grows the panel downward as streamed text arrives, keeping the top edge
    /// pinned to where it first appeared.
    private func updateHeight(_ contentHeight: CGFloat) {
        guard let panel else { return }
        let clamped = max(110, min(contentHeight, maxHeight))
        isAdjusting = true
        panel.setContentSize(NSSize(width: width, height: clamped))
        panel.setFrameTopLeftPoint(anchorTopLeft)
        isAdjusting = false
    }

    /// Returns the top-left corner (Cocoa screen coords) for a popup placed
    /// just below-right of `point`, flipped above the cursor when there is no
    /// room below, and clamped to the visible screen.
    private func anchor(near point: NSPoint, height: CGFloat) -> NSPoint {
        var x = point.x + 12
        var topY = point.y - 12

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if x + width > visible.maxX { x = visible.maxX - width - 8 }
            if x < visible.minX { x = visible.minX + 8 }
            if topY - height < visible.minY { topY = point.y + height + 12 } // flip above
            if topY > visible.maxY { topY = visible.maxY - 8 }
        }
        return NSPoint(x: x, y: topY)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        // Clicks in other apps close the popup.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // Esc closes it; clicks outside the panel close it.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.close()
                    return nil
                }
                return event
            }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.close()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
}

private struct PopupView: View {
    @ObservedObject var session: TranslationSession
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, newValue in
                        onHeightChange(newValue)
                    }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.secondary)
            Text("翻译")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if session.isLoading {
                ProgressView().controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let notice = session.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(session.sourceText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(session.results) { result in
                        ResultCard(result: result)
                    }
                }
            }
        }
        .frame(maxHeight: 380)
    }
}

/// One backend's translation result (name header + streaming text + copy).
private struct ResultCard: View {
    let result: TranslationSession.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.backendName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if result.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result.output, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("复制此译文")
                .disabled(result.output.isEmpty)
            }

            if let error = result.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(result.output.isEmpty ? "翻译中…" : result.output)
                    .font(.body)
                    .foregroundStyle(result.output.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
