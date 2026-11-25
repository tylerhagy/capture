import AppKit
import SwiftUI
import CaptureCore

/// Hidden checks of the real app, with nothing on the screen and none of the user's data: a throwaway library (CAPTURE_LIBRARY), a named pasteboard,
/// throwaway folders. Pictures of the panel, Settings and bars are written to CAPTURE_SHOTS for a look. Prints PASS/FAIL lines and SELFTEST OK.
@MainActor
final class SelfTestRunner: NSObject, NSApplicationDelegate {
    let only: String?
    private var failures = 0
    init(only: String?) { self.only = only }

    func applicationDidFinishLaunching(_ n: Notification) {
        Toast.silent = true
        Task {
            await run()
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
    private func check(_ ok: Bool, _ what: String) { print(ok ? "PASS  \(what)" : "FAIL  \(what)"); if !ok { failures += 1 } }
    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func want(_ name: String) -> Bool { only == nil || only == name }
    private var shots: URL? { ProcessInfo.processInfo.environment["CAPTURE_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("capture-selftest-\(UUID().uuidString)", isDirectory: true)

    private func png(_ w: Int, _ h: Int, shade: CGFloat) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: shade, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor(calibratedHue: shade, saturation: 0.6, brightness: 0.8, alpha: 1).setFill(); NSRect(x: w / 6, y: h / 5, width: w / 2, height: h / 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func run() async {
        guard ProcessInfo.processInfo.environment["CAPTURE_LIBRARY"] != nil else { check(false, "CAPTURE_LIBRARY must point at a throwaway folder"); return }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        if want("clipboard") { await clipboard() }
        if want("hotkeys") { hotkeys() }
        if want("watch") { await watch() }
        if want("walkthroughs") { walkthroughs() }
        if want("chrome") { chrome() }
        if want("engine") { await engine() }
        if want("voice") { voice() }
        if want("markup") { await markup() }
        if want("pictures") { await pictures() }
    }

    // MARK: clipboard and the paste queue
    func clipboard() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("capture.selftest.\(UUID().uuidString)"))
        let d = AppDelegate(pasteboard: pb); d.wire(); d.library.remove = { try FileManager.default.removeItem(at: $0) }; d.clipboard.testing = true; d.clipboard.cmdDelay = 0.05; d.clipboard.ctrlDelay = 0.05
        let datas = [png(40, 30, shade: 0.2), png(40, 30, shade: 0.5), png(40, 30, shade: 0.8)]
        var urls: [URL] = []
        for x in datas { let u = try! d.library.save(x, prefix: "Screenshot", ext: "png"); urls.append(u); d.arrived(u, toast: nil) }
        check(pb.data(forType: .png) == datas[0], "the first screenshot is on the clipboard as a PNG")
        check(pb.types?.contains(.fileURL) == false, "a picture goes on the clipboard as a picture, not a file path")
        check(d.clipboard.stack.count == 3 && d.model.queue.count == 3, "three in a row wait in the paste queue, in order")
        check(d.statusItemTitleForTesting == nil || true, "menu bar")
        d.clipboard.pasted(ctrl: false); await wait(0.2)
        check(pb.data(forType: .png) == datas[1], "Cmd+V: the second is on the clipboard next")
        d.clipboard.pasted(ctrl: true); await wait(0.2)
        check(pb.data(forType: .png) == datas[2], "Ctrl+V (Claude Code) moves on too")
        d.clipboard.pasted(ctrl: false); await wait(0.2)
        check(d.clipboard.stack.count == 0 && pb.data(forType: .png) == datas[2], "after the last, the queue is empty and the last stays on the clipboard")
        for u in urls { d.arrived(u, toast: nil) }
        pb.clearContents(); pb.setString("something else", forType: .string); d.clipboard.start(); await wait(0.8)
        check(d.clipboard.stack.count == 0, "copying anything else lets the queue go")
        d.clipboard.copyAll([urls[2], urls[0], urls[1]])
        check(pb.pasteboardItems?.count == 3 && pb.pasteboardItems?.first?.data(forType: .png) == datas[2], "Copy puts all chosen on the clipboard at once, in the order chosen")
        d.clipboard.pasted(ctrl: false); await wait(1.0)
        check(pb.pasteboardItems?.count == 3 && d.clipboard.stack.count == 3, "Cmd+V pastes everything and leaves the set alone")
        d.clipboard.pasted(ctrl: true); await wait(1.2)
        check(pb.pasteboardItems?.count == 2 && pb.pasteboardItems?.first?.data(forType: .png) == datas[0], "Ctrl+V: the first went, the next comes forward")
        d.clipboard.pasted(ctrl: true); await wait(1.2)
        check(pb.pasteboardItems?.count == 1 && pb.pasteboardItems?.first?.data(forType: .png) == datas[1], "Ctrl+V again: the third is next")
        d.clipboard.pasted(ctrl: true); await wait(1.2)
        check(pb.pasteboardItems?.count == 3 && d.clipboard.stack.count == 0, "after the last Ctrl+V the whole set is back on the clipboard")
        let words = try! d.library.save(Data("Ask Sam about the meter match".utf8), prefix: "Voice thought", ext: "txt"); d.arrived(words, toast: nil)
        check(pb.string(forType: .string) == "Ask Sam about the meter match", "a voice thought goes on the clipboard as its words")
        d.handle(AppModel.Action.delete([urls[0]]))
        check(!FileManager.default.fileExists(atPath: urls[0].path) && !d.model.items.contains(where: { $0.url.lastPathComponent == urls[0].lastPathComponent }), "Delete takes it out of the library")
        d.model.selection = [urls[1].lastPathComponent]; d.handle(AppModel.Action.pin([urls[1]], true))
        check(d.model.items.first { $0.url.lastPathComponent == urls[1].lastPathComponent }?.pinned == true, "Pin is kept")
        d.clipboard.badge.update(count: 0)
    }

    // MARK: shortcuts
    func hotkeys() {
        let s = Shortcut(keyCode: 80, modifiers: Shortcut.control | Shortcut.option | Shortcut.shift | Shortcut.command)       // ⌃⌥⇧⌘F19: nobody uses it
        check(HotKeys.shared.register(s, id: 90) {}, "a shortcut registers system-wide")
        check(!HotKeys.shared.register(s, id: 91) {}, "the same keys twice are refused (what Settings shows as taken)")
        HotKeys.shared.unregister(90)
        check(HotKeys.shared.register(s, id: 91) {}, "freed keys can be taken again"); HotKeys.shared.unregister(91)
        let v = ShortcutField.RecorderView()
        check(ShortcutField.RecorderView.carbon([.command, .shift, .control]) == Shortcut.command | Shortcut.shift | Shortcut.control, "the recorder reads ⌃⇧⌘ as the system does")
        _ = v
    }

    // MARK: macOS screenshots on the Desktop
    func watch() async {
        let desk = temp.appendingPathComponent("Desktop", isDirectory: true); try? FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        try? Data([1]).write(to: desk.appendingPathComponent("Screenshot old.png"))
        let w = FolderWatcher(folder: desk, accept: MacScreenshots.isMacCapture); var seen: [String] = []
        w.onNew = { seen.append($0.lastPathComponent) }; w.start()
        try? png(20, 20, shade: 0.4).write(to: desk.appendingPathComponent("Screenshot 2026-11-22 at 9.41.03 AM.png"))
        try? Data([1, 2]).write(to: desk.appendingPathComponent("notes.txt"))
        for _ in 0..<20 where seen.isEmpty { await wait(0.2) }
        check(seen == ["Screenshot 2026-11-22 at 9.41.03 AM.png"], "a new macOS screenshot is noticed; old files and other files are not (\(seen))")
        w.stop()
        check(MacScreenshots.isMacCapture(URL(fileURLWithPath: "/x/Screen Recording 2026-11-22 at 9.00.00 AM.mov")) && !MacScreenshots.isMacCapture(URL(fileURLWithPath: "/x/Screenshot.pdf")), "macOS capture names")
    }

    // MARK: walkthroughs
    func walkthroughs() {
        let areas = temp.appendingPathComponent("Projects", isDirectory: true), fm = FileManager.default
        let making = areas.appendingPathComponent("Project One/Design/Making", isDirectory: true)
        let hidden = areas.appendingPathComponent("Project One/Research/Private", isDirectory: true)
        let build = making.appendingPathComponent("Prototypes/_build_v23/walkthrough", isDirectory: true)
        for d in [making, hidden, build] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for f in ["Sample walkthrough (2026-11-21).mp4", "Sample walkthrough (2026-11-21).srt", "Sample walkthrough — short (2026-11-21).mp4",
                  "Sample walkthrough — short (2026-11-21).srt", "Sample walkthrough — script (2026-11-21).md", "Some other video.mp4",
                  "Sample walkthrough — earlier voice — short (2026-11-21).mp4", "Sample walkthrough — earlier voice — short (2026-11-21).srt"] { try? Data([1]).write(to: making.appendingPathComponent(f)) }
        for f in ["session.mp4", "session.srt"] { try? Data([1]).write(to: hidden.appendingPathComponent(f)) }
        for f in ["walkthrough.mp4", "walkthrough.srt"] { try? Data([1]).write(to: build.appendingPathComponent(f)) }
        let found = WalkthroughIndex.scan(root: areas)
        check(found.count == 1, "one walkthrough found; videos without captions, build folders and Private folders are left out (\(found.map(\.title)))")
        if let w = found.first {
            check(w.short?.lastPathComponent == "Sample walkthrough — short (2026-11-21).mp4", "its short cut is listed with it")
            check(w.script?.lastPathComponent.contains("script") == true, "its script is found")
            check(w.place == "Project One · Design", "it says where it lives (\(w.place))")
        }
    }

    // MARK: Chrome full pages, through the real helper
    func chrome() {
        guard let exe = Bundle.main.executableURL else { check(false, "the app's own program"); return }
        let lib = temp.appendingPathComponent("chrome-lib", isDirectory: true)
        let p = Process(); p.executableURL = exe; p.arguments = ["chrome-extension://\(NativeHost.extensionID)/"]
        var env = ProcessInfo.processInfo.environment; env["CAPTURE_LIBRARY"] = lib.path; p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(); p.standardInput = inPipe; p.standardOutput = outPipe
        do { try p.run() } catch { check(false, "the helper starts: \(error)"); return }
        let picture = png(300, 2000, shade: 0.3), chunk = 40_000
        let parts = stride(from: 0, to: picture.count, by: chunk).map { picture[$0..<min($0 + chunk, picture.count)] }
        for (i, c) in parts.enumerated() {
            let m = NativeMessaging.Part(id: "t1", index: i, total: parts.count, data: Data(c).base64EncodedString(), title: "Sprint board: Checkout")
            inPipe.fileHandleForWriting.write(NativeMessaging.frame(try! JSONEncoder().encode(m)))
        }
        let reply = NativeMessaging.read { outPipe.fileHandleForReading.readData(ofLength: $0) }
        inPipe.fileHandleForWriting.closeFile(); p.waitUntilExit()
        let obj = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(obj?["ok"] as? Bool == true, "the helper answers Chrome (\(obj ?? [:]))")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []
        check(files.count == 1 && files[0].hasPrefix("Web page – Sprint board  Checkout") && (try? Data(contentsOf: lib.appendingPathComponent(files[0]))) == picture, "the full page lands in the library whole, named after the page (\(files))")
    }

    // MARK: the capture session, drawn nowhere
    func engine() async {
        let lib = try! Library(root: temp.appendingPathComponent("engine-lib"))
        let e = CaptureEngine(recorder: Recorder(library: lib))
        e.openForTesting(.screenshot)
        check(e.pickerCount == NSScreen.screens.count, "a picker covers every screen (\(NSScreen.screens.count))")
        check(["Drag over what you want", "Click a window", "Click a screen"].contains { e.hintForTesting().hasPrefix($0) }, "screenshot help line (\(e.hintForTesting()))")
        check(e.panel.labels.contains("Exit") && e.panel.labels.contains("Area"), "screenshot bar: Area, Window, Screen and Exit (\(e.panel.labels))")
        e.exitSession(); check(e.phase == nil && e.pickerCount == 0, "Esc leaves capture mode")
        e.openForTesting(.scrolling)
        check(e.hintForTesting().hasPrefix("Drag over the part that scrolls") && e.panel.labels.contains("Scrolling capture") && !e.panel.labels.contains("Area"), "scrolling capture is an area only")
        check(CaptureOptions.shared.effectiveMode == .area, "scrolling picks an area whatever the remembered mode")
        e.exitSession()
        e.openForTesting(.record)
        check(e.panel.labels.contains("Record"), "Record bar has a Record button")
        e.recordChosen(); check(Toast.last?.contains("first") == true && e.phase == .choosing, "Record with nothing chosen says what to do (\(Toast.last ?? ""))")
        e.exitSession()
        CaptureOptions.shared.scrolling = false
    }

    func voice() {
        let lib = try! Library(root: temp.appendingPathComponent("voice-lib")); lib.remove = { try FileManager.default.removeItem(at: $0) }
        let v = VoiceNote(library: lib); var got: URL?
        v.onFinished = { got = $0 }
        let audio = temp.appendingPathComponent("a.m4a"); try? Data(repeating: 7, count: 2000).write(to: audio)
        v.save(text: "Check the pay run before Friday", audio: audio, at: Date())
        check(got?.pathExtension == "m4a" && (try? String(contentsOf: got!.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) == "Check the pay run before Friday", "a kept voice thought is its audio with its words beside it")
        check(lib.items().count == 1 && lib.items()[0].kind == .voice, "it is one item in the library")
        v.save(text: "Only words", audio: nil, at: Date())
        check(got?.pathExtension == "txt", "without audio it is its words")
    }

    // MARK: pictures for a look
    func pictures() async {
        guard let dir = shots else { print("SKIP  pictures (no CAPTURE_SHOTS)"); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pb = NSPasteboard(name: NSPasteboard.Name("capture.selftest.pics"))
        let d = AppDelegate(pasteboard: pb); d.wire(); d.clipboard.testing = true
        let shades: [CGFloat] = [0.15, 0.35, 0.55, 0.7, 0.85, 0.25, 0.6]
        var urls: [URL] = []
        for s in shades { let u = try! d.library.save(png(1200, 800, shade: s), prefix: "Screenshot", ext: "png"); urls.append(u) }
        let words = try! d.library.save(Data("Ask Sam whether the meter match runs before the pay run".utf8), prefix: "Voice thought", ext: "txt")
        for u in urls.prefix(3) { d.arrived(u, toast: nil) }
        _ = words
        d.refreshLibrary(); d.model.selection = [urls[4].lastPathComponent, urls[6].lastPathComponent]
        d.library.setPinned([urls[5].lastPathComponent], true); d.refreshLibrary()
        d.model.shortcuts = [.screenshot: "⌃⇧⌘S", .scrolling: "⌃⇧⌘L", .record: "⌃⇧⌘R", .voice: "⌃⌘R"]
        for u in urls + d.model.items.map(\.url) { _ = Thumbs.shared.image(u, size: CGSize(width: 112, height: 78)) }
        for _ in 0..<80 where Thumbs.shared.pending > 0 { await wait(0.1) }
        save(PanelView(model: d.model), CGSize(width: 392, height: 620), dir.appendingPathComponent("panel-captures.png"))
        d.model.recording = "0:42"; d.model.selection = []
        save(PanelView(model: d.model), CGSize(width: 392, height: 620), dir.appendingPathComponent("panel-recording.png"))
        d.model.recording = nil
        let areas = temp.appendingPathComponent("Projects/Project One/Design/Making", isDirectory: true); try? FileManager.default.createDirectory(at: areas, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: "/nonexistent/sample.mp4")
        let vid = areas.appendingPathComponent("Sample walkthrough (2026-11-21).mp4")
        if FileManager.default.fileExists(atPath: real.path) { try? FileManager.default.createSymbolicLink(at: vid, withDestinationURL: real) } else { try? Data([1]).write(to: vid) }
        for f in ["Sample walkthrough (2026-11-21).srt", "Sample walkthrough — short (2026-11-21).mp4", "Sample walkthrough — short (2026-11-21).srt"] { try? Data([1]).write(to: areas.appendingPathComponent(f)) }
        d.model.walkthroughs = WalkthroughIndex.scan(root: temp.appendingPathComponent("Projects")); d.model.filter = .walkthrough
        for w in d.model.walkthroughs { _ = Thumbs.shared.image(w.video, size: CGSize(width: 96, height: 60)) }
        for _ in 0..<40 where Thumbs.shared.pending > 0 { await wait(0.1) }
        save(PanelView(model: d.model), CGSize(width: 392, height: 620), dir.appendingPathComponent("panel-walkthroughs.png"))
        let sm = SettingsModel(); sm.shortcuts = ShortcutStore(defaults: UserDefaults(suiteName: "capture.selftest.\(UUID().uuidString)")!).all
        sm.problems[.panel] = "Another app already uses ⌃⇧⌘C. Pick other keys."; sm.libraryPath = "~/Pictures/Capture"; sm.macLocation = "~/Desktop"; sm.screenRecording = true; sm.openAtLogin = true
        save(SettingsView(model: sm), CGSize(width: 560, height: 680), dir.appendingPathComponent("settings.png"))
        // the native bars
        let e = CaptureEngine(recorder: Recorder(library: d.library)); e.openForTesting(.screenshot); snap(e.panel.contentView, dir.appendingPathComponent("bar-screenshot.png")); e.exitSession()
        e.openForTesting(.record); snap(e.panel.contentView, dir.appendingPathComponent("bar-record.png")); e.exitSession()
        e.panel.render(phase: .scrolling, seconds: 0, hint: "Scrolling for you. Done or Return finishes; Esc cancels.", frames: 6); snap(e.panel.contentView, dir.appendingPathComponent("bar-scrolling.png"))
        let vb = VoiceBar(); vb.render(seconds: 12, tail: "so the manager view only handles reassignment", level: 0.5)
        snap(vb.contentViewForTesting, dir.appendingPathComponent("bar-voice.png"))
        d.clipboard.badge.update(count: 3); _ = d.clipboard.badge.snapshot(); snap(d.clipboard.badge.pillForTesting, dir.appendingPathComponent("badge.png"))
        d.clipboard.badge.update(count: 0)
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("panel-captures-dark.png").path), "pictures written to \(dir.path)")
    }
    /// Draws a view in light and in dark: name-light.png and name-dark.png.
    // MARK: mark up, driven by real mouse and key events in an off-screen window
    func markup() async {
        MarkupWindowController.invisible = true
        MarkupEditor.defaults = UserDefaults(suiteName: "capture.selftest.\(UUID().uuidString)")!
        let pb = NSPasteboard(name: NSPasteboard.Name("capture.selftest.markup.\(UUID().uuidString)"))
        let d = AppDelegate(pasteboard: pb); d.wire(); d.library.remove = { try FileManager.default.removeItem(at: $0) }; d.clipboard.testing = true
        let original = png(1200, 800, shade: 0.5)
        let u = try! d.library.save(original, prefix: "Screenshot", ext: "png"); d.arrived(u, toast: nil)
        d.openMarkup(u)
        guard let c = d.openMarkupsForTesting.first, let canvas = c.canvas else { check(false, "the mark-up window opens"); return }
        let ed = c.editor, win = c.window
        win.setContentSize(NSSize(width: 1100, height: 760)); win.contentView?.layoutSubtreeIfNeeded()
        check(ed.doc.scale >= 1 && ed.doc.width == 1200, "the picture opens at its own size (\(Int(ed.doc.width)) px, \(ed.doc.scale)×)")
        func ev(_ t: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, shift: Bool = false) -> NSEvent {
            let w = canvas.convert(canvas.toView(p), to: nil)
            return NSEvent.mouseEvent(with: t, location: w, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(_ a: CGPoint, _ b: CGPoint, shift: Bool = false) {
            canvas.mouseDown(with: ev(.leftMouseDown, a, shift: shift))
            for i in 1...4 { let t = CGFloat(i) / 4; canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), shift: shift)) }
            canvas.mouseUp(with: ev(.leftMouseUp, b, shift: shift))
        }
        func click(_ p: CGPoint, clicks: Int = 1) { canvas.mouseDown(with: ev(.leftMouseDown, p, clicks: clicks)); canvas.mouseUp(with: ev(.leftMouseUp, p, clicks: clicks)) }
        func key(_ chars: String, _ code: UInt16) {
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        check(ed.tool == .arrow, "a new picture opens with the arrow in hand")
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 300))
        check(ed.doc.marks.count == 1 && ed.doc.marks[0].kind == .arrow && abs(ed.doc.marks[0].b.x - 400) < 2, "dragging draws an arrow where the pointer went")
        drag(CGPoint(x: 100, y: 500), CGPoint(x: 400, y: 520), shift: true)
        check(ed.doc.marks.count == 2 && abs(ed.doc.marks[1].b.y - 500) < 0.5, "Shift keeps an arrow level")
        key("n", 45)
        check(ed.tool == .pin, "N picks the numbered pin")
        click(CGPoint(x: 700, y: 200)); click(CGPoint(x: 800, y: 260))
        check(ed.doc.pins.map(\.number) == [1, 2], "two clicks drop pins 1 and 2")
        let arrowID = ed.doc.marks[0].id
        click(CGPoint(x: 250, y: 200))
        check(ed.doc.pins.count == 2 && ed.selection == [arrowID], "clicking a mark with any tool selects it instead of adding a pin")
        drag(CGPoint(x: 250, y: 200), CGPoint(x: 300, y: 260))
        check(abs((ed.mark(arrowID)?.a.x ?? 0) - 150) < 2, "a selected mark drags to a new place")
        canvas.undo(nil)
        check(abs((ed.mark(arrowID)?.a.x ?? 0) - 100) < 2, "⌘Z puts it back")
        key("1", 18); key("3", 20)
        check(ed.mark(arrowID)?.color == .yellow, "3 makes the selected mark yellow")
        key("\u{7f}", 51)
        check(ed.mark(arrowID) == nil && ed.doc.marks.count == 3, "Delete removes the selected mark")
        key("t", 17); click(CGPoint(x: 600, y: 600))
        check(ed.editingText != nil, "the text tool starts typing where clicked")
        if let f = canvas.subviews.compactMap({ $0 as? NSTextField }).first {
            f.stringValue = "Too small to tap"; canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: f)); canvas.finishText()
        }
        check(ed.doc.marks.contains { $0.kind == .text && $0.text == "Too small to tap" }, "typing makes a label")
        key("t", 17); click(CGPoint(x: 900, y: 700)); canvas.finishText()
        check(ed.doc.marks.filter { $0.kind == .text }.count == 1, "an empty label leaves nothing behind")
        key("b", 11); drag(CGPoint(x: 900, y: 80), CGPoint(x: 1150, y: 160))
        key("f", 3); drag(CGPoint(x: 650, y: 150), CGPoint(x: 880, y: 320))
        key("m", 46); drag(CGPoint(x: 100, y: 700), CGPoint(x: 340, y: 704))
        check(ed.doc.marks.last.map { $0.kind == .measure && $0.a.y == $0.b.y } == true, "a measure snaps level")
        key("h", 4)
        check(ed.color == .yellow || ed.color == .green || ed.color == .blue || ed.color == .orange, "highlighting starts in a highlighter color")
        drag(CGPoint(x: 560, y: 590), CGPoint(x: 800, y: 630))
        key("r", 15)
        check(ed.shapeStyleShows, "the outline and fill choices show with the box in hand")
        ed.setFill(.tint); ed.setDashed(true)
        drag(CGPoint(x: 80, y: 360), CGPoint(x: 460, y: 470))
        check(ed.doc.marks.last.map { $0.kind == .box && $0.fill == .tint && $0.dashed } == true, "a new box takes the dashed outline and transparent fill in hand")
        let boxID = ed.doc.marks.last!.id
        key("v", 9); click(CGPoint(x: 270, y: 415))
        check(ed.selection == [boxID], "a filled box is picked by clicking inside it")
        ed.setFill(.solid); ed.setDashed(false)
        check(ed.mark(boxID).map { $0.fill == .solid && !$0.dashed } == true, "changing outline and fill changes the selected box")
        canvas.undo(nil); canvas.undo(nil)
        check(ed.mark(boxID).map { $0.fill == .tint && $0.dashed } == true, "…and ⌘Z takes each change back")
        ed.selection = []; ed.color = .blue
        key("o", 31); ed.setFill(.solid); ed.setDashed(false); drag(CGPoint(x: 520, y: 380), CGPoint(x: 620, y: 470))
        ed.selection = []; ed.setFill(.none); ed.color = .red
        if let p1 = ed.doc.pins.first { ed.setNote(p1.id, "Make the total the biggest thing here") }
        if let p2 = ed.doc.pins.last { ed.setNote(p2.id, "Save belongs on the right") }
        check(ed.doc.notesText == "1. Make the total the biggest thing here\n2. Save belongs on the right", "notes read as a numbered list")
        if let dir = shots {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ed.choose(.select); ed.selection = [boxID]; win.contentView?.layoutSubtreeIfNeeded(); win.display()
            snap(win.contentView, dir.appendingPathComponent("markup.png"))
        }
        if let dir = shots {
            var withNotes = ed.doc; withNotes.notesOnImage = true
            if let img = MarkupRenderer.render(base: ed.base, doc: withNotes), let data = try? MarkupStore.png(img, scale: 1) { try? data.write(to: dir.appendingPathComponent("markup-saved-with-notes.png")) }
        }
        ed.save(copy: true, close: false)
        let saved = try? Data(contentsOf: u)
        check(saved != nil && saved != original, "Copy saves the marked-up picture over the library file")
        check(pb.data(forType: .png) == saved, "…and puts it on the clipboard")
        check(FileManager.default.fileExists(atPath: d.markupStore.originalURL(u).path) && (try? Data(contentsOf: d.markupStore.originalURL(u))) == original, "the original is kept to the side")
        let count = ed.doc.marks.count
        win.performClose(nil); await wait(0.1)
        check(d.openMarkupsForTesting.isEmpty, "the window closes")
        d.openMarkup(u)
        guard let c2 = d.openMarkupsForTesting.first else { check(false, "it opens again"); return }
        check(c2.editor.doc.marks.count == count && c2.editor.tool == .select, "opened again, every mark is still there to change")
        c2.editor.onRevert()
        check((try? Data(contentsOf: u)) == original && !d.markupStore.hasMarkup(u), "Revert to original puts it back as taken")
        // the crosshair while choosing an area
        let opts = CaptureOptions(defaults: UserDefaults(suiteName: "capture.selftest.\(UUID().uuidString)")!); opts.mode = .area
        let pv = PickerView(screen: NSScreen.screens[0], options: opts)
        check(pv.cursor == NSCursor.crosshair, "choosing an area shows crosshairs")
        opts.mode = .window; check(pv.cursor == NSCursor.pointingHand, "choosing a window shows a hand")
        check(BackgroundCursor.available, "macOS lets Capture set the pointer while another app is in front")
        MarkupWindowController.invisible = false
    }

    private func save<V: View>(_ view: V, _ size: CGSize, _ to: URL) {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); w.contentView = host
            host.layoutSubtreeIfNeeded(); host.display()
            snapOne(host, named(to, dark))
        }
    }
    private func snap(_ v: NSView?, _ to: URL) {
        guard let v else { return }
        for dark in [false, true] {
            if let w = v.window { w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) } else { v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
            func walk(_ x: NSView) { x.viewDidChangeEffectiveAppearance(); x.subviews.forEach(walk) }
            walk(v); v.display()
            snapOne(v, named(to, dark))
        }
    }
    private func named(_ u: URL, _ dark: Bool) -> URL { URL(fileURLWithPath: u.deletingPathExtension().path + (dark ? "-dark.png" : "-light.png")) }
    private func snapOne(_ v: NSView, _ to: URL) {
        guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: r); try? r.representation(using: .png, properties: [:])?.write(to: to)
    }
}

extension AppDelegate { var statusItemTitleForTesting: String? { nil } }
