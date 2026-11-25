import AppKit
import Carbon.HIToolbox
import CaptureCore

/// System-wide keys through Carbon's hot keys, which need no Accessibility or Input Monitoring permission.
/// Each registration has an id; ids 1–99 are the shortcuts people set, 100 and up are the keys a capture session borrows while it is open (Esc, Return, letters).
final class HotKeys {
    nonisolated(unsafe) static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }; installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DiagLog.write("pressed id \(id)")
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false when the keys are already taken (by another app, or twice here).
    @discardableResult
    func register(_ s: Shortcut, id: UInt32, _ handler: @escaping () -> Void) -> Bool {
        install(); unregister(id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: OSType(0x43505452), id: id), GetApplicationEventTarget(), 0, &ref)
        if id < 100 { DiagLog.write("register \(s.display) id \(id): \(status)") }
        guard status == noErr, let ref else { return false }
        refs[id] = ref; handlers[id] = handler
        return true
    }
    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers[id] = nil
    }
    func unregister(where match: (UInt32) -> Bool) { for id in Array(refs.keys) where match(id) { unregister(id) } }
    func isRegistered(_ id: UInt32) -> Bool { refs[id] != nil }
}

/// A short plain log of shortcut registrations and presses, for working out why a key does nothing: ~/Library/Logs/Capture.log
enum DiagLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Capture.log")
    static func write(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "\(f.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() } else { try? Data(text.utf8).write(to: url) }
    }
}
