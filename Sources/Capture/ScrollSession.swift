import AppKit
import ScreenCaptureKit
import CaptureCore

/// A scrolling capture of one area. With Accessibility allowed, Capture scrolls the area itself, a step at a time; without it, you scroll by hand and frames are taken as it moves.
/// Either way the frames are joined by `Stitcher` into one tall picture.
@MainActor
final class ScrollSession {
    let screen: NSScreen
    let rect: CGRect                     // points, bottom-left of its screen
    let auto: Bool
    var onFrames: (Int) -> Void = { _ in }
    var onEnd: (CGImage?) -> Void = { _ in }
    private var frames: [CGImage] = [], sigs: [Stitcher.Signature] = [], hints: [Int?] = []
    private var running = false, ended = false, finishing = false
    private var filter: SCContentFilter?, cfg: SCStreamConfiguration?
    private var timer: Timer?
    static let maxFrames = 80

    init(screen: NSScreen, rect: CGRect, auto: Bool = CGPreflightPostEventAccess()) { self.screen = screen; self.rect = rect; self.auto = auto }
    var frameCount: Int { frames.count }

    func start(excluding mine: Set<CGWindowID>) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let d = content.displays.first(where: { $0.displayID == CaptureEngine.screenNumber(screen) }) else { throw NSError(domain: "Capture", code: 2) }
            let f = SCContentFilter(display: d, excludingWindows: CaptureEngine.ourWindows(content)), k = CGFloat(f.pointPixelScale)
            let c = SCStreamConfiguration(); c.showsCursor = false
            c.sourceRect = CaptureGeometry.sourceRect(selection: rect, viewHeight: screen.frame.height); c.width = Int(rect.width * k); c.height = Int(rect.height * k)
            filter = f; cfg = c
        } catch { NSLog("Capture: scrolling capture could not start: \(error)"); Toast.show("Couldn’t start the scrolling capture. Try again."); end(nil); return }
        running = true
        guard await grab() else { end(nil); return }
        if auto { await autoScroll() } else { timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.manualTick() } } }
    }

    /// Takes a frame; keeps it only when the area moved. Returns false when the capture failed.
    @discardableResult
    private func grab(hint: Int? = nil) async -> Bool {
        guard let filter, let cfg, let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg), let sig = Stitcher.signature(img) else { return false }
        if let last = sigs.last, Stitcher.same(last, sig) { return true }
        frames.append(img); sigs.append(sig); hints.append(hint); onFrames(frames.count)
        return true
    }
    private var lastMoved: Bool { sigs.count >= 2 && !Stitcher.same(sigs[sigs.count - 2], sigs[sigs.count - 1]) }

    // MARK: Capture scrolls
    private func autoScroll() async {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let centre = CGPoint(x: screen.frame.minX + rect.midX, y: primaryH - (screen.frame.minY + rect.midY))      // system coordinates, top-left
        let back = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(centre)
        let stepPoints = max(40, Int(rect.height * 0.6)), scale = Int(screen.backingScaleFactor)
        var direction: Int32 = -1, stuck = 0
        while running, frames.count < Self.maxFrames {
            let before = frames.count
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: direction * Int32(stepPoints), wheel2: 0, wheel3: 0) { e.location = centre; e.post(tap: .cghidEventTap) }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard running, await grab(hint: stepPoints * scale) else { break }
            if frames.count == before {
                if frames.count == 1 && direction == -1 { direction = 1; continue }            // natural scrolling flipped it: try the other way once
                stuck += 1; if stuck >= 2 { break }                                           // nothing moved twice: the end of the page
            } else { stuck = 0 }
        }
        if let back { CGWarpMouseCursorPosition(back) }
        if running { finish() }
    }

    // MARK: you scroll
    private func manualTick() {
        guard running, frames.count < Self.maxFrames else { if running { finish() }; return }
        Task { await grab() }
    }

    func finish() {
        guard !ended, !finishing else { return }
        finishing = true; running = false; timer?.invalidate(); timer = nil
        let fs = frames, hs = hints
        Task.detached(priority: .userInitiated) {
            let image = Stitcher.stitch(fs, hints: hs)
            await MainActor.run { self.end(image) }
        }
    }
    func cancel() { running = false; timer?.invalidate(); timer = nil; end(nil) }
    private func end(_ image: CGImage?) { guard !ended else { return }; ended = true; onEnd(image) }
}
