import AppKit
import Carbon.HIToolbox
import CaptureCore

enum CaptureMode: String { case area, window, screen }

/// What the capture bar is set to. The target and the sound choices are remembered.
/// `video` and `scrolling` say which tool is open; they are set when a session opens and never remembered, so a shortcut never starts a recording by surprise.
final class CaptureOptions {
    static let shared = CaptureOptions()
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { d = defaults; d.register(defaults: ["capture.mic": true, "capture.system": false]) }
    var mode: CaptureMode { get { CaptureMode(rawValue: d.string(forKey: "capture.mode") ?? "") ?? .area } set { d.set(newValue.rawValue, forKey: "capture.mode") } }
    var mic: Bool { get { d.bool(forKey: "capture.mic") } set { d.set(newValue, forKey: "capture.mic") } }
    var system: Bool { get { d.bool(forKey: "capture.system") } set { d.set(newValue, forKey: "capture.system") } }
    var video = false
    var scrolling = false
    /// A scrolling capture is always an area.
    var effectiveMode: CaptureMode { scrolling ? .area : mode }
}

/// What the person chose. An area is in points from the bottom-left of its screen.
enum CaptureTarget {
    case area(NSScreen, CGRect), window(CGWindowID, String?), screen(NSScreen)
}

/// The windows on screen now, front to back, in the system's top-left coordinates.
enum LiveWindows {
    struct Info { var id: CGWindowID; var bounds: CGRect; var owner: String }
    static func list(excluding mine: Set<CGWindowID>) -> [Info] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID, !mine.contains(id), (d[kCGWindowLayer as String] as? Int) == 0, (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat], let w = b["Width"], let h = b["Height"], w >= 60, h >= 40, let x = b["X"], let y = b["Y"] else { return nil }
            return Info(id: id, bounds: CGRect(x: x, y: y, width: w, height: h), owner: d[kCGWindowOwnerName as String] as? String ?? "Window")
        }
    }
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let d = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first, let b = d[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A window the pointer picks from, drawn live over everything. It never activates the app, never hides a desktop, and gestures and other displays keep working.
final class PickerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerView: NSView {
    let screen: NSScreen
    let options: CaptureOptions
    var mine: () -> Set<CGWindowID> = { [] }
    var onPick: (CaptureTarget) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onChanged: () -> Void = {}
    var onReturn: () -> Void = {}
    var selected: CaptureTarget? { didSet { needsDisplay = true } }
    private var start: NSPoint?, selection: CGRect?, hover: LiveWindows.Info?, over = false, lastQuery = Date.distantPast
    private var mode: CaptureMode { options.effectiveMode }

    init(screen: NSScreen, options: CaptureOptions) {
        self.screen = screen; self.options = options
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    func refresh() { selection = nil; start = nil; hover = nil; window?.invalidateCursorRects(for: self); applyCursor(); needsDisplay = true }
    /// Crosshairs for an area, a hand for a window or a screen. Set directly, not only by cursor rect: the picking windows never make Capture the
    /// active app (so the window under the pointer keeps its focus look), and macOS applies cursor rects only for the active app.
    var cursor: NSCursor { mode == .area ? .crosshair : .pointingHand }
    func applyCursor() { if over || window?.frame.contains(NSEvent.mouseLocation) == true { cursor.set() } }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? screen.frame.height }
    private func windowUnder(_ local: NSPoint) -> LiveWindows.Info? {
        let g = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y), p = CGPoint(x: g.x, y: primaryHeight - g.y)
        return LiveWindows.list(excluding: mine()).first { $0.bounds.contains(p) }
    }
    override func mouseMoved(with e: NSEvent) {
        cursor.set()
        guard mode == .window, Date().timeIntervalSince(lastQuery) > 0.04 else { return }; lastQuery = Date()
        let h = windowUnder(convert(e.locationInWindow, from: nil)); if h?.id != hover?.id { hover = h; needsDisplay = true }
    }
    override func mouseEntered(with e: NSEvent) { over = true; cursor.set(); needsDisplay = true }
    override func mouseExited(with e: NSEvent) { over = false; hover = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch mode {
        case .area: start = p; selection = nil; needsDisplay = true
        case .window: if let w = windowUnder(p) ?? hover { onPick(.window(w.id, w.owner)) }
        case .screen: onPick(.screen(screen))
        }
    }
    override func mouseDragged(with e: NSEvent) {
        cursor.set()
        guard mode == .area, let s = start else { return }; let p = convert(e.locationInWindow, from: nil)
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard mode == .area else { return }
        if let s = selection, s.width > 3, s.height > 3 { onPick(.area(screen, s)) } else if start != nil { selection = nil; needsDisplay = true }
        start = nil
    }
    override func rightMouseDown(with e: NSEvent) { onCancel() }
    func flash(_ t: CaptureTarget) {
        var r: CGRect?
        switch t {
        case .area(let sc, let a): if sc == screen { r = a }
        case .screen(let sc): if sc == screen { r = bounds }
        case .window(let id, _): if let h = LiveWindows.list(excluding: mine()).first(where: { $0.id == id }) { r = CaptureGeometry.windowRect(windowFrame: h.bounds, screenFrame: screen.frame, primaryHeight: primaryHeight) }
        }
        guard let r else { return }
        let v = NSView(frame: r); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.white.cgColor; v.alphaValue = 0.7; addSubview(v)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; v.animator().alphaValue = 0 }, completionHandler: { v.removeFromSuperview() })
    }
    override func keyDown(with e: NSEvent) {
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased()) {
        case (UInt16(kVK_Escape), _): onCancel()
        case (UInt16(kVK_Return), _), (UInt16(kVK_ANSI_KeypadEnter), _): onReturn()
        default: super.keyDown(with: e)
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor); ctx.fill(bounds)
        var hole: CGRect?; var label: String?
        switch mode {
        case .area: if let s = selection, s.width > 0, s.height > 0 { hole = s; label = "\(Int(s.width)) × \(Int(s.height))" }
        case .window: if let h = hover, let r = CaptureGeometry.windowRect(windowFrame: h.bounds, screenFrame: screen.frame, primaryHeight: primaryHeight) { hole = r; label = h.owner }
        case .screen: if over { hole = bounds.insetBy(dx: 3, dy: 3); label = "This screen" }
        }
        if hole == nil, let sel = selected {
            switch sel {
            case .area(let sc, let a): if sc == screen { hole = a; label = "\(Int(a.width)) × \(Int(a.height)) · ready to record" }
            case .screen(let sc): if sc == screen { hole = bounds.insetBy(dx: 3, dy: 3); label = "This screen · ready to record" }
            case .window(let id, let owner):
                if let w = LiveWindows.list(excluding: mine()).first(where: { $0.id == id }), let r = CaptureGeometry.windowRect(windowFrame: w.bounds, screenFrame: screen.frame, primaryHeight: primaryHeight) { hole = r; label = "\(owner ?? w.owner) · ready to record" }
            }
        }
        guard let r = hole else { return }
        // Lifted out of the dim but never fully clear: a click on a clear part of a window falls through to the app underneath.
        ctx.clear(r); ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.fill(r)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2); ctx.stroke(r.insetBy(dx: -1, dy: -1))
        if let label {
            let attrs: [NSAttributedString.Key: Any] = [.font: Intent.font(Intent.caption, .medium), .foregroundColor: NSColor.white], t = label as NSString, size = t.size(withAttributes: attrs)
            let pill = NSRect(x: r.minX, y: max(r.minY - size.height - 12, 4), width: size.width + 14, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill(); t.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}

/// A colored frame around what is being recorded or scrolled: drawn outside the captured part, never in the capture, and it lets clicks through.
final class OutlineWindow: NSWindow {
    let color: NSColor
    private let thickness: CGFloat
    init(frame f: NSRect, color: NSColor, thickness: CGFloat) {
        self.color = color; self.thickness = thickness
        super.init(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(f, display: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true; isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = OutlineView(frame: NSRect(origin: .zero, size: f.size), color: color, thickness: thickness)
    }
    override var canBecomeKey: Bool { false }
    private(set) var dimmed = false
    func setDimmed(_ on: Bool) {
        guard on != dimmed else { return }; dimmed = on
        contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size), color: on ? color.withAlphaComponent(0.28) : color, thickness: thickness)
    }
    func place(_ f: NSRect) { setFrame(f, display: true); contentView?.frame = NSRect(origin: .zero, size: f.size); contentView?.needsDisplay = true }
}
private final class OutlineView: NSView {
    let color: NSColor, thickness: CGFloat
    init(frame: NSRect, color: NSColor, thickness: CGFloat) { self.color = color; self.thickness = thickness; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        color.setStroke(); let p = NSBezierPath(roundedRect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2), xRadius: 2, yRadius: 2); p.lineWidth = thickness; p.stroke()
    }
}

/// Lets Capture set the pointer while another app is active, only while a picker is open. It goes through the window server's own connection
/// setting (looked up at run time, as other screenshot tools do); if macOS ever drops it, the crosshair still shows once Capture is active.
enum BackgroundCursor {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let handle = dlopen(nil, RTLD_NOW)
    private static let mainConn: MainConn? = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConn.self) }
    private static let setProp: SetProp? = dlsym(handle, "CGSSetConnectionProperty").map { unsafeBitCast($0, to: SetProp.self) }
    static var available: Bool { mainConn != nil && setProp != nil }
    static func allow(_ on: Bool) {
        guard let mainConn, let setProp else { return }
        let c = mainConn(); _ = setProp(c, c, "SetsCursorInBackground" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
