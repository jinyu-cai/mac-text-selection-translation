import AppKit
import SwiftUI

/// A tiny floating button that appears next to a fresh text selection.
/// Clicking it triggers a translation at that spot.
@MainActor
final class FloatingIconController {
    var onActivate: ((NSPoint) -> Void)?

    private var panel: NSPanel?
    private var anchorPoint: NSPoint = .zero
    private var autoHideTask: Task<Void, Never>?
    private let size = NSSize(width: 28, height: 28)
    private let autoHideDelay: UInt64 = 5_000_000_000

    func show(at point: NSPoint) {
        anchorPoint = point
        let panel = ensurePanel()

        var origin = NSPoint(x: point.x + 6, y: point.y - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        let delay = autoHideDelay
        autoHideTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.hideFromTimeout()
        }
    }

    private func hideFromTimeout() {
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = FloatingIconView { [weak self] in
            guard let self else { return }
            let point = self.anchorPoint
            self.hide()
            self.onActivate?(point)
        }
        panel.contentView = NSHostingView(rootView: view)

        self.panel = panel
        return panel
    }

    deinit {
        autoHideTask?.cancel()
    }
}

private struct FloatingIconView: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .scaleEffect(hovering ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shadow(radius: 2, y: 1)
    }
}
