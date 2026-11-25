import Foundation

/// A key with its modifiers, in the system's hot key terms (Carbon key codes and modifier bits).
public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public static let command: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + KeyNames.name(keyCode)
    }
    /// Has ⌘, ⌃ or ⌥, so it never fires while typing.
    public var isSafe: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 || KeyNames.isFunctionKey(keyCode) }
}

/// What a shortcut can do.
public enum CaptureAction: String, CaseIterable, Codable, Sendable {
    case screenshot, fullScreen, scrolling, record, voice, markup, panel, clearStack

    public var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .fullScreen: return "Whole screen"
        case .scrolling: return "Scrolling capture"
        case .record: return "Record screen"
        case .voice: return "Voice thought"
        case .markup: return "Mark up latest screenshot"
        case .panel: return "Open Capture"
        case .clearStack: return "Clear paste queue"
        }
    }
    /// The classic markup shortcuts stay the same; the new tools get free neighbors.
    public var defaultShortcut: Shortcut? {
        let csc = Shortcut.control | Shortcut.shift | Shortcut.command
        switch self {
        case .screenshot: return Shortcut(keyCode: KeyNames.s, modifiers: csc)
        case .record: return Shortcut(keyCode: KeyNames.r, modifiers: csc)
        case .voice: return Shortcut(keyCode: KeyNames.r, modifiers: Shortcut.control | Shortcut.command)
        case .scrolling: return Shortcut(keyCode: KeyNames.l, modifiers: csc)
        case .panel: return Shortcut(keyCode: KeyNames.c, modifiers: csc)
        case .markup: return Shortcut(keyCode: KeyNames.m, modifiers: csc)
        case .fullScreen, .clearStack: return nil
        }
    }
    /// With the Mac's own screenshot keys handed to Capture: the same keys do the same jobs, plus the neighbors for the rest.
    public var macStyleShortcut: Shortcut? {
        let cs = Shortcut.command | Shortcut.shift
        switch self {
        case .fullScreen: return Shortcut(keyCode: KeyNames.three, modifiers: cs)
        case .screenshot: return Shortcut(keyCode: KeyNames.four, modifiers: cs)
        case .record: return Shortcut(keyCode: KeyNames.five, modifiers: cs)
        case .scrolling: return Shortcut(keyCode: KeyNames.six, modifiers: cs)
        case .voice: return Shortcut(keyCode: 19, modifiers: cs)                // ⇧⌘2
        case .panel, .markup: return defaultShortcut
        case .clearStack: return nil
        }
    }
}

/// Checks a new shortcut before it is kept. Returns a plain sentence when it can't be used, else nil.
public enum ShortcutRules {
    static let cs = Shortcut.command | Shortcut.shift
    /// True once macOS's own ⇧⌘3, ⇧⌘4, ⇧⌘5 and ⇧⌘6 are switched off and handed to Capture.
    nonisolated(unsafe) public static var macKeysHandedOver = false
    static let macKeys: Set<UInt32> = [KeyNames.three, KeyNames.four, KeyNames.five, KeyNames.six]
    public static let reserved: [Shortcut: String] = [
        Shortcut(keyCode: KeyNames.three, modifiers: cs): "macOS screenshots",
        Shortcut(keyCode: KeyNames.four, modifiers: cs): "macOS screenshots",
        Shortcut(keyCode: KeyNames.five, modifiers: cs): "macOS screenshots",
        Shortcut(keyCode: KeyNames.six, modifiers: cs): "macOS screenshots",
        Shortcut(keyCode: KeyNames.q, modifiers: Shortcut.command): "Quit",
        Shortcut(keyCode: KeyNames.c, modifiers: Shortcut.command): "Copy",
        Shortcut(keyCode: KeyNames.v, modifiers: Shortcut.command): "Paste",
        Shortcut(keyCode: KeyNames.x, modifiers: Shortcut.command): "Cut",
        Shortcut(keyCode: KeyNames.space, modifiers: Shortcut.command): "Spotlight",
        Shortcut(keyCode: KeyNames.tab, modifiers: Shortcut.command): "switching apps",
    ]
    public static func problem(_ s: Shortcut, for action: CaptureAction, current: [CaptureAction: Shortcut]) -> String? {
        if !s.isSafe { return "Add ⌘, ⌃ or ⌥, so it doesn’t fire while you type." }
        if let r = reserved[s], !(macKeysHandedOver && s.modifiers == cs && macKeys.contains(s.keyCode)) { return "\(s.display) is used by \(r)." }
        if let other = current.first(where: { $0.key != action && $0.value == s }) { return "\(s.display) is already used for \(other.key.title)." }
        return nil
    }
}

/// The shortcuts in use, kept in UserDefaults. An action can have none.
public final class ShortcutStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "shortcuts.v1"
    private struct Saved: Codable { var keys: [String: Shortcut]; var none: [String] }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var all: [CaptureAction: Shortcut] {
        let saved = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var out: [CaptureAction: Shortcut] = [:]
        for a in CaptureAction.allCases {
            if let s = saved?.keys[a.rawValue] { out[a] = s }
            else if saved?.none.contains(a.rawValue) == true { continue }
            else if let d = a.defaultShortcut { out[a] = d }
        }
        return out
    }
    public func shortcut(_ a: CaptureAction) -> Shortcut? { all[a] }

    /// Keep a new shortcut (nil clears it). Returns the problem instead when it can't be used; nothing changes then.
    @discardableResult
    public func set(_ s: Shortcut?, for a: CaptureAction) -> String? {
        var current = all
        if let s, let p = ShortcutRules.problem(s, for: a, current: current) { return p }
        current[a] = s
        write(current)
        return nil
    }
    public func reset(_ a: CaptureAction) -> String? { set(ShortcutRules.macKeysHandedOver ? a.macStyleShortcut : a.defaultShortcut, for: a) }
    /// All at once (handing the Mac's keys over, or back). No checks between them, since they change together.
    public func setAll(_ m: [CaptureAction: Shortcut]) { write(m) }

    private func write(_ m: [CaptureAction: Shortcut]) {
        let keys = Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) })
        let none = CaptureAction.allCases.filter { m[$0] == nil }.map(\.rawValue)
        if let d = try? JSONEncoder().encode(Saved(keys: keys, none: none)) { defaults.set(d, forKey: key) }
    }
}

/// Names of keys by their key code (US layout, as printed on the key).
public enum KeyNames {
    public static let a: UInt32 = 0, s: UInt32 = 1, c: UInt32 = 8, v: UInt32 = 9, x: UInt32 = 7, q: UInt32 = 12, r: UInt32 = 15, l: UInt32 = 37, m: UInt32 = 46
    public static let three: UInt32 = 20, four: UInt32 = 21, five: UInt32 = 23, six: UInt32 = 22, space: UInt32 = 49, tab: UInt32 = 48
    static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 64: "F17", 79: "F18", 80: "F19", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    public static func name(_ code: UInt32) -> String { table[code] ?? "Key \(code)" }
    public static func isFunctionKey(_ code: UInt32) -> Bool { name(code).hasPrefix("F") && name(code).count > 1 }
}
