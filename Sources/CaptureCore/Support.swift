import Foundation
import CoreGraphics

/// Joins what the speech recogniser says into one transcript.
/// The recogniser re-sends the whole text so far, may start over after a pause, and a new request starts about every 50 seconds.
public struct TranscriptAssembler: Equatable, Sendable {
    private var done: [String] = []
    private var live = ""
    public init() {}
    public mutating func beginRequest() { settle() }
    public mutating func update(_ text: String, isFinal: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !live.isEmpty && t.count * 10 < live.count * 6 { done.append(live) }
        live = t
        if isFinal { settle() }
    }
    public var text: String { (done + (live.isEmpty ? [] : [live])).joined(separator: " ") }
    public var isEmpty: Bool { done.isEmpty && live.isEmpty }
    public var tail: String { live.isEmpty ? (done.last ?? "") : live }
    private mutating func settle() { if !live.isEmpty { done.append(live); live = "" } }
}

/// What was dragged on the picker, turned into the system's terms.
public enum CaptureGeometry {
    /// Where a window (top-left system coordinates) sits inside one screen's picker (bottom-left). Nil when too little of it is on that screen.
    public static func windowRect(windowFrame w: CGRect, screenFrame s: CGRect, primaryHeight: CGFloat) -> CGRect? {
        let screenTopDown = primaryHeight - s.maxY
        let r = CGRect(x: w.minX - s.minX, y: s.height - ((w.minY - screenTopDown) + w.height), width: w.width, height: w.height)
        let inter = r.intersection(CGRect(origin: .zero, size: s.size))
        return inter.isNull || inter.width < 20 || inter.height < 20 ? nil : inter
    }
    /// The same area as the system measures it for a capture: points from the top-left of the display.
    public static func sourceRect(selection: CGRect, viewHeight: CGFloat) -> CGRect {
        CGRect(x: selection.minX, y: viewHeight - selection.maxY, width: selection.width, height: selection.height)
    }
}

/// Chrome's native messaging: each message is a 4-byte length (native byte order) and then JSON.
/// The Capture extension sends a full-page picture in parts; the parts are put back together here.
public enum NativeMessaging {
    public static func frame(_ json: Data) -> Data {
        var n = UInt32(json.count)
        return Data(bytes: &n, count: 4) + json
    }
    /// Reads one message, or nil at the end of input.
    public static func read(_ next: (Int) -> Data) -> Data? {
        let len = next(4)
        guard len.count == 4 else { return nil }
        let n = len.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard n > 0, n < 128 * 1024 * 1024 else { return nil }
        let body = next(Int(n))
        return body.count == Int(n) ? body : nil
    }

    public struct Part: Codable, Sendable {
        public var type: String          // "page"
        public var id: String
        public var index: Int
        public var total: Int
        public var data: String          // base64 of this part of the PNG
        public var title: String?
        public init(type: String = "page", id: String, index: Int, total: Int, data: String, title: String?) {
            self.type = type; self.id = id; self.index = index; self.total = total; self.data = data; self.title = title
        }
    }
    /// Collects the parts of one picture. `complete` is the whole PNG once every part has arrived.
    public struct Assembly: Sendable {
        public private(set) var parts: [Int: Data] = [:]
        public private(set) var total = 0
        public private(set) var title: String?
        public init() {}
        public mutating func add(_ p: Part) -> Bool {
            guard let d = Data(base64Encoded: p.data), p.index >= 0, p.total > 0, p.index < p.total else { return false }
            total = p.total; parts[p.index] = d; if title == nil { title = p.title }
            return true
        }
        public var complete: Data? {
            guard total > 0, parts.count == total else { return nil }
            return (0..<total).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
        }
    }
    /// A safe file name from a page title.
    public static func fileName(title: String?) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let t = (title ?? "").components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let short = String(t.prefix(60)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Web page" : "Web page – \(short)"
    }
}
