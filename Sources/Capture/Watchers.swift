import AppKit
import CaptureCore

/// Notices new files in a folder (a macOS screenshot landing on the Desktop, a Chrome full page landing in the library). A file counts once its size has stopped changing.
@MainActor
final class FolderWatcher {
    let folder: URL
    let accept: (URL) -> Bool
    var onNew: (URL) -> Void = { _ in }
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pending: [String: Int] = [:]
    private var settle: Timer?

    init(folder: URL, accept: @escaping (URL) -> Bool) { self.folder = folder; self.accept = accept }

    func start() {
        known = Set(names())
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { NSLog("Capture: can’t watch \(folder.path)"); return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        s.setCancelHandler { close(fd) }
        s.resume(); source = s
    }
    func stop() { source?.cancel(); source = nil; settle?.invalidate() }
    /// Our own file: never treated as new.
    func ignore(_ url: URL) { known.insert(url.lastPathComponent) }

    private func names() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
    private func scan() {
        let now = Set(names())
        for n in now.subtracting(known) where !n.hasPrefix(".") && accept(folder.appendingPathComponent(n)) { pending[n] = pending[n] ?? -1 }
        known = known.intersection(now).union(now.filter { pending[$0] == nil })
        if !pending.isEmpty, settle == nil { settle = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkPending() } } }
    }
    private func checkPending() {
        for (n, lastSize) in pending {
            let u = folder.appendingPathComponent(n)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) else { pending[n] = nil; known.insert(n); continue }
            if size > 0 && size == lastSize { pending[n] = nil; known.insert(n); onNew(u) } else { pending[n] = size }
        }
        if pending.isEmpty { settle?.invalidate(); settle = nil }
    }
}

/// Where macOS saves ⇧⌘3, ⇧⌘4 and ⇧⌘5 captures, and the switch that sends them into the library.
enum MacScreenshots {
    static var location: URL {
        let raw = (CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String).map { ($0 as NSString).expandingTildeInPath }
        return URL(fileURLWithPath: raw ?? (NSHomeDirectory() + "/Desktop"), isDirectory: true).standardizedFileURL
    }
    static var showsThumbnail: Bool { (CFPreferencesCopyAppValue("show-thumbnail" as CFString, "com.apple.screencapture" as CFString) as? Bool) ?? true }
    /// A file macOS wrote for a screenshot or screen recording (English names).
    static func isMacCapture(_ u: URL) -> Bool {
        let n = u.lastPathComponent
        return (n.hasPrefix("Screenshot ") || n.hasPrefix("Screen Shot ") || n.hasPrefix("Screen Recording ")) && ["png", "jpg", "heic", "tiff", "mov"].contains(u.pathExtension.lowercased())
    }
    /// Send macOS screenshots into the library, with no floating thumbnail (the file lands at once, so it is on the clipboard at once). `back` undoes it.
    static func route(to library: URL?, completion: @escaping (Bool) -> Void) {
        var script = "defaults delete com.apple.screencapture location 2>/dev/null; defaults delete com.apple.screencapture show-thumbnail 2>/dev/null"
        if let library { script = "defaults write com.apple.screencapture location \(shellQuote(library.path)) && defaults write com.apple.screencapture show-thumbnail -bool false" }
        script += "; killall SystemUIServer 2>/dev/null; true"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.terminationHandler = { t in DispatchQueue.main.async { completion(t.terminationStatus == 0) } }
        do { try p.run() } catch { completion(false) }
    }
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension MacScreenshots {
    /// The system's screenshot keys: ⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4, ⇧⌘5.
    static let systemKeyIDs: [Int32] = [28, 29, 30, 31, 184]
    /// Switches the system's own screenshot keys on or off in the running session, at once. Writing the preference alone takes effect only after logging
    /// out, so until then macOS and Capture both answered ⇧⌘3 (two pictures, two shutter sounds). Uses the window server's own call, looked up at run time.
    @discardableResult
    static func applyInSession(_ toCapture: Bool) -> Bool {
        typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) ?? dlopen(nil, RTLD_LAZY),
              let sym = dlsym(h, "CGSSetSymbolicHotKeyEnabled") ?? dlsym(h, "SLSSetSymbolicHotKeyEnabled") else { DiagLog.write("system screenshot keys: call not found"); return false }
        let set = unsafeBitCast(sym, to: SetEnabled.self)
        let results = systemKeyIDs.map { set($0, !toCapture) }
        DiagLog.write("system screenshot keys \(toCapture ? "off" : "on") in this session: \(results)")
        return results.allSatisfy { $0 == 0 }
    }
    /// Turns macOS's own screenshot keys (⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4, ⇧⌘5) off, or back on, so Capture can have them. Same as unticking them in
    /// System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots, applied at once.
    static func handOverKeys(_ toCapture: Bool, completion: @escaping (Bool) -> Void) {
        let keys: [(Int, Int, Int, Int)] = [(28, 51, 20, 1179648), (29, 51, 20, 1441792), (30, 52, 21, 1179648), (31, 52, 21, 1441792), (184, 53, 23, 1179648)]
        var script = keys.map { k in "defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \(k.0) '{ enabled = \(toCapture ? 0 : 1); value = { parameters = (\(k.1), \(k.2), \(k.3)); type = standard; }; }'" }.joined(separator: " && ")
        script += " && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.terminationHandler = { t in DispatchQueue.main.async { applyInSession(toCapture); completion(t.terminationStatus == 0) } }
        do { try p.run() } catch { completion(false) }
    }
}

/// Walkthrough videos: screen-recorded demos you keep in ~/Movies (or the folder in CAPTURE_VIDEO_ROOT); a walkthrough is an .mp4 with captions (.srt) beside it.
/// A short cut ("— short" in its name) is listed with its full cut.
struct Walkthrough: Identifiable, Hashable {
    var id: String { video.path }
    let video: URL
    let captions: URL?
    let script: URL?
    let short: URL?
    let date: Date
    var title: String { video.deletingPathExtension().lastPathComponent }
    /// Where it lives, for the list: the Area and the work it belongs to.
    var place: String {
        let parts = video.deletingLastPathComponent().pathComponents
        guard let i = parts.firstIndex(of: "Projects") else { return video.deletingLastPathComponent().lastPathComponent }
        return parts[(i + 1)...].filter { $0 != "Making" && $0 != "Prototypes" }.prefix(2).joined(separator: " · ")
    }
}

enum WalkthroughIndex {
    static var root: URL {
        if let p = ProcessInfo.processInfo.environment["CAPTURE_VIDEO_ROOT"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Movies", isDirectory: true)
    }
    /// Folders never opened: private folders, build exhaust and dependencies.
    static let skipped: Set<String> = ["Private", "node_modules", ".git", "dry", "frames"]

    static func scan(root: URL = root, limit: Int = 60) -> [Walkthrough] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var videos: [URL] = []
        for case let u as URL in e {
            let n = u.lastPathComponent
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(n) || n.hasPrefix("_build") { e.skipDescendants() }
                continue
            }
            if u.pathExtension.lowercased() == "mp4" { videos.append(u) }
        }
        let withCaptions = videos.filter { fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("srt").path) }
        let shorts = withCaptions.filter { isShort($0) }
        var out: [Walkthrough] = []
        for v in withCaptions where !isShort(v) {
            let dir = v.deletingLastPathComponent(), stem = v.deletingPathExtension().lastPathComponent
            let (name, date) = split(stem)
            let short = shorts.first { s in s.deletingLastPathComponent() == dir && split(s.deletingPathExtension().lastPathComponent).name == name }
            let script = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix(name) && $0.lastPathComponent.contains("script") && (date == nil || $0.lastPathComponent.contains(date!)) }
            let made = (try? v.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            out.append(Walkthrough(video: v, captions: v.deletingPathExtension().appendingPathExtension("srt"), script: script, short: short, date: made))
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }
    static func isShort(_ u: URL) -> Bool { let n = u.deletingPathExtension().lastPathComponent.lowercased(); return n.contains("— short") || n.contains("- short") || n.hasSuffix("short") || n.contains("walkthrough-short") }
    /// "Sample walkthrough (2026-11-21)" → ("Sample walkthrough", "2026-11-21").
    static func split(_ stem: String) -> (name: String, date: String?) {
        guard stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") else { return (stem, nil) }
        let date = String(stem[stem.index(after: open)..<stem.index(before: stem.endIndex)])
        var name = String(stem[..<open]).trimmingCharacters(in: .whitespaces)
        for cut in [" — short", " - short"] where name.hasSuffix(cut) { name = String(name.dropLast(cut.count)) }
        return (name, date)
    }
}
