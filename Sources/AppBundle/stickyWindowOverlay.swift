import AVFoundation
import AppKit
import Common
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

@MainActor
private let stickyWindowOverlayManager = StickyWindowOverlayManager()

// SCStreamConfiguration.backgroundColor is imported as unowned(unsafe), so
// retain the color for every stream configuration's lifetime.
private let stickyWindowTransparentCaptureBackground = NSColor.clear.cgColor

/// Creates an AeroSpace-owned, always-on-top mirror of a sticky window.
///
/// macOS doesn't allow AeroSpace to change another process' window level while
/// SIP is enabled. ScreenCaptureKit lets us mirror that window into an NSPanel
/// owned by AeroSpace, whose level and Space behavior we are allowed to control.
@MainActor
func setStickyWindowOverlay(_ window: Window, sticky: Bool) async -> String? {
    if isUnitTest { return nil }
    if sticky {
        return await stickyWindowOverlayManager.show(window)
    } else {
        stickyWindowOverlayManager.hide(windowId: window.windowId)
        return nil
    }
}

@MainActor
func hideStickyWindowOverlay(windowId: UInt32) {
    if !isUnitTest {
        stickyWindowOverlayManager.hide(windowId: windowId)
    }
}

@MainActor
func hideAllStickyWindowOverlays() {
    if !isUnitTest {
        stickyWindowOverlayManager.hideAll()
    }
}

@MainActor
func syncStickyWindowOverlays() async {
    if !isUnitTest {
        await stickyWindowOverlayManager.syncFrames()
    }
}

@MainActor
func syncStickyWindowOverlayVisibility() {
    if !isUnitTest {
        stickyWindowOverlayManager.syncVisibility()
    }
}

@MainActor
private final class StickyWindowOverlayManager {
    private var overlays: [UInt32: StickyWindowOverlay] = [:]

    func show(_ window: Window) async -> String? {
        if overlays[window.windowId] != nil {
            return nil
        }

        let preflightAccess = CGPreflightScreenCaptureAccess()
        guard preflightAccess || CGRequestScreenCaptureAccess() else {
            return """
                Screen Recording permission is required for sticky always-on-top windows.

                Enable AeroSpace in System Settings > Privacy & Security > \
                Screen & System Audio Recording, then quit and reopen AeroSpace.
                """
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false,
            )
            guard let capturedWindow = content.windows.first(where: { $0.windowID == window.windowId }) else {
                return "Can't make the window always-on-top because ScreenCaptureKit couldn't find it."
            }
            guard let rect = try await window.getAxRect(.nonCancellable) else {
                return "Can't make the window always-on-top because its frame isn't available."
            }

            let overlay = try await StickyWindowOverlay(
                capturedWindow: capturedWindow,
                rect: rect,
                onActivate: { [weak window] in
                    guard let window else { return }
                    stickyWindowOverlayManager.activate(window)
                },
            )
            overlays[window.windowId] = overlay
            overlay.setSourceActive(focus.windowOrNil?.windowId == window.windowId)
            return nil
        } catch {
            return """
                Can't make the window always-on-top: \(error.localizedDescription)

                Allow AeroSpace under System Settings > Privacy & Security > Screen Recording \
                (called Screen & System Audio Recording on newer macOS versions), restart AeroSpace if prompted, \
                then run the sticky shortcut again.
                """
        }
    }

    func hide(windowId: UInt32) {
        overlays.removeValue(forKey: windowId)?.stop()
    }

    func hideAll() {
        let previousOverlays = Array(overlays.values)
        overlays.removeAll()
        for overlay in previousOverlays {
            overlay.stop()
        }
    }

    func activate(_ window: Window) {
        guard window.isSticky, let overlay = overlays[window.windowId] else {
            hide(windowId: window.windowId)
            return
        }

        // Reveal and focus the genuine application window before handing input
        // back to it. The activating click is intentionally consumed by the
        // overlay; subsequent input goes directly to the real window.
        overlay.setSourceActive(true)
        _ = window.focusWindow()
        window.nativeFocus()
    }

    func syncVisibility() {
        let focusedWindowId = focus.windowOrNil?.windowId
        for (windowId, overlay) in overlays {
            overlay.setSourceActive(focusedWindowId == windowId)
        }
    }

    func syncFrames() async {
        // Sticky state is restored from the closed-windows cache after sleep,
        // display reconfiguration, and app relaunch. Recreate overlays that
        // weren't alive when that state was restored.
        let stickyWindows = Workspace.all
            .flatMap(\.allLeafWindowsRecursive)
            .filter(\.isSticky)
        for window in stickyWindows where overlays[window.windowId] == nil {
            _ = await show(window)
        }

        syncVisibility()
        for (windowId, overlay) in Array(overlays) {
            guard let window = Window.get(byId: windowId), window.isSticky else {
                hide(windowId: windowId)
                continue
            }
            guard let rect = try? await window.getAxRect(.nonCancellable) else { continue }
            await overlay.syncFrame(rect)
        }
    }
}

@MainActor
private final class StickyWindowOverlay: NSObject, SCStreamOutput {
    private let panel: NSPanel
    private let contentView: StickyWindowOverlayView
    private let displayLayer: AVSampleBufferDisplayLayer
    private let stream: SCStream
    private var sourceSize: CGSize
    private var captureScale: CGFloat
    private var isStopping = false
    private var isSourceActive: Bool?

    init(
        capturedWindow: SCWindow,
        rect: Rect,
        onActivate: @escaping @MainActor () -> Void,
    ) async throws {
        self.sourceSize = rect.size
        let captureScale = StickyWindowOverlay.backingScale(for: rect)
        self.captureScale = captureScale

        let configuration = makeStickyWindowStreamConfiguration(
            for: rect.size,
            scale: captureScale,
        )
        self.stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: capturedWindow),
            configuration: configuration,
            delegate: nil,
        )

        let displayLayer = AVSampleBufferDisplayLayer()
        // StickyWindowOverlayView sizes this layer with the frame's contentRect.
        // Its frame keeps the IOSurface aspect ratio, so .resize doesn't distort
        // the image or add another layer of aspect-fit letterboxing.
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.isOpaque = false
        self.displayLayer = displayLayer

        let contentView = StickyWindowOverlayView(
            frame: CGRect(origin: .zero, size: rect.size),
            displayLayer: displayLayer,
            onActivate: onActivate,
        )
        self.contentView = contentView

        let panel = NSPanel(
            contentRect: StickyWindowOverlay.appKitFrame(for: rect),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.contentView = contentView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // AppKit renders this outside the window frame, preserving exact source
        // alignment and mouse hit-testing while giving the rounded window a
        // native, compositor-backed shadow.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityElement(false)
        self.panel = panel

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        do {
            try await stream.startCapture()
        } catch {
            try? stream.removeStreamOutput(self, type: .screen)
            throw error
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        panel.orderOut(nil)
        displayLayer.flushAndRemoveImage()
        try? stream.removeStreamOutput(self, type: .screen)
        Task.startUnstructured { [stream] in
            try? await stream.stopCapture()
        }
    }

    func syncFrame(_ rect: Rect) async {
        panel.setFrame(StickyWindowOverlay.appKitFrame(for: rect), display: true)
        panel.invalidateShadow()

        let newCaptureScale = StickyWindowOverlay.backingScale(for: rect)
        guard rect.size != sourceSize || newCaptureScale != captureScale else { return }
        sourceSize = rect.size
        captureScale = newCaptureScale
        let newConfiguration = makeStickyWindowStreamConfiguration(
            for: rect.size,
            scale: newCaptureScale,
        )
        do {
            try await stream.updateConfiguration(newConfiguration)
        } catch {
            // Retain the last good stream configuration. The panel still follows
            // the source and AVSampleBufferDisplayLayer scales its contents.
        }
    }

    func setSourceActive(_ active: Bool) {
        guard isSourceActive != active, !isStopping else { return }
        isSourceActive = active
        if active {
            panel.orderOut(nil)
            displayLayer.flushAndRemoveImage()
        } else {
            // A hidden AVSampleBufferDisplayLayer can retain an old scheduled
            // frame. Resume with a clean timebase so the next captured frame
            // appears immediately instead of looking like a snapshot.
            displayLayer.flushAndRemoveImage()
            panel.orderFrontRegardless()
        }
    }

    nonisolated func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of _: SCStreamOutputType,
    ) {
        let sampleBuffer = SendableSampleBuffer(sampleBuffer)
        MainActor.assumeIsolated {
            guard sampleBuffer.value.isValid,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer.value),
                  !isStopping
            else {
                return
            }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            contentView.updateCaptureGeometry(
                StickyWindowCaptureGeometry.from(sampleBuffer: sampleBuffer.value),
                sourceHasAlpha: CVPixelBufferGetPixelFormatType(imageBuffer) == kCVPixelFormatType_32BGRA,
            )
            displayLayer.enqueue(sampleBuffer.value)
        }
    }

    private static func backingScale(for rect: Rect) -> CGFloat {
        let appKitRect = appKitFrame(for: rect)
        return NSScreen.screens
            .max(by: {
                $0.frame.intersection(appKitRect).area < $1.frame.intersection(appKitRect).area
            })?
            .backingScaleFactor ?? 2
    }

    private static func appKitFrame(for rect: Rect) -> CGRect {
        CGRect(
            x: rect.topLeftX,
            y: mainMonitor.height - rect.maxY,
            width: rect.width,
            height: rect.height,
        )
    }
}

/// Creates a single-window stream whose pixels retain the source window's
/// transparency. ScreenCaptureKit otherwise defaults to a bi-planar YUV format
/// that cannot represent alpha, turning rounded window corners black.
func makeStickyWindowStreamConfiguration(for size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = max(Int(size.width * scale), 2)
    configuration.height = max(Int(size.height * scale), 2)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 3
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.scalesToFit = true
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    unsafe configuration.backgroundColor = stickyWindowTransparentCaptureBackground
    if #available(macOS 14.0, *) {
        // Single-window shadows otherwise occupy transparent padding in the
        // IOSurface. AeroSpace supplies its own native panel shadow.
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.preservesAspectRatio = true
    }
    return configuration
}

extension CGRect {
    fileprivate var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}

/// Maps ScreenCaptureKit's IOSurface geometry into the visible overlay.
///
/// Apple documents `contentRect` as the region of interest to crop when
/// displaying a single-window stream. `boundingRect` is the minimum box around
/// all captured windows, so it is only a fallback when content metadata is
/// absent. Rectangles use IOSurface coordinates with a top-left origin.
struct StickyWindowCaptureGeometry: Equatable {
    let surfaceSize: CGSize
    let contentRect: CGRect?
    let boundingRect: CGRect?

    var cropRect: CGRect {
        validRect(contentRect) ?? validRect(boundingRect) ?? CGRect(origin: .zero, size: surfaceSize)
    }

    func displayLayerFrame(in destinationSize: CGSize) -> CGRect {
        guard isValid(size: destinationSize) else { return .zero }

        let cropRect = cropRect
        let scale = max(
            destinationSize.width / cropRect.width,
            destinationSize.height / cropRect.height,
        )
        let visibleSize = CGSize(
            width: cropRect.width * scale,
            height: cropRect.height * scale,
        )
        let centeringOffset = CGPoint(
            x: (destinationSize.width - visibleSize.width) / 2,
            y: (destinationSize.height - visibleSize.height) / 2,
        )

        // ScreenCaptureKit metadata is top-left based while Core Animation
        // layer frames are bottom-left based.
        let surfacePaddingBelowContent = surfaceSize.height - cropRect.maxY
        return CGRect(
            x: centeringOffset.x - cropRect.minX * scale,
            y: centeringOffset.y - surfacePaddingBelowContent * scale,
            width: surfaceSize.width * scale,
            height: surfaceSize.height * scale,
        )
    }

    private func validRect(_ rect: CGRect?) -> CGRect? {
        guard let rect, isValid(size: surfaceSize), isValid(size: rect.size) else { return nil }
        let surfaceBounds = CGRect(origin: .zero, size: surfaceSize)
        let intersection = rect.standardized.intersection(surfaceBounds)
        guard isValid(size: intersection.size) else { return nil }
        return intersection
    }

    private func isValid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func from(sampleBuffer: CMSampleBuffer) -> StickyWindowCaptureGeometry {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return StickyWindowCaptureGeometry(surfaceSize: .zero, contentRect: nil, boundingRect: nil)
        }

        let surfaceSize = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer),
        )
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false,
        ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentArray.first
        else {
            return StickyWindowCaptureGeometry(
                surfaceSize: surfaceSize,
                contentRect: nil,
                boundingRect: nil,
            )
        }

        let contentRect = attachments[.contentRect] as? CGRect
        let boundingRect: CGRect? = if #available(macOS 14.0, *) {
            attachments[.boundingRect] as? CGRect
        } else {
            nil
        }
        return StickyWindowCaptureGeometry(
            surfaceSize: surfaceSize,
            contentRect: contentRect,
            boundingRect: boundingRect,
        )
    }
}

@MainActor
private final class StickyWindowOverlayView: NSView {
    private static let fallbackCornerRadius: CGFloat = 10

    private let onActivate: @MainActor () -> Void
    private let contentLayer = CALayer()
    private let displayLayer: AVSampleBufferDisplayLayer
    private var captureGeometry: StickyWindowCaptureGeometry?
    private var sourceHasAlpha: Bool?

    init(
        frame: CGRect,
        displayLayer: AVSampleBufferDisplayLayer,
        onActivate: @escaping @MainActor () -> Void,
    ) {
        self.onActivate = onActivate
        self.displayLayer = displayLayer
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        contentLayer.cornerRadius = Self.fallbackCornerRadius
        contentLayer.cornerCurve = .continuous
        contentLayer.masksToBounds = true
        contentLayer.backgroundColor = NSColor.clear.cgColor
        contentLayer.isOpaque = false
        contentLayer.addSublayer(displayLayer)
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    func updateCaptureGeometry(_ geometry: StickyWindowCaptureGeometry, sourceHasAlpha: Bool) {
        guard geometry != captureGeometry || sourceHasAlpha != self.sourceHasAlpha else { return }
        captureGeometry = geometry
        self.sourceHasAlpha = sourceHasAlpha
        updateLayerFrames()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onActivate()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // BGRA frames retain each source window's exact alpha silhouette, so a
        // guessed radius would only distort app-specific corners. Keep the old
        // rounded clip solely as a defensive fallback for opaque pixel formats.
        contentLayer.cornerRadius = sourceHasAlpha == true ? 0 : Self.fallbackCornerRadius
        contentLayer.frame = bounds
        displayLayer.frame = captureGeometry?.displayLayerFrame(in: bounds.size) ?? bounds
        CATransaction.commit()
    }
}

/// ScreenCaptureKit owns the sample buffer for the duration of its output
/// callback. Core Media sample buffers are reference-counted and can safely be
/// retained until AVSampleBufferDisplayLayer enqueues them on the main queue.
private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}
