import AppKit
import UniformTypeIdentifiers
import SwiftUI
import ServiceManagement
import CaptureCore
import DesignKit

/// Capture lives in the menu bar and opens at login. nothing in the panel quits it (Quit is in Settings, or a right-click on the icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library: Library
    let shortcuts = ShortcutStore()
    let clipboard: Clipboard
    let recorder: Recorder
    let engine: CaptureEngine
    let voice: VoiceNote
    let model = AppModel()
    let settingsModel = SettingsModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var libraryWatcher: FolderWatcher?, macWatcher: FolderWatcher?
    private var tick: Timer?, daily: Timer?, retry: Timer?
    private var registered: [CaptureAction: Bool] = [:]
    private var markups: [URL: MarkupWindowController] = [:]
    var markupStore: MarkupStore { MarkupStore(root: library.root) }

    init(pasteboard: NSPasteboard = .general) {
        library = (try? Library(root: Library.defaultRoot)) ?? (try! Library(root: FileManager.default.temporaryDirectory.appendingPathComponent("Capture")))
        clipboard = Clipboard(pasteboard: pasteboard)
        recorder = Recorder(library: library)
        engine = CaptureEngine(recorder: recorder)
        voice = VoiceNote(library: library)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        DKFonts.register()
        ShortcutRules.macKeysHandedOver = UserDefaults.standard.bool(forKey: "mac.keysHandedOver")
        if ShortcutRules.macKeysHandedOver { MacScreenshots.applyInSession(true) }          // macOS would otherwise answer ⇧⌘3 and ⇧⌘4 too, until a log out
        wire()
        installMenu()
        installStatusItem()
        registerShortcuts()
        clipboard.start()
        startWatchers()
        firstLaunch()
        refreshLibrary()
        cleanup()
        daily = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.cleanup() } }
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.retryTakenShortcuts() } }     // another app (an older copy of this app, say) may let go of them
        retry?.tolerance = 10; daily?.tolerance = 600
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        Task { await recorder.recoverIfAny() }
    }
    func applicationWillTerminate(_ n: Notification) {
        let sem = DispatchSemaphore(value: 0)
        Task { await recorder.stopForQuit(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }

    // MARK: wiring
    func wire() {
        engine.onImage = { [weak self] png, _ in self?.keepImage(png) }
        engine.voiceIsRecording = { [weak self] in self?.voice.recording ?? false }
        engine.onState = { [weak self] in self?.updateStatus() }
        recorder.onFinished = { [weak self] url in let early = self?.recorder.endedOnItsOwn == true; self?.recorder.endedOnItsOwn = false; self?.arrived(url, toast: early ? "Recording stopped on its own. What was recorded is saved and copied" : "Recording saved and copied") }
        voice.onFinished = { [weak self] url in self?.arrived(url, toast: "Voice thought copied") }
        voice.onChange = { [weak self] in self?.updateStatus() }
        clipboard.onChange = { [weak self] in self?.updateQueue() }
        model.act = { [weak self] a in self?.handle(a) }
        settingsModel.act = { [weak self] a in self?.handle(a) }
    }
    private func keepImage(_ png: Data) {
        do {
            let u = try library.save(png, prefix: "Screenshot", ext: "png"); arrived(u, toast: nil)
            if UserDefaults.standard.bool(forKey: "markup.afterScreenshot") { openMarkup(u) }
        }
        catch { Toast.show("Couldn’t save that screenshot") }
    }
    /// Anything new in the library: on the clipboard (or next in the queue), and in the panel.
    func arrived(_ url: URL, toast: String?) {
        libraryWatcher?.ignore(url)
        clipboard.captured(url)
        refreshLibrary()
        if let toast { Toast.show(toast) }
    }

    /// Pictures and recordings dropped on the panel or the menu bar icon: they join the paste queue. Anything else is left alone.
    func addToQueue(_ urls: [URL]) {
        let ok = urls.filter { u in (UTType(filenameExtension: u.pathExtension)).map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false }
        guard !ok.isEmpty else { Toast.show("Drop pictures or recordings"); return }
        clipboard.enqueue(ok); updateQueue()
        Toast.show(ok.count == 1 ? "Added to the paste queue" : "\(ok.count) added to the paste queue")
    }
    /// A picture dragged in without a file (from a web page): kept in the library, then queued.
    func addToQueue(imageData: Data) {
        guard let png = NSBitmapImageRep(data: imageData)?.representation(using: .png, properties: [:]), let u = try? library.save(png, prefix: "Screenshot", ext: "png") else { Toast.show("Couldn’t use that picture"); return }
        arrived(u, toast: "Added to the paste queue")
    }

    // MARK: the menu bar
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self; item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        if let b = item.button { let drop = StatusDropView(frame: b.bounds); drop.onFiles = { [weak self] in self?.addToQueue($0) }; drop.onImage = { [weak self] in self?.addToQueue(imageData: $0) }; b.addSubview(drop) }
        popover.behavior = .transient; popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        updateStatus()
    }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if engine.isRecording { engine.askToStop(); return }             // the red time in the menu bar asks "Stop recording?" first
        if voice.recording { voice.stop(); return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Capture", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem?.menu = m; sender.performClick(nil); statusItem?.menu = nil
            return
        }
        togglePanel()
    }
    func togglePanel() {
        guard let b = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        refreshLibrary(); updateQueue()
        if model.filter == .walkthrough { refreshWalkthroughs() }   // the list may already be showing, so onChange won't fire
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateStatus() {
        let rec = engine.isRecording ? fmt(engine.recordingSeconds) : nil, v = voice.recording ? fmt(voice.seconds) : nil
        model.recording = rec; model.voice = v
        guard let b = statusItem?.button else { return }
        if let t = rec ?? v {
            b.image = NSImage(systemSymbolName: rec != nil ? "record.circle.fill" : "waveform", accessibilityDescription: "Stop")
            b.attributedTitle = NSAttributedString(string: " " + t, attributes: [.foregroundColor: Intent.red, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            b.contentTintColor = Intent.red; b.toolTip = "Click to stop"
        } else {
            b.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture"); b.contentTintColor = nil; b.toolTip = "Capture"
            let n = clipboard.queueEnabled ? clipboard.stack.count : 0
            b.attributedTitle = NSAttributedString(string: n >= 2 ? " \(n)" : "", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        }
        if rec != nil || v != nil { if tick == nil { tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStatus() } } } }
        else { tick?.invalidate(); tick = nil }
    }
    private func fmt(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    func updateQueue() { model.queue = clipboard.stack.items; model.queueEnabled = clipboard.queueEnabled; updateStatus() }
    func refreshLibrary() {
        model.items = library.items()
        model.selection = model.selection.filter { id in model.items.contains { $0.id == id } }
    }
    func refreshWalkthroughs() {
        model.scanningWalkthroughs = true
        Task.detached(priority: .userInitiated) {
            let found = WalkthroughIndex.scan()
            await MainActor.run { self.model.walkthroughs = found; self.model.scanningWalkthroughs = false }
        }
    }

    // MARK: shortcuts
    func registerShortcuts() {
        let all = shortcuts.all
        var labels: [CaptureAction: String] = [:]
        for (i, a) in CaptureAction.allCases.enumerated() {
            let id = UInt32(i + 1)
            HotKeys.shared.unregister(id)
            guard let s = all[a] else { registered[a] = nil; continue }
            labels[a] = s.display
            registered[a] = HotKeys.shared.register(s, id: id) { [weak self] in self?.run(a) }
            if registered[a] == false { NSLog("Capture: %@ (%@) is already taken by another app", a.title, s.display) }
        }
        model.shortcuts = labels
        settingsModel.shortcuts = all
        for a in CaptureAction.allCases where registered[a] == false { settingsModel.problems[a] = "Another app already uses \(all[a]?.display ?? ""). Pick other keys." }
    }
    func retryTakenShortcuts() {
        guard settingsModel.recordingFor == nil, registered.values.contains(false) else { return }
        let before = registered; registerShortcuts()
        for (a, ok) in registered where ok && before[a] == false { settingsModel.problems[a] = nil }
    }
    func run(_ a: CaptureAction) {
        if popover.isShown, a != .panel { popover.performClose(nil) }
        switch a {
        case .screenshot: Task { await engine.begin(.screenshot) }
        case .fullScreen: Task { await engine.screenNow() }
        case .scrolling: Task { await engine.begin(.scrolling) }
        case .record: Task { await engine.begin(.record) }
        case .voice: if engine.phase != nil { Toast.show("Finish capturing first") } else { voice.toggle() }
        case .markup:
            if let u = library.items().first(where: { $0.kind == .screenshot })?.url { openMarkup(u) } else { Toast.show("No screenshots yet") }
        case .panel: togglePanel()
        case .clearStack: clipboard.clear(); Toast.show("Paste queue cleared")
        }
    }

    // MARK: what the panel and Settings ask for
    func handle(_ a: AppModel.Action) {
        switch a {
        case .tool(let t): popover.performClose(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.run(t) }
        case .stopRecording: Task { await engine.stopRecording() }
        case .stopVoice: voice.stop()
        case .settings: popover.performClose(nil); openSettings()
        case .clearQueue: clipboard.clear()
        case .queueFront(let u): clipboard.pasteNext(u)
        case .queueRemove(let u): clipboard.removed(u)
        case .copy(let urls): clipboard.copyAll(urls); popover.performClose(nil); Toast.show(urls.count == 1 ? "Copied" : "\(urls.count) copied")
        case .reveal(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .open(let u): NSWorkspace.shared.open(u)
        case .markup(let u): popover.performClose(nil); openMarkup(u)
        case .pin(let urls, let on): library.setPinned(urls.map(\.lastPathComponent), on); refreshLibrary()
        case .delete(let urls):
            let gone = library.trash(urls); gone.forEach { clipboard.removed($0) }; model.selection = []; refreshLibrary()
            Toast.show(gone.count == 1 ? "Moved to Trash" : "\(gone.count) moved to Trash")
        case .share(let urls): share(urls)
        case .refreshWalkthroughs: refreshWalkthroughs()
        case .enqueue(let urls): addToQueue(urls)
        }
    }
    private func share(_ urls: [URL]) {
        guard let v = popover.contentViewController?.view else { return }
        let p = v.convert(v.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        NSSharingServicePicker(items: urls).show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: v, preferredEdge: .minY)
    }
    func handle(_ a: SettingsModel.Action) {
        switch a {
        case .beginRecording(let ac): settingsModel.recordingFor = ac; settingsModel.problems[ac] = nil; HotKeys.shared.unregister { $0 < 100 }   // so pressing the current keys reaches the field
        case .endRecording: settingsModel.recordingFor = nil; registerShortcuts()
        case .setShortcut(let ac, let s):
            settingsModel.recordingFor = nil
            let p = shortcuts.set(s, for: ac); registerShortcuts()
            if let p { settingsModel.problems[ac] = p } else if registered[ac] == false { settingsModel.problems[ac] = "Another app already uses \(s?.display ?? ""). Pick other keys." } else { settingsModel.problems[ac] = nil }
        case .resetShortcut(let ac): settingsModel.recordingFor = nil; settingsModel.problems[ac] = shortcuts.reset(ac); registerShortcuts()
        case .askInputMonitoring:
            if !CGRequestListenEventAccess() { openPrivacy("Privacy_ListenEvent") }
            refreshPermissions(); clipboard.start()
        case .askAccessibility: if !CGRequestPostEventAccess() { openPrivacy("Privacy_Accessibility") }; refreshPermissions()
        case .askScreenRecording: if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }; refreshPermissions()
        case .routeMac(let on):
            MacScreenshots.route(to: on ? library.root : nil) { [weak self] ok in
                guard let self else { return }
                self.settingsModel.macNote = ok ? nil : "macOS didn’t take the change. Try again."
                self.refreshPermissions(); self.startWatchers()
            }
        case .revealLibrary: NSWorkspace.shared.activateFileViewerSelecting([library.root])
        case .openAtLogin(let on):
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { Toast.show("macOS didn’t change it. Try System Settings ▸ General ▸ Login Items.") }
            refreshPermissions()
        case .macKeys(let on):
            MacScreenshots.handOverKeys(on) { [weak self] ok in
                guard let self else { return }
                guard ok else { self.settingsModel.macNote = "macOS didn’t take the change. Try again."; return }
                UserDefaults.standard.set(on, forKey: "mac.keysHandedOver"); ShortcutRules.macKeysHandedOver = on
                var m: [CaptureAction: Shortcut] = [:]
                for a in CaptureAction.allCases { if let s = on ? a.macStyleShortcut : a.defaultShortcut { m[a] = s } }
                self.shortcuts.setAll(m); self.settingsModel.problems = [:]; self.registerShortcuts(); self.refreshPermissions()
                Toast.show(on ? "⇧⌘3, ⇧⌘4 and ⇧⌘5 now open Capture" : "macOS has its screenshot keys back")
            }
        case .setUpChrome: settingsModel.chromeNote = ChromeSetup.install()
        case .quit: quit()
        case .changed:
            clipboard.setExpiry(seconds: Clipboard.expirySeconds())
            if !((UserDefaults.standard.object(forKey: "stack.enabled") as? Bool) ?? true) { clipboard.watcher.stop(); clipboard.clear() } else { clipboard.start() }
            startWatchers(); cleanup(); updateQueue()
        }
    }
    private func openPrivacy(_ pane: String) { if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) } }
    func refreshPermissions() {
        settingsModel.inputMonitoring = CGPreflightListenEventAccess()
        settingsModel.accessibility = CGPreflightPostEventAccess()
        settingsModel.screenRecording = CGPreflightScreenCaptureAccess()
        let loc = MacScreenshots.location
        settingsModel.macRouted = loc.path == library.root.path
        settingsModel.macLocation = loc.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        settingsModel.libraryPath = library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        settingsModel.openAtLogin = SMAppService.mainApp.status == .enabled
        settingsModel.macKeys = UserDefaults.standard.bool(forKey: "mac.keysHandedOver")
    }

    @objc func openSettings() {
        refreshPermissions(); settingsModel.shortcuts = shortcuts.all
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Capture Settings"; w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel)); w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: folders
    func startWatchers() {
        libraryWatcher?.stop(); macWatcher?.stop()
        // New files in the library from elsewhere: a Chrome full page, or a macOS screenshot when macOS saves into the library.
        let lw = FolderWatcher(folder: library.root) { CaptureKind.of($0) != .file }
        lw.onNew = { [weak self] u in
            guard let self else { return }
            if MacScreenshots.isMacCapture(u) && !((UserDefaults.standard.object(forKey: "watch.native") as? Bool) ?? true) { self.refreshLibrary(); return }
            self.arrived(u, toast: nil)
        }
        lw.start(); libraryWatcher = lw
        let loc = MacScreenshots.location
        guard (UserDefaults.standard.object(forKey: "watch.native") as? Bool) ?? true, loc.path != library.root.path else { return }
        // macOS screenshots elsewhere (the Desktop by default): moved into the library, so the Desktop stays clear, and copied.
        let mw = FolderWatcher(folder: loc, accept: MacScreenshots.isMacCapture)
        mw.onNew = { [weak self] u in
            guard let self else { return }
            let kept = (try? self.library.adopt(u, prefix: nil, move: true)) ?? u
            self.arrived(kept, toast: nil)
        }
        mw.start(); macWatcher = mw
    }
    func cleanup() {
        let days = UserDefaults.standard.integer(forKey: "library.cleanupDays")
        if days > 0 { let gone = library.cleanup(olderThan: days); gone.forEach { clipboard.removed($0) }; if !gone.isEmpty { refreshLibrary() } }
    }

    private func firstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "launchedBefore") else { return }
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        try? SMAppService.mainApp.register()                         // opens at login by default; Settings turns it off
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }        // the one question that makes paste-in-order work
    }

    // MARK: mark up
    /// Opens a picture to mark up, or brings its window forward if it is already open.
    func openMarkup(_ url: URL) {
        guard CaptureKind.of(url) == .screenshot else { NSWorkspace.shared.open(url); return }
        if let c = markups[url] { c.show(); return }
        let store = markupStore
        guard let (base, doc) = store.open(url, fallbackScale: NSScreen.main?.backingScaleFactor ?? 2) else { Toast.show("Couldn’t open that picture"); return }
        let editor = MarkupEditor(file: url, base: base, doc: doc, store: store)
        let c = MarkupWindowController(editor: editor)
        editor.onSave = { [weak self, weak editor] copy, close in
            guard let self, let editor else { return }
            self.saveMarkup(editor, copy: copy)
            if close { c.window.performClose(nil) }
        }
        editor.onRevert = { [weak self, weak c] in
            guard let self, let c else { return }
            do { try store.revert(url) } catch { Toast.show("Couldn’t put the original back"); return }
            c.editor.markSaved(); c.window.close()
            self.pictureChanged(url); Toast.show("Back to the original")
        }
        c.onClosed = { [weak self] in
            guard let self else { return }
            self.markups[url] = nil
            if self.markups.isEmpty, !MarkupWindowController.invisible { NSApp.setActivationPolicy(.accessory) }               // menu bar only again
        }
        markups[url] = c
        if !MarkupWindowController.invisible { NSApp.setActivationPolicy(.regular) }       // a real window: in the Dock and ⌘Tab while it is open
        c.show()
    }
    func saveMarkup(_ editor: MarkupEditor, copy: Bool) {
        do { try editor.store.save(editor.file, base: editor.base, doc: editor.doc) } catch { Toast.show("Couldn’t save the marked-up picture"); return }
        editor.markSaved()
        pictureChanged(editor.file)
        if copy { clipboard.putFirst(editor.file); Toast.show("Copied") }
    }
    /// The file changed in place: new thumbnail, and the clipboard holds the new picture if it held the old one.
    private func pictureChanged(_ url: URL) {
        libraryWatcher?.ignore(url)
        Thumbs.shared.forget(url)
        clipboard.refreshIfShowing(url)
        refreshLibrary(); updateQueue()
    }
    var openMarkupsForTesting: [MarkupWindowController] { Array(markups.values) }

    /// The editor's Edit menu (⌘Z, ⇧⌘Z, ⌘C, ⌘A, ⌘D, ⌘↩). Menu bar apps have none; key equivalents still travel through it.
    private func installMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let m = NSMenu(title: title)
            for (t, sel, key, mods) in items {
                if t == "-" { m.addItem(.separator()); continue }
                let i = m.addItem(withTitle: t, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods
            }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: ""); top.submenu = m; main.addItem(top)
        }
        let noop = #selector(NSResponder.noResponder(for:))
        menu("Capture", [("Settings…", #selector(openSettings), ",", [.command])])
        main.items.first?.submenu?.items.first?.target = self
        menu("File", [("Done", #selector(MarkupWindowController.markupDone(_:)), "\r", [.command]), ("Save", #selector(MarkupWindowController.markupSave(_:)), "s", [.command]),
                      ("-", noop, "", []), ("Close", #selector(NSWindow.performClose(_:)), "w", [.command])])
        menu("Edit", [("Undo", Selector(("undo:")), "z", [.command]), ("Redo", Selector(("redo:")), "z", [.command, .shift]), ("-", noop, "", []),
                      ("Cut", #selector(NSText.cut(_:)), "x", [.command]), ("Copy", #selector(NSText.copy(_:)), "c", [.command]), ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
                      ("Duplicate", #selector(MarkupCanvas.duplicate(_:)), "d", [.command]), ("Delete", #selector(MarkupCanvas.delete(_:)), "", []),
                      ("Select All", #selector(NSText.selectAll(_:)), "a", [.command])])
        NSApp.mainMenu = main
    }

    // MARK: capture:// links (other tools)
    @objc func handleURL(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URL(string: s), let host = u.host else { return }
        switch host {
        case "screenshot": run(.screenshot)
        case "scrolling": run(.scrolling)
        case "record": run(.record)
        case "voice": run(.voice)
        case "markup": run(.markup)                                                        // the latest screenshot
        case "panel", "open": togglePanel()
        case "use-mac-keys": handle(SettingsModel.Action.macKeys(u.query != "off"))           // capture://use-mac-keys or ?off
        case "walkthroughs": model.filter = .walkthrough; refreshWalkthroughs(); if !popover.isShown { togglePanel() }
        default: break
        }
    }
}


/// Lets the menu bar icon take a drop: drag pictures or recordings (from Finder, a browser, Teams) onto it and they join the paste queue.
/// Clicks pass straight through to the icon. The panel itself cannot take drops from other apps, because clicking in another app closes it.
final class StatusDropView: NSView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data) -> Void = { _ in }
    override init(frame: NSRect) { super.init(frame: frame); autoresizingMask = [.width, .height]; registerForDraggedTypes([.fileURL, .png, .tiff]) }
    required init?(coder: NSCoder) { fatalError() }
    private var button: NSStatusBarButton? { superview as? NSStatusBarButton }
    override func mouseDown(with e: NSEvent) { nextResponder?.mouseDown(with: e) }
    override func mouseUp(with e: NSEvent) { nextResponder?.mouseUp(with: e) }
    override func rightMouseDown(with e: NSEvent) { nextResponder?.rightMouseDown(with: e) }
    override func rightMouseUp(with e: NSEvent) { nextResponder?.rightMouseUp(with: e) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { button?.highlight(true); return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { button?.highlight(false) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let pb = s.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { onFiles(urls); return true }
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff) { onImage(d); return true }
        return false
    }
}
