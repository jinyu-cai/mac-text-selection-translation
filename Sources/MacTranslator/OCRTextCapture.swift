import AppKit
import CoreGraphics
import Vision

enum OCRCaptureError: LocalizedError {
    case alreadyInProgress
    case cancelled
    case screenRecordingDenied
    case screenCaptureFailed
    case noTextRecognized

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "已有一次截图 OCR 正在进行。"
        case .cancelled:
            return "已取消截图 OCR。"
        case .screenRecordingDenied:
            return "需要「屏幕录制」权限才能识别其他 App 或网页里的文字。"
        case .screenCaptureFailed:
            return "没有截取到屏幕图像。"
        case .noTextRecognized:
            return "没有识别到文字。"
        }
    }
}

@MainActor
final class OCRTextCapture {
    static let shared = OCRTextCapture()

    private struct Selection {
        let screen: NSScreen
        let rect: CGRect
    }

    private var overlayWindows: [OCRSelectionWindow] = []
    private var continuation: CheckedContinuation<Selection, Error>?

    private init() {}

    func captureRecognizedText() async throws -> String {
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            guard granted else { throw OCRCaptureError.screenRecordingDenied }
        }

        let selection = try await selectRegion()
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard let image = captureImage(for: selection) else {
            throw OCRCaptureError.screenCaptureFailed
        }

        let text = try await OCRRecognizer.recognizeText(in: image)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OCRCaptureError.noTextRecognized }
        return trimmed
    }

    private func selectRegion() async throws -> Selection {
        guard continuation == nil else { throw OCRCaptureError.alreadyInProgress }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            showOverlays()
        }
    }

    private func showOverlays() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        overlayWindows = NSScreen.screens.map { screen in
            let window = OCRSelectionWindow(screen: screen)
            let view = OCRSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if screen.displayID == activeScreen?.displayID {
                view.setInitialSelection(defaultSelectionRect(around: mouseLocation, in: screen))
            }
            view.onComplete = { [weak self, weak screen] rect in
                guard let screen else { return }
                self?.finish(.success(Selection(screen: screen, rect: rect)))
            }
            view.onCancel = { [weak self] in
                self?.finish(.failure(OCRCaptureError.cancelled))
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            return window
        }
        NSCursor.crosshair.set()
    }

    private func defaultSelectionRect(around point: CGPoint, in screen: NSScreen) -> CGRect {
        let margin: CGFloat = 32
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let maxWidth = max(160, bounds.width - margin * 2)
        let maxHeight = max(120, bounds.height - margin * 2)
        let size = CGSize(
            width: min(520, maxWidth),
            height: min(240, maxHeight)
        )
        let localPoint = CGPoint(
            x: point.x - screen.frame.minX,
            y: point.y - screen.frame.minY
        )
        let maxOriginX = max(margin, bounds.width - size.width - margin)
        let maxOriginY = max(margin, bounds.height - size.height - margin)
        let origin = CGPoint(
            x: min(max(localPoint.x - size.width / 2, margin), maxOriginX),
            y: min(max(localPoint.y - size.height / 2, margin), maxOriginY)
        )
        return CGRect(origin: origin, size: size)
    }

    private func finish(_ result: Result<Selection, Error>) {
        let continuation = continuation
        self.continuation = nil
        closeOverlays()
        continuation?.resume(with: result)
    }

    private func closeOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        NSCursor.arrow.set()
    }

    private func captureImage(for selection: Selection) -> CGImage? {
        guard let displayID = selection.screen.displayID else { return nil }

        let rect = selection.rect.standardized
        let displayBounds = CGDisplayBounds(displayID)
        let localBounds = CGRect(origin: .zero, size: displayBounds.size)
        let captureRect = CGRect(
            x: rect.minX,
            y: localBounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        .integral
        .intersection(localBounds)

        guard !captureRect.isNull, !captureRect.isEmpty else { return nil }

        if let image = CGDisplayCreateImage(displayID, rect: captureRect) {
            return image
        }

        if let fullImage = CGDisplayCreateImage(displayID),
           let croppedImage = fullImage.cropping(to: captureRect) {
            return croppedImage
        }

        return nil
    }
}

private enum OCRRecognizer {
    static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.012

            let preferredLanguages = [
                "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
                "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR"
            ]
            if let supported = try? request.supportedRecognitionLanguages() {
                let languages = preferredLanguages.filter { supported.contains($0) }
                if !languages.isEmpty {
                    request.recognitionLanguages = languages
                }
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            let observations = (request.results ?? [])
                .compactMap { observation -> (box: CGRect, text: String)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (observation.boundingBox, text)
                }
                .sorted { lhs, rhs in
                    let sameLine = abs(lhs.box.midY - rhs.box.midY) < 0.018
                    if sameLine { return lhs.box.minX < rhs.box.minX }
                    return lhs.box.midY > rhs.box.midY
                }

            return observations
                .map(\.text)
                .joined(separator: "\n")
        }.value
    }
}

private final class OCRSelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OCRSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var selectionRect: CGRect?
    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    private var dragRect: CGRect? {
        guard let dragStartPoint, let dragCurrentPoint else { return nil }
        return CGRect(
            x: min(dragStartPoint.x, dragCurrentPoint.x),
            y: min(dragStartPoint.y, dragCurrentPoint.y),
            width: abs(dragStartPoint.x - dragCurrentPoint.x),
            height: abs(dragStartPoint.y - dragCurrentPoint.y)
        )
    }

    private var visibleSelectionRect: CGRect? {
        dragRect ?? selectionRect
    }

    func setInitialSelection(_ rect: CGRect) {
        selectionRect = rect.standardized
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragCurrentPoint = dragStartPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrentPoint = convert(event.locationInWindow, from: nil)
        if let rect = dragRect, rect.width >= 8, rect.height >= 8 {
            selectionRect = rect.standardized
            completeSelection()
            return
        }

        let startedInsideSelection = dragStartPoint.map { point in
            selectionRect?.standardized.contains(point) ?? false
        } ?? false
        dragStartPoint = nil
        dragCurrentPoint = nil

        if startedInsideSelection {
            completeSelection()
        } else if selectionRect == nil {
            onCancel?()
        } else {
            needsDisplay = true
        }
    }

    private func completeSelection() {
        guard let rect = selectionRect?.standardized, rect.width >= 8, rect.height >= 8 else {
            onCancel?()
            return
        }
        dragStartPoint = nil
        dragCurrentPoint = nil
        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            completeSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.26).setFill()
        bounds.fill()

        drawInstruction()

        guard let rect = visibleSelectionRect else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawInstruction() {
        let text = "拖拽重选 OCR 区域，按 Enter 识别，Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let padding = CGSize(width: 18, height: 10)
        let textSize = attributed.size()
        let bubble = CGRect(
            x: bounds.midX - (textSize.width + padding.width * 2) / 2,
            y: bounds.maxY - textSize.height - padding.height * 2 - 44,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )

        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
        attributed.draw(at: CGPoint(
            x: bubble.minX + padding.width,
            y: bubble.minY + padding.height
        ))
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
