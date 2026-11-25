import Foundation

/// What a file in the library is, judged by its extension.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case screenshot, recording, voice, file

    public static func of(_ url: URL) -> CaptureKind {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp": return .screenshot
        case "mp4", "mov", "m4v": return .recording
        case "m4a", "wav", "aac", "mp3", "caf", "txt": return .voice
        default: return .file
        }
    }
    static let audioExtensions = ["m4a", "wav", "aac", "mp3", "caf"]
}

/// One capture in the library folder.
public struct CaptureItem: Identifiable, Hashable, Sendable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let kind: CaptureKind
    public let date: Date
    public let bytes: Int
    public var pinned: Bool
    public init(url: URL, kind: CaptureKind, date: Date, bytes: Int, pinned: Bool) {
        self.url = url; self.kind = kind; self.date = date; self.bytes = bytes; self.pinned = pinned
    }
    public var name: String { url.deletingPathExtension().lastPathComponent }
    /// The words of a voice thought: the item itself when it has no audio, else the .txt beside the audio.
    public var transcriptURL: URL { url.pathExtension.lowercased() == "txt" ? url : url.deletingPathExtension().appendingPathExtension("txt") }
}

/// The library is one ordinary folder (default ~/Pictures/Capture). The folder is the truth: Finder and any other tool can read it.
/// Pins are the only thing kept beside the files, in a hidden `.pins.json`.
public final class Library: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    /// How a file leaves the library. The Trash by default; tests delete outright.
    public var remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public static var defaultRoot: URL {
        if let p = ProcessInfo.processInfo.environment["CAPTURE_LIBRARY"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Capture", isDirectory: true)
    }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: reading
    public func items() -> [CaptureItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let pinned = pins()
        return urls.compactMap { u -> CaptureItem? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            if u.pathExtension.lowercased() == "txt" {                     // the words beside a kept recording are part of that item
                let stem = u.deletingPathExtension()
                if CaptureKind.audioExtensions.contains(where: { fm.fileExists(atPath: stem.appendingPathExtension($0).path) }) { return nil }
            }
            return CaptureItem(url: u, kind: CaptureKind.of(u), date: v.creationDate ?? .distantPast, bytes: v.fileSize ?? 0, pinned: pinned.contains(u.lastPathComponent))
        }
        .sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }
    }

    // MARK: names
    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f.string(from: d)
    }
    /// A free name in the library: never over a file that is there.
    public func uniqueURL(_ base: String, ext: String) -> URL {
        var u = root.appendingPathComponent("\(base).\(ext)"), n = 2
        while fm.fileExists(atPath: u.path) { u = root.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1 }
        return u
    }

    // MARK: writing
    @discardableResult
    public func save(_ data: Data, prefix: String, ext: String, at: Date = Date()) throws -> URL {
        let u = uniqueURL("\(prefix) \(Self.stamp(at))", ext: ext)
        try data.write(to: u, options: .atomic)
        return u
    }
    /// Bring a file in from elsewhere (a recording's temporary file, a macOS screenshot on the Desktop). `prefix` renames it; nil keeps its name.
    @discardableResult
    public func adopt(_ file: URL, prefix: String?, move: Bool, at: Date = Date()) throws -> URL {
        let base = prefix.map { "\($0) \(Self.stamp(at))" } ?? file.deletingPathExtension().lastPathComponent
        let u = uniqueURL(base, ext: file.pathExtension)
        if move { try fm.moveItem(at: file, to: u) } else { try fm.copyItem(at: file, to: u) }
        return u
    }
    public func contains(_ url: URL) -> Bool { url.standardizedFileURL.deletingLastPathComponent().path == root.path }

    // MARK: pins, removal, cleanup
    private var pinsURL: URL { root.appendingPathComponent(".pins.json") }
    public func pins() -> Set<String> { (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: pinsURL))) ?? [] }
    public func setPinned(_ names: [String], _ on: Bool) {
        var p = pins(); for n in names { if on { p.insert(n) } else { p.remove(n) } }
        try? JSONEncoder().encode(p).write(to: pinsURL, options: .atomic)
    }
    /// Removes the files (and a recording's words beside it). Returns what was removed.
    @discardableResult
    public func trash(_ urls: [URL]) -> [URL] {
        var done: [URL] = []
        for u in urls {
            do {
                try remove(u); done.append(u)
                MarkupStore(root: root).forget(u)                                // its original and marks go with it
                let words = u.deletingPathExtension().appendingPathExtension("txt")
                if u.pathExtension.lowercased() != "txt", fm.fileExists(atPath: words.path) { try? remove(words) }
            } catch { continue }
        }
        setPinned(done.map(\.lastPathComponent), false)
        return done
    }
    /// Captures older than `days` go to the Trash, unless pinned. 0 means never.
    @discardableResult
    public func cleanup(olderThan days: Int, now: Date = Date()) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return trash(items().filter { !$0.pinned && $0.date < cutoff }.map(\.url))
    }
}
