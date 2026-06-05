import AppKit
import SwiftUI

/// A borderless, non-activating panel that can still become key so the user
/// can select/scroll the translation without stealing focus from their app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Layout mode shared with the SwiftUI view. `userSize == nil` means
/// auto-height (grow with content); a non-nil size means the user resized it,
/// so we keep that fixed size and let content scroll.
@MainActor
final class PopupLayout: ObservableObject {
    @Published var userSize: CGSize?
}

/// A real AppKit drag handle in the bottom-right corner. Handling the mouse
/// itself (instead of a SwiftUI gesture) avoids fighting `isMovableByWindowBackground`
/// and the click-outside dismissal, and gives a large, reliable hit area.
final class ResizeHandleView: NSView {
    var onResizeDelta: ((CGFloat, CGFloat) -> Void)?
    private var lastLocation: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false } // resize, never move

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.diagonalResizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastLocation else { return }
        let now = NSEvent.mouseLocation
        onResizeDelta?(now.x - last.x, now.y - last.y) // screen coords (y up)
        lastLocation = now
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.3
        for i in 0..<3 {
            let off = CGFloat(i) * 4.5 + 5
            path.move(to: NSPoint(x: bounds.maxX - off, y: bounds.minY + 4))
            path.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + off))
        }
        path.stroke()
    }

    /// The system diagonal resize cursor (private), falling back to crosshair.
    static let diagonalResizeCursor: NSCursor = {
        let sel = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if NSCursor.responds(to: sel),
           let value = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return value
        }
        return .crosshair
    }()
}

@MainActor
final class PopupController {
    private let session = TranslationSession()
    private let layout = PopupLayout()
    private var panel: FloatingPanel?
    private var anchorTopLeft: NSPoint = .zero

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var isAdjusting = false

    private let defaultWidth: CGFloat = 360
    private let autoMaxHeight: CGFloat = 460
    private let minSize = CGSize(width: 300, height: 140)
    private let maxSize = CGSize(width: 900, height: 1000)
    private let handleSize: CGFloat = 24

    init() {
        let d = UserDefaults.standard
        let w = d.double(forKey: "popupWidth")
        let h = d.double(forKey: "popupHeight")
        if w > 0, h > 0 { layout.userSize = CGSize(width: w, height: h) }
    }

    func show(text: String, at point: NSPoint, settings: AppSettings) {
        let panel = ensurePanel()
        session.start(text: text, backends: settings.enabledBackends, prompt: settings.effectiveSystemPrompt())
        present(panel, at: point, initialHeight: 180)
    }

    func showNotice(_ message: String, at point: NSPoint) {
        let panel = ensurePanel()
        session.presentNotice(message)
        present(panel, at: point, initialHeight: 140)
    }

    private func present(_ panel: FloatingPanel, at point: NSPoint, initialHeight: CGFloat) {
        let size = layout.userSize ?? CGSize(width: defaultWidth, height: initialHeight)
        anchorTopLeft = anchor(near: point, height: size.height)
        isAdjusting = true
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(anchorTopLeft)
        isAdjusting = false
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
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: 180),
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
        panel.isMovableByWindowBackground = true // drag the card background to move

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

        // Container hosts the SwiftUI content + an AppKit resize handle on top.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: defaultWidth, height: 180))
        container.autoresizesSubviews = true

        let root = PopupView(
            session: session,
            layout: layout,
            onClose: { [weak self] in self?.close() },
            onHeightChange: { [weak self] height in self?.updateHeight(height) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let handle = ResizeHandleView(frame: NSRect(
            x: container.bounds.width - handleSize,
            y: 0,
            width: handleSize,
            height: handleSize
        ))
        handle.autoresizingMask = [.minXMargin, .maxYMargin] // stay bottom-right
        handle.onResizeDelta = { [weak self] dx, dy in self?.resizeBy(dx: dx, dy: dy) }
        container.addSubview(handle)

        panel.contentView = container
        self.panel = panel
        return panel
    }

    /// Auto-grows the panel as streamed text arrives — only while the user has
    /// not manually resized it.
    private func updateHeight(_ contentHeight: CGFloat) {
        guard let panel, layout.userSize == nil else { return }
        let clamped = max(110, min(contentHeight, autoMaxHeight))
        isAdjusting = true
        panel.setContentSize(NSSize(width: defaultWidth, height: clamped))
        panel.setFrameTopLeftPoint(anchorTopLeft)
        isAdjusting = false
    }

    /// Incremental resize from the drag handle (top-left pinned). `dy` is in
    /// screen coords (y up), so dragging down (dy < 0) makes it taller.
    private func resizeBy(dx: CGFloat, dy: CGFloat) {
        guard let panel else { return }
        let current = panel.contentView?.frame.size ?? panel.frame.size
        let w = min(max(current.width + dx, minSize.width), maxSize.width)
        let h = min(max(current.height - dy, minSize.height), maxSize.height)
        let size = CGSize(width: w, height: h)
        layout.userSize = size

        isAdjusting = true
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(anchorTopLeft)
        isAdjusting = false

        UserDefaults.standard.set(w, forKey: "popupWidth")
        UserDefaults.standard.set(h, forKey: "popupHeight")
    }

    /// Top-left corner for a popup placed below-right of `point`, flipped above
    /// when there is no room below, clamped to the visible screen.
    private func anchor(near point: NSPoint, height: CGFloat) -> NSPoint {
        let w = layout.userSize?.width ?? defaultWidth
        var x = point.x + 12
        var topY = point.y - 12

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if x + w > visible.maxX { x = visible.maxX - w - 8 }
            if x < visible.minX { x = visible.minX + 8 }
            if topY - height < visible.minY { topY = point.y + height + 12 }
            if topY > visible.maxY { topY = visible.maxY - 8 }
        }
        return NSPoint(x: x, y: topY)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.close()
                    return nil
                }
                return event
            }
            // Only dismiss on a click clearly outside the panel (small grace margin
            // so clicks near the edge / resize handle don't accidentally close it).
            let margin: CGFloat = 6
            let area = panel.frame.insetBy(dx: -margin, dy: -margin)
            if !area.contains(NSEvent.mouseLocation) {
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
    @ObservedObject var layout: PopupLayout
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void

    private var isUserSized: Bool { layout.userSize != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: isUserSized ? .infinity : nil, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, newValue in
                        if !isUserSized { onHeightChange(newValue) }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14) // keep content clear of the resize handle
        }
        .frame(maxHeight: isUserSized ? .infinity : 380)
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
