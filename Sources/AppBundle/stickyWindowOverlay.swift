import AVFoundation
import AppKit
import Common
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

@MainActor
private let stickyWindowOverlayManager = StickyWindowOverlayManager()

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
    private let displayLayer: AVSampleBufferDisplayLayer
    private let stream: SCStream
    private var sourceSize: CGSize
    private var isStopping = false
    private var isSourceActive: Bool?

    init(
        capturedWindow: SCWindow,
        rect: Rect,
        onActivate: @escaping @MainActor () -> Void,
    ) async throws {
        self.sourceSize = rect.size

        let configuration = StickyWindowOverlay.makeConfiguration(
            for: rect.size,
            scale: StickyWindowOverlay.backingScale(for: rect),
        )
        self.stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: capturedWindow),
            configuration: configuration,
            delegate: nil,
        )

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.clear.cgColor
        self.displayLayer = displayLayer

        let contentView = StickyWindowOverlayView(
            frame: CGRect(origin: .zero, size: rect.size),
            onActivate: onActivate,
        )
        contentView.wantsLayer = true
        contentView.layer = displayLayer

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
        panel.hasShadow = false
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
        Task { [stream] in
            try? await stream.stopCapture()
        }
    }

    func syncFrame(_ rect: Rect) async {
        panel.setFrame(StickyWindowOverlay.appKitFrame(for: rect), display: true)
        guard rect.size != sourceSize else { return }

        sourceSize = rect.size
        let newConfiguration = StickyWindowOverlay.makeConfiguration(
            for: rect.size,
            scale: StickyWindowOverlay.backingScale(for: rect),
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
                  CMSampleBufferGetImageBuffer(sampleBuffer.value) != nil,
                  !isStopping
            else {
                return
            }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer.value)
        }
    }

    private static func makeConfiguration(for size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(size.width * scale), 2)
        configuration.height = max(Int(size.height * scale), 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        return configuration
    }

    private static func backingScale(for rect: Rect) -> CGFloat {
        let appKitRect = appKitFrame(for: rect)
        return NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) })?.backingScaleFactor ?? 2
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

@MainActor
private final class StickyWindowOverlayView: NSView {
    private let onActivate: @MainActor () -> Void

    init(frame: CGRect, onActivate: @escaping @MainActor () -> Void) {
        self.onActivate = onActivate
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
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
