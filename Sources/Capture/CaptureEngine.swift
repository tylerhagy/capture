import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox
import CaptureCore

/// Screenshots, scrolling captures and screen recordings, as one self-contained tool.
/// One small bar stays on screen while you capture; the screen is picked live, so desktops, gestures and other displays keep working. Nothing of ours is ever in a capture.
@MainActor
final class CaptureEngine {
    enum Kind { case screenshot, scrolling, record }
    let options: CaptureOptions
    let panel: CapturePanel
    let recorder: Recorder
    /// A finished picture: PNG data and the app it came from (the name only, never window titles).
    var onImage: (Data, String?) -> Void = { _, _ in }
    var voiceIsRecording: () -> Bool = { false }
    var onState: () -> Void = {}
    private(set) var phase: CapturePhase?
    private(set) var kind: Kind = .screenshot
    private var pickers: [PickerWindow] = [], outlines: [OutlineWindow] = []
    private var ticker: Timer?, follower: Timer?, recordingStart = Date(), recordingLabel = "screen"
    private(set) var asking = false
    private(set) var busy = false
    private(set) var chosen: CaptureTarget?
    private var scroll: ScrollSession?
    /// Stay in capture mode after a screenshot, so the next drag captures again (Settings). Off: one screenshot, then back to work.
    var stayOpen: Bool { UserDefaults.standard.bool(forKey: "capture.stayOpen") }
    var invisible = false
    private static let askedKey = "askedScreenRecording"
    private static let shutter: NSSound? = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

    init(recorder: Recorder, options: CaptureOptions = .shared) {
        self.recorder = recorder; self.options = options; panel = CapturePanel(options: options)
        panel.onChange = { [weak self] in self?.optionsChanged() }
        panel.onKeepRecording = { [weak self] in self?.asking = false; self?.refresh() }
        panel.onStop = { [weak self] in Task { await self?.stopRecording() } }
        panel.onPause = { [weak self] in Task { await self?.pauseRecording() } }
        panel.onResume = { [weak self] in Task { await self?.resumeRecording() } }
        panel.onExit = { [weak self] in self?.exitSession() }
        panel.onRecord = { [weak self] in self?.recordChosen() }
        panel.onDone = { [weak self] in self?.scroll?.finish() }
        recorder.onStopRequested = { [weak self] in Task { await self?.stopRecording() } }
    }

    var isRecording: Bool { phase == .recording || recorder.isRecording }
    var recordingSeconds: Int { Int(recorder.elapsed) }

    /// One entry for each tool (its shortcut, the panel, the URL). The same tool again leaves capture mode, or stops its recording; another tool switches over.
    func begin(_ k: Kind) async {
        switch phase {
        case .recording?: if k == .record { askToStop() } else { Toast.show("Stop the recording first") }
        case .scrolling?: if k == .scrolling { scroll?.finish() }
        case .choosing?:
            if k == kind { exitSession() } else { exitSession(); await begin(k) }
        case .saving?: break
        case nil:
            if voiceIsRecording() { Toast.show("Finish your voice thought first"); return }
            guard !busy, await ensurePermission() else { return }
            kind = k; options.video = k == .record; options.scrolling = k == .scrolling
            phase = .choosing; panel.show(on: Self.screenUnderPointer()); startChoosing(); onState()
        }
    }

    /// ⇧⌘3: the whole screen under the pointer, at once, with no picker.
    func screenNow() async {
        guard phase == nil, !busy else { return }
        if voiceIsRecording() { Toast.show("Finish your voice thought first"); return }
        guard await ensurePermission(), let s = Self.screenUnderPointer() else { return }
        busy = true; defer { busy = false }
        let front = NSWorkspace.shared.frontmostApplication
        await photo(.screen(s), app: front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.localizedName)
    }

    // MARK: the bar and its one line of help
    private func hint() -> String {
        switch phase {
        case .recording?:
            if asking { return "Nothing is lost: it is saved when you stop." }
            if recorder.paused { return "Paused. Resume or Stop; what you have is kept." }
            return "Recording the \(recordingLabel)\(options.mic || options.system ? "" : ", no sound"). Stop with the shortcut or the button."
        case .scrolling?:
            return scroll?.auto == true ? "Scrolling for you. Done or Return finishes; Esc cancels." : "Scroll down slowly, then press Done or Return. Esc cancels."
        case .saving?, nil: return ""
        case .choosing?:
            if options.scrolling { return "Drag over the part that scrolls · Esc to exit" }
            var t = options.mode == .area ? "Drag over what you want" : options.mode == .window ? "Click a window" : "Click a screen"
            if options.video { t = chosen == nil ? t + ", then press Record" : "Ready. Press Record to start (or choose again)" }
            return t + " · Esc to exit"
        }
    }
    func hintForTesting() -> String { hint() }
    private func refresh() {
        guard let p = phase else { return }
        panel.render(phase: p, seconds: Int(recorder.isRecording ? recorder.elapsed : Date().timeIntervalSince(recordingStart)), hint: hint(), canRecord: options.video ? chosen != nil : nil,
                     confirmingStop: asking && p == .recording, paused: recorder.paused, frames: scroll?.frameCount ?? 0)
        panel.recentre()
        if invisible { panel.alphaValue = 0 }
        onState()
    }
    private var lastChoice: (CaptureMode, Bool) = (.area, false)
    private func optionsChanged() {
        if (options.mode, options.video) != lastChoice { lastChoice = (options.mode, options.video); chosen = nil; pickers.forEach { ($0.contentView as? PickerView)?.selected = nil } }
        pickers.forEach { ($0.contentView as? PickerView)?.refresh() }; refresh()
    }
    private static func screenUnderPointer() -> NSScreen? { let p = NSEvent.mouseLocation; return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main }
    func mine() -> Set<CGWindowID> {
        var ids = Set(pickers.map { CGWindowID($0.windowNumber) } + outlines.map { CGWindowID($0.windowNumber) }); ids.insert(CGWindowID(panel.windowNumber)); return ids
    }

    // MARK: picking, live
    /// For the hidden self-test: open a session with nothing on the screen.
    func openForTesting(_ k: Kind) { invisible = true; kind = k; options.video = k == .record; options.scrolling = k == .scrolling; phase = .choosing; panel.alphaValue = 0; startChoosing() }
    var pickerCount: Int { pickers.count }

    private func startChoosing() {
        guard phase == .choosing, pickers.isEmpty else { return }
        lastChoice = (options.mode, options.video)
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false); w.isFloatingPanel = true; w.hidesOnDeactivate = false; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false; w.acceptsMouseMovedEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))); w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = PickerView(screen: screen, options: options); w.contentView = v
            v.mine = { [weak self] in self?.mine() ?? [] }
            v.onPick = { [weak self] t in self?.picked(t) }
            v.onCancel = { [weak self] in self?.exitSession() }
            v.onChanged = { [weak self] in self?.optionsChanged() }
            v.onReturn = { [weak self] in self?.returnPressed() }
            if invisible { w.alphaValue = 0 }
            pickers.append(w)
            if !invisible { w.orderFrontRegardless() }
        }
        startKeys(picking: true)
        if !invisible {
            BackgroundCursor.allow(true)
            (pickers.first { $0.frame.contains(NSEvent.mouseLocation) } ?? pickers.first).map { $0.makeKey(); $0.makeFirstResponder($0.contentView) }
        }
        refresh()
        if !invisible { pickers.compactMap { $0.contentView as? PickerView }.forEach { $0.applyCursor() } }
    }
    private func stopChoosing() {
        stopKeys(); pickers.forEach { $0.orderOut(nil) }; pickers = []
        if !invisible { NSCursor.arrow.set(); BackgroundCursor.allow(false) }
    }

    /// While a session is open, Esc and a few letters work from anywhere: the picking windows never take the keyboard from the app underneath.
    private func startKeys(picking: Bool) {
        stopKeys()
        // While recording, Return belongs to the app being recorded; only Esc is ours (and it asks first).
        var map: [(Int, () -> Void)] = [(kVK_Escape, { [weak self] in self?.exitSession() })]
        if phase != .recording { map.append((kVK_Return, { [weak self] in self?.returnPressed() })) }
        if picking && !options.scrolling {
            map += [(kVK_Space, { [weak self] in guard let o = self?.options else { return }; o.mode = o.mode == .window ? .area : .window; self?.optionsChanged() }),
                    (kVK_ANSI_A, { [weak self] in self?.options.mode = .area; self?.optionsChanged() }), (kVK_ANSI_W, { [weak self] in self?.options.mode = .window; self?.optionsChanged() }),
                    (kVK_ANSI_S, { [weak self] in self?.options.mode = .screen; self?.optionsChanged() })]
        }
        if invisible { return }
        for (i, (code, action)) in map.enumerated() { HotKeys.shared.register(Shortcut(keyCode: UInt32(code), modifiers: 0), id: UInt32(100 + i), action) }
    }
    private func stopKeys() { HotKeys.shared.unregister { $0 >= 100 } }

    private func returnPressed() {
        if phase == .scrolling { scroll?.finish(); return }
        if options.video { recordChosen() }
        else if options.mode == .screen, !options.scrolling, let s = Self.screenUnderPointer() { picked(.screen(s)) }
    }
    func recordChosen() {
        guard options.video, phase == .choosing, !busy else { return }
        guard let t = chosen else { Toast.show(options.mode == .area ? "Drag over what to record first" : options.mode == .window ? "Click a window to record first" : "Click a screen to record first"); return }
        chosen = nil; stopChoosing(); Task { await perform(t) }
    }
    /// The menu bar timer and the record shortcut: a recording is never stopped by one stray click or key. Asks first; the Stop button in the panel is the deliberate way.
    func askToStop() {
        guard phase == .recording else { Task { await stopRecording() }; return }
        asking = true; refresh()
    }
    /// Esc or Exit. A recording is never just walked away from: it asks first.
    func exitSession() {
        if phase == .recording { asking.toggle(); refresh(); return }
        if phase == .scrolling { scroll?.cancel(); return }
        if phase == .saving { return }
        chosen = nil; endSession()
    }
    private func picked(_ t: CaptureTarget) {
        guard !busy else { return }
        if options.video { chosen = t; pickers.forEach { ($0.contentView as? PickerView)?.selected = t }; refresh(); return }
        if options.scrolling { if case .area(let s, let r) = t { stopChoosing(); Task { await startScrolling(s, r) } }; return }
        if stayOpen { pickers.forEach { ($0.contentView as? PickerView)?.flash(t) } } else { stopChoosing() }
        Task { await perform(t); if !self.stayOpen { self.endSession() } }
    }

    // MARK: doing it
    private func perform(_ t: CaptureTarget) async {
        busy = true; defer { busy = false }
        let front = NSWorkspace.shared.frontmostApplication, app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.localizedName
        if options.video { await startRecording(t, app: app) } else { await photo(t, app: app) }
    }
    static func screenNumber(_ s: NSScreen) -> CGDirectDisplayID { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    static func ourWindows(_ content: SCShareableContent) -> [SCWindow] { content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier } }

    private func photo(_ t: CaptureTarget, app: String?) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ours = Self.ourWindows(content)
            let cfg = SCStreamConfiguration(); cfg.showsCursor = false; var filter: SCContentFilter, name = app
            switch t {
            case .area(let screen, let r):
                guard let d = content.displays.first(where: { $0.displayID == Self.screenNumber(screen) }) else { throw NSError(domain: "Capture", code: 2) }
                filter = SCContentFilter(display: d, excludingWindows: ours); let k = CGFloat(filter.pointPixelScale)
                cfg.sourceRect = CaptureGeometry.sourceRect(selection: r, viewHeight: screen.frame.height); cfg.width = Int(r.width * k); cfg.height = Int(r.height * k)
            case .screen(let screen):
                guard let d = content.displays.first(where: { $0.displayID == Self.screenNumber(screen) }) else { throw NSError(domain: "Capture", code: 2) }
                filter = SCContentFilter(display: d, excludingWindows: ours); let k = CGFloat(filter.pointPixelScale); cfg.width = Int(CGFloat(d.width) * k); cfg.height = Int(CGFloat(d.height) * k)
            case .window(let id, let owner):
                guard let w = content.windows.first(where: { $0.windowID == id }) else { throw NSError(domain: "Capture", code: 3) }
                filter = SCContentFilter(desktopIndependentWindow: w); let k = CGFloat(filter.pointPixelScale); cfg.width = Int(w.frame.width * k); cfg.height = Int(w.frame.height * k)
                name = owner ?? w.owningApplication?.applicationName ?? app
            }
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 4) }
            Self.shutter?.play(); onImage(png, name)
        } catch { NSLog("Capture: screenshot failed: \(error)"); Toast.show("Couldn’t capture that. Try again.") }
    }

    // MARK: scrolling capture
    private func startScrolling(_ screen: NSScreen, _ r: CGRect) async {
        let frame = CGRect(x: screen.frame.minX + r.minX, y: screen.frame.minY + r.minY, width: r.width, height: r.height).insetBy(dx: -4, dy: -4)
        let outline = OutlineWindow(frame: frame, color: Intent.ink, thickness: 3); outline.sharingType = .none
        if invisible { outline.alphaValue = 0 }; outline.orderFrontRegardless(); outlines = [outline]
        let s = ScrollSession(screen: screen, rect: r)
        s.onFrames = { [weak self] _ in self?.refresh() }
        s.onEnd = { [weak self] image in
            guard let self else { return }
            self.scroll = nil; self.endRecordingFrame()
            if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { Self.shutter?.play(); self.onImage(png, nil) }
            self.endSession()
        }
        scroll = s; phase = .scrolling; startKeys(picking: false); refresh()
        await s.start(excluding: mine())
    }

    // MARK: recording, with a frame around what is being recorded (never in the recording)
    private func appKitRect(_ t: CaptureTarget) -> (CGRect, String) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        switch t {
        case .area(let s, let r): return (CGRect(x: s.frame.minX + r.minX, y: s.frame.minY + r.minY, width: r.width, height: r.height).insetBy(dx: -4, dy: -4), "area")
        case .screen(let s): return (s.frame, "screen")
        case .window(let id, _): let b = LiveWindows.frame(of: id) ?? .zero; return (CGRect(x: b.minX, y: primaryH - b.maxY, width: b.width, height: b.height).insetBy(dx: -4, dy: -4), "window")
        }
    }
    private func startRecording(_ t: CaptureTarget, app: String?) async {
        let (frame, label) = appKitRect(t); recordingLabel = label
        let outline = OutlineWindow(frame: frame, color: Intent.red, thickness: 4); if invisible { outline.alphaValue = 0 }; outline.orderFrontRegardless(); outlines = [outline]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ours = Self.ourWindows(content)
            let filter: SCContentFilter; var points = CGSize.zero; var source: CGRect?; var name = app
            switch t {
            case .area(let screen, let r):
                guard let d = content.displays.first(where: { $0.displayID == Self.screenNumber(screen) }) else { throw NSError(domain: "Capture", code: 2) }
                filter = SCContentFilter(display: d, excludingWindows: ours); points = r.size; source = CaptureGeometry.sourceRect(selection: r, viewHeight: screen.frame.height)
            case .screen(let screen):
                guard let d = content.displays.first(where: { $0.displayID == Self.screenNumber(screen) }) else { throw NSError(domain: "Capture", code: 2) }
                filter = SCContentFilter(display: d, excludingWindows: ours); points = CGSize(width: d.width, height: d.height)
            case .window(let id, let owner):
                guard let w = content.windows.first(where: { $0.windowID == id }) else { throw NSError(domain: "Capture", code: 3) }
                filter = SCContentFilter(desktopIndependentWindow: w); points = w.frame.size; name = owner ?? w.owningApplication?.applicationName ?? app
            }
            guard await recorder.start(filter: filter, points: points, sourceRect: source, app: name, options: options) else { endRecordingFrame(); startChoosing(); return }
        } catch { NSLog("Capture: could not start recording: \(error)"); Toast.show("Couldn’t start recording. Try again."); endRecordingFrame(); startChoosing(); return }
        recordingStart = Date(); phase = .recording; asking = false; startKeys(picking: false); refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        if case .window(let id, _) = t {
            follower = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { guard let self, let o = self.outlines.first else { return }; o.place(self.appKitRect(.window(id, nil)).0) } }
        }
    }
    private func endRecordingFrame() { ticker?.invalidate(); ticker = nil; follower?.invalidate(); follower = nil; outlines.forEach { $0.orderOut(nil) }; outlines = [] }

    func pauseRecording() async {
        guard phase == .recording, recorder.isRecording, !recorder.paused else { return }
        await recorder.pause(); asking = false; outlines.forEach { $0.setDimmed(true) }; refresh()
    }
    func resumeRecording() async {
        guard phase == .recording, recorder.paused else { return }
        if await recorder.resume() { outlines.forEach { $0.setDimmed(false) } }
        refresh()
    }
    func stopRecording() async {
        guard phase == .recording || recorder.isRecording else { return }
        asking = false; stopKeys(); phase = .saving; endRecordingFrame(); refresh()
        await recorder.stop()
        endSession()
    }

    private func endSession() {
        stopChoosing(); stopKeys(); endRecordingFrame(); asking = false; scroll = nil
        panel.hide(); options.scrolling = false; let was = phase != nil; phase = nil; if was { onState() }
    }

    // MARK: permission, asked just in time with a short plain explanation
    private func ensurePermission() async -> Bool {
        if invisible || CGPreflightScreenCaptureAccess() { return true }
        let alert = NSAlert(); alert.alertStyle = .informational
        if !UserDefaults.standard.bool(forKey: Self.askedKey) {
            alert.messageText = "Allow Capture to see the screen"
            alert.informativeText = "macOS asks once for Screen Recording. Capture keeps only what you choose, in your Pictures folder, and nothing leaves this Mac."
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Not now")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            _ = CGRequestScreenCaptureAccess()
            Toast.show("After you allow it, press the shortcut again")
        } else {
            alert.messageText = "Screen Recording is off for Capture"
            alert.informativeText = "Turn it on in System Settings, under Privacy & Security, then Screen Recording. You may need to reopen Capture afterwards."
            alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let open = alert.runModal() == .alertFirstButtonReturn
            _ = CGRequestScreenCaptureAccess()
            if open, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
        }
        return false
    }
}
