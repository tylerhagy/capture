import AppKit
import CaptureCore

/// Every capture goes on the clipboard. Several in a row wait in a paste queue: each Cmd+V (or Ctrl+V, which Claude Code uses for pictures)
/// pastes the next one, in the order they were taken. Copying anything else lets the queue go.
@MainActor
final class Clipboard {
    let pasteboard: NSPasteboard
    private(set) var stack: PasteStack
    private var ours = -1                                    // the pasteboard's change count after our own last write
    private var poll: Timer?
    let watcher = PasteWatcher()
    let badge = CursorBadge()
    var onChange: () -> Void = {}
    /// Seconds between a paste and putting the next one on the clipboard: long enough for the app to have read it.
    var cmdDelay = 0.35, ctrlDelay = 0.8
    private var advancing = false
    /// Set by Copy with several chosen: the clipboard holds all of them (⌘V pastes everything), and Ctrl+V steps through them one at a time.
    /// Empty when the queue is the plain one made by captures arriving in a row.
    private var wholeSet: [URL] = []
    /// A capture, a drop or a delete ends the Copy set: from here the queue is the plain one, next picture first.
    private func leaveSet() { if !wholeSet.isEmpty { wholeSet = []; if let n = stack.next { write([n]) } } }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        stack = PasteStack(expiry: TimeInterval(Self.expirySeconds()))
        watcher.onPaste = { [weak self] ctrl in self?.pasted(ctrl: ctrl) }
    }

    /// The paste queue is on in Settings and macOS lets Capture see a paste.
    var queueEnabled: Bool { ((UserDefaults.standard.object(forKey: "stack.enabled") as? Bool) ?? true) && (watcher.running || testing) }
    var testing = false

    func start() {
        if (UserDefaults.standard.object(forKey: "stack.enabled") as? Bool) ?? true, CGPreflightListenEventAccess() { _ = watcher.start() }
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        poll?.tolerance = 0.25
    }
    /// How long the queue waits before letting go, in seconds (0 never). Settings used to keep whole minutes; that choice carries over.
    static func expirySeconds() -> Int {
        let d = UserDefaults.standard
        if let s = d.object(forKey: "stack.expirySeconds") as? Int { return s }
        if let m = d.object(forKey: "stack.expiryMinutes") as? Int { d.set(m * 60, forKey: "stack.expirySeconds"); return m * 60 }
        return 600
    }
    func setExpiry(seconds: Int) { stack.expiry = TimeInterval(seconds) }

    // MARK: in
    /// A new capture: on the clipboard now, or next in the queue.
    func captured(_ url: URL) {
        leaveSet()
        if queueEnabled {
            if stack.push(url) != nil { write([url]) }
        } else { stack.clear(); write([url]) }
        badge.flash(); changed()
    }
    /// Pictures or recordings dropped in (on the panel or the menu bar icon) join the end of the queue; one already waiting is not added twice.
    func enqueue(_ urls: [URL]) {
        leaveSet()
        let new = urls.filter { !stack.items.contains($0) }
        guard !new.isEmpty else { return }
        if queueEnabled { if let first = stack.push(contentsOf: new) { write([first]) } }
        else { write([new[0]]); Toast.show("Pasting one by one needs Input Monitoring (Settings)") }
        badge.flash(); changed()
    }
    /// Captures chosen in the library: all on the clipboard at once, so ⌘V in Teams, Mail or Finder pastes every one. A terminal takes only the first
    /// picture from a clipboard like that, so Ctrl+V pastes one, then the next one comes forward, and so on. When the last has gone, the whole set is back
    /// on the clipboard. One button, and nothing to decide about where it is pasted.
    func copyAll(_ urls: [URL]) {
        stack.clear(); wholeSet = []
        if urls.count > 1, queueEnabled { wholeSet = urls; _ = stack.push(contentsOf: urls) }
        write(urls); badge.flash(); changed()
    }
    func clear() { wholeSet = []; stack.clear(); changed() }
    /// A picture just marked up: on the clipboard now, and first in the queue when one is waiting.
    func putFirst(_ url: URL) {
        leaveSet()
        if queueEnabled { write([stack.pushFront(url)]) } else { stack.clear(); write([url]) }
        badge.flash(); changed()
    }
    /// A file changed in place: if it is what the clipboard holds, the clipboard gets the new picture.
    func refreshIfShowing(_ url: URL) { if stack.next == url, pasteboard.changeCount == ours { write([url]) } }
    /// Paste this one next: it moves to the front of the queue and onto the clipboard.
    func pasteNext(_ url: URL) { leaveSet(); if let u = stack.moveToFront(url) { write([u]) }; changed() }
    /// A file left the library: it leaves the queue too.
    func removed(_ url: URL) { leaveSet(); if let next = stack.remove(url) { write([next]) }; changed() }

    // MARK: a paste happened
    func pasted(ctrl: Bool) {
        guard queueEnabled, stack.count > 0, pasteboard.changeCount == ours, !advancing else { return }
        if !wholeSet.isEmpty, !ctrl { return }            // ⌘V pastes the whole set and leaves it alone
        advancing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (ctrl ? ctrlDelay : cmdDelay)) { MainActor.assumeIsolated {
            self.advancing = false
            guard self.pasteboard.changeCount == self.ours else { return }
            let next = self.stack.pasted()
            if !self.wholeSet.isEmpty {
                if self.stack.count > 0 { self.write(self.stack.items) } else { self.write(self.wholeSet); self.wholeSet = [] }      // the last one went: everything is back
            } else if let next { self.write([next]) }
            self.changed()
        } }
    }
    private func check() {
        if pasteboard.changeCount != ours, stack.count > 0 { stack.clear(); wholeSet = []; ours = pasteboard.changeCount; changed() }        // something else was copied
        if stack.expire() { if !wholeSet.isEmpty { write(wholeSet) }; wholeSet = []; changed() }      // mid-way through a Copy set, everything comes back to the clipboard
    }
    private func changed() { badge.update(count: queueEnabled ? stack.count : 0); onChange() }

    // MARK: writing
    func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.compactMap(Self.item))
        ours = pasteboard.changeCount
    }
    /// What goes on the clipboard for one capture. A picture goes as PNG only, as macOS's own screenshot-to-clipboard does, so it pastes as a picture in
    /// Terminal and chat apps (not as a file path). A recording goes as the file. A voice thought goes as its words.
    static func item(_ url: URL) -> NSPasteboardItem? {
        let it = NSPasteboardItem()
        switch CaptureKind.of(url) {
        case .screenshot:
            if url.pathExtension.lowercased() == "png", let d = try? Data(contentsOf: url) { it.setData(d, forType: .png) }
            else if let img = NSImage(contentsOf: url), let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) { it.setData(png, forType: .png) }
            else { return nil }
        case .voice:
            let words = url.pathExtension.lowercased() == "txt" ? url : url.deletingPathExtension().appendingPathExtension("txt")
            guard let s = try? String(contentsOf: words, encoding: .utf8) else { return nil }
            it.setString(s, forType: .string)
        case .recording, .file:
            it.setString(url.absoluteString, forType: .fileURL)
        }
        return it
    }
}

/// Sees Cmd+V and Ctrl+V anywhere, only to know a paste happened. It listens and never blocks or changes a key. Needs Input Monitoring.
final class PasteWatcher {
    var onPaste: (Bool) -> Void = { _ in }
    private var tap: CFMachPort?, source: CFRunLoopSource?
    var running: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let w = Unmanaged<PasteWatcher>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = w.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let f = event.flags, cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl)
                if cmd != ctrl, !f.contains(.maskAlternate) { DispatchQueue.main.async { w.onPaste(ctrl) } }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t; source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }
}

/// A small count that rides beside the pointer while two or more captures wait to be pasted. It lets clicks through, fades when the pointer rests,
/// and is kept out of screenshots. (macOS lets no app change the pointer inside other apps, so it follows the pointer instead.)
@MainActor
final class CursorBadge {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let pill = Themed(frame: .zero)
    private var timer: Timer?, lastPoint = NSPoint.zero, lastMove = Date(), flashUntil = Date.distantPast
    private(set) var count = 0
    var enabled: Bool { (UserDefaults.standard.object(forKey: "badge.enabled") as? Bool) ?? true }
    var shouldShow: Bool { enabled && (count >= 2 || (count == 1 && Date() < flashUntil)) }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 26, height: 20), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.ignoresMouseEvents = true; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.sharingType = .none
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1); panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        pill.fill = Intent.inverse; pill.stroke = Intent.background; pill.strokeWidth = 1.5; pill.radius = 10
        label.font = Intent.font(12, .medium); label.textColor = Intent.inverseForeground; label.alignment = .center
        pill.addSubview(label); panel.contentView = pill
    }
    func update(count n: Int) { count = n; layout(); refresh() }
    /// A single capture shows its 1 for a moment, as a quiet "copied".
    func flash() { flashUntil = Date().addingTimeInterval(1.6); refresh() }
    private func layout() {
        label.stringValue = "\(count)"; label.sizeToFit()
        let w = max(20, label.frame.width + 12)
        panel.setContentSize(NSSize(width: w, height: 20)); pill.frame = NSRect(x: 0, y: 0, width: w, height: 20)
        label.frame = NSRect(x: 0, y: (20 - label.frame.height) / 2, width: w, height: label.frame.height)
    }
    private func refresh() {
        if shouldShow {
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } } }
            lastMove = Date(); follow(); panel.orderFrontRegardless()
        } else { timer?.invalidate(); timer = nil; panel.orderOut(nil) }
    }
    private func follow() {
        if !shouldShow { refresh(); return }
        let p = NSEvent.mouseLocation
        if p != lastPoint { lastPoint = p; lastMove = Date() }
        panel.setFrameOrigin(NSPoint(x: p.x + 16, y: p.y - 34))
        let idle = Date().timeIntervalSince(lastMove)
        panel.alphaValue = idle < 2 ? 1 : max(0, 1 - CGFloat(idle - 2) * 2)          // rests: fades out; moves: back at once
    }
    var isShowing: Bool { panel.isVisible }
    var pillForTesting: NSView { pill }
    func snapshot() -> NSBitmapImageRep? { layout(); let r = pill.bitmapImageRepForCachingDisplay(in: pill.bounds); if let r { pill.cacheDisplay(in: pill.bounds, to: r) }; return r }
}
