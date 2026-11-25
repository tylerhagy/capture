import Foundation

/// Captures waiting to be pasted, oldest first. The first one is what the clipboard holds now.
/// Each paste moves on to the next, so three screenshots paste as three Cmd+V presses, in the order they were taken.
public struct PasteStack: Sendable, Equatable {
    public private(set) var items: [URL] = []
    /// Seconds without a capture or a paste after which the stack is let go. 0 means never.
    public var expiry: TimeInterval
    public private(set) var last: Date = .distantPast

    public init(expiry: TimeInterval = 600) { self.expiry = expiry }

    public var count: Int { items.count }
    public var next: URL? { items.first }

    /// A new capture joins the end. Returns what the clipboard should hold now: the capture itself when nothing else was waiting,
    /// else nil (the clipboard keeps the one that is next).
    public mutating func push(_ u: URL, now: Date = Date()) -> URL? {
        expire(now)
        items.append(u); last = now
        return items.count == 1 ? u : nil
    }
    /// Several at once, in order (chosen in the library). Same return as `push`.
    public mutating func push(contentsOf us: [URL], now: Date = Date()) -> URL? {
        expire(now)
        let wasEmpty = items.isEmpty
        items.append(contentsOf: us); last = now
        return wasEmpty ? items.first : nil
    }
    /// The one on the clipboard was pasted. Returns the next one to put on the clipboard, or nil when the stack is done.
    public mutating func pasted(now: Date = Date()) -> URL? {
        guard !items.isEmpty else { return nil }
        items.removeFirst(); last = now
        return items.first
    }
    /// Take one out (it was deleted). Returns the new first one when the first was taken, so the clipboard can follow.
    public mutating func remove(_ u: URL) -> URL? {
        let wasFirst = items.first == u
        items.removeAll { $0 == u }
        return wasFirst ? items.first : nil
    }
    /// Paste this one next: it moves to the front. Returns it, for the clipboard.
    public mutating func moveToFront(_ u: URL, now: Date = Date()) -> URL? {
        guard let i = items.firstIndex(of: u) else { return nil }
        items.remove(at: i); items.insert(u, at: 0); last = now
        return u
    }
    /// Paste this one next, whether it was waiting or not (a picture just marked up). Returns it, for the clipboard.
    public mutating func pushFront(_ u: URL, now: Date = Date()) -> URL {
        expire(now)
        items.removeAll { $0 == u }; items.insert(u, at: 0); last = now
        return u
    }
    public mutating func clear() { items = [] }
    /// Let go of a stack nobody has touched for a while. Returns whether it was let go.
    @discardableResult
    public mutating func expire(_ now: Date = Date()) -> Bool {
        guard expiry > 0, !items.isEmpty, now.timeIntervalSince(last) > expiry else { return false }
        items = []; return true
    }
}
