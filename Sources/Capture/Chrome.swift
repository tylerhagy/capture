import Foundation
import CaptureCore

/// Chrome's side of a full-page capture. Chrome starts this same program with the extension's address as its argument; it reads the picture's parts,
/// writes the PNG into the library, and the running app notices the new file (clipboard, paste queue, panel). No window, no menu bar.
enum NativeHost {
    static let name = "com.tylerhagy.capture"
    /// Fixed by the "key" in chrome-extension/manifest.json, so the address never changes.
    static let extensionID = "oeanhbighikjnffcahfhoagdnbohcoio"

    static func isLaunchedByChrome(_ args: [String]) -> Bool { args.dropFirst().contains { $0.hasPrefix("chrome-extension://") } }

    static func run(library: Library? = nil, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) -> Int32 {
        guard let lib = library ?? (try? Library(root: Library.defaultRoot)) else { return 1 }
        var parts: [String: NativeMessaging.Assembly] = [:]
        while let msg = NativeMessaging.read({ input.readData(ofLength: $0) }) {
            guard let p = try? JSONDecoder().decode(NativeMessaging.Part.self, from: msg) else { reply(output, ["ok": false, "error": "unreadable"]); continue }
            var a = parts[p.id] ?? NativeMessaging.Assembly()
            guard a.add(p) else { reply(output, ["ok": false, "error": "bad part"]); continue }
            parts[p.id] = a
            guard let png = a.complete else { continue }
            parts[p.id] = nil
            do { let u = try lib.save(png, prefix: NativeMessaging.fileName(title: a.title), ext: "png"); reply(output, ["ok": true, "file": u.lastPathComponent]) }
            catch { reply(output, ["ok": false, "error": "could not save"]) }
        }
        return 0
    }
    private static func reply(_ out: FileHandle, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        out.write(NativeMessaging.frame(d))
    }
}

/// Settings ▸ Chrome full pages ▸ Set up: tells Chrome where the helper is, then shows the extension folder to load.
enum ChromeSetup {
    static func install() -> String {
        let fm = FileManager.default
        guard let exe = Bundle.main.executableURL?.path else { return "Couldn’t find Capture itself." }
        let manifest: [String: Any] = ["name": NativeHost.name, "description": "Capture full pages", "path": exe, "type": "stdio",
                                       "allowed_origins": ["chrome-extension://\(NativeHost.extensionID)/"]]
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("\(NativeHost.name).json"))
        } catch { return "Couldn’t tell Chrome about Capture. Is Chrome installed?" }
        let ext = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension")
        if let ext, fm.fileExists(atPath: ext.path) {
            let shared = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Capture/chrome-extension", isDirectory: true)
            try? fm.removeItem(at: shared); try? fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true); try? fm.copyItem(at: ext, to: shared)
            NSWorkspaceOpen.reveal(shared)
            return "Ready. In Chrome open chrome://extensions, turn on Developer mode, choose Load unpacked and pick the folder just shown. If Chrome refuses, your company has blocked it."
        }
        return "Chrome knows about Capture. The extension folder is missing from this build."
    }
}

import AppKit
enum NSWorkspaceOpen { static func reveal(_ u: URL) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
