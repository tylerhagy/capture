import SwiftUI
import AppKit

// A field that records a keyboard shortcut, and a gate for a permission an app needs before it can work.

/// Click it, press the keys. Delete clears; Esc keeps what was there. It only reports what was pressed, as a Carbon key code and
/// modifier bits (⌘ 256, ⇧ 512, ⌥ 2048, ⌃ 4096), the way system-wide hot keys are registered. The app decides whether the keys are usable.
/// `text` is what the field shows when it isn't recording ("⌃⌥P"), `placeholder` when it holds nothing.
public struct ShortcutRecorder: View {
    let text: String?
    let placeholder: String
    let onKeys: (_ keyCode: UInt32, _ modifiers: UInt32) -> Void
    let onClear: () -> Void
    @State private var recording = false
    @State private var hover = false

    public init(text: String?, placeholder: String = "Add keys", onKeys: @escaping (UInt32, UInt32) -> Void, onClear: @escaping () -> Void) {
        self.text = text; self.placeholder = placeholder; self.onKeys = onKeys; self.onClear = onClear
    }

    public var body: some View {
        Recorder(recording: $recording, onKeys: { c, m in recording = false; onKeys(c, m) }, onClear: { recording = false; onClear() })
            .overlay {
                Text(recording ? "Press the keys" : (text ?? placeholder))
                    .type(.caption, medium: text != nil && !recording)
                    .foregroundStyle(recording || text == nil ? DK.subtleForeground : DK.foreground)
                    .allowsHitTesting(false)
            }
            .frame(width: 132, height: Control.compact)
            .background(RoundedRectangle(cornerRadius: Radius.base).fill(hover && !recording ? DK.hover : DK.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.base).strokeBorder(recording ? DK.ring : DK.border, lineWidth: recording ? 1 : 1))
            .onHover { hover = $0 }
            .animation(DKMotion.enter(.fast), value: recording)
            .accessibilityLabel(text.map { "Shortcut \($0)" } ?? "Add a shortcut")
            .accessibilityAddTraits(.isButton)
    }

    private struct Recorder: NSViewRepresentable {
        @Binding var recording: Bool
        let onKeys: (UInt32, UInt32) -> Void
        let onClear: () -> Void
        func makeNSView(context: Context) -> RecorderView { RecorderView() }
        func updateNSView(_ v: RecorderView, context: Context) {
            v.onBegin = { recording = true }; v.onCancel = { recording = false }; v.onKeys = onKeys; v.onClear = onClear
            v.recording = recording
            if recording, v.window?.firstResponder !== v { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
        }
    }

    final class RecorderView: NSView {
        var recording = false
        var onBegin: () -> Void = {}, onCancel: () -> Void = {}, onKeys: (UInt32, UInt32) -> Void = { _, _ in }, onClear: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); onBegin() }
        override func resignFirstResponder() -> Bool { if recording { onCancel() }; return true }
        override func keyDown(with e: NSEvent) {
            guard recording else { super.keyDown(with: e); return }
            switch e.keyCode {
            case 53: onCancel()
            case 51, 117: onClear()
            default: onKeys(UInt32(e.keyCode), Self.carbon(e.modifierFlags))
            }
        }
        override func performKeyEquivalent(with e: NSEvent) -> Bool { if recording, e.type == .keyDown { keyDown(with: e); return true }; return super.performKeyEquivalent(with: e) }
        static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if f.contains(.command) { m |= 256 }; if f.contains(.shift) { m |= 512 }
            if f.contains(.option) { m |= 2048 }; if f.contains(.control) { m |= 4096 }
            return m
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// A page shown in place of an app's content until a permission is given: what is needed, why, and the one button that goes to get it.
public struct PermissionGate: View {
    let icon: String, title: String, detail: String, action: String, perform: () -> Void
    public init(icon: String, title: String, detail: String, action: String, perform: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.detail = detail; self.action = action; self.perform = perform
    }
    public var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(DK.mutedForeground)
            Text(title).type(.title, medium: true)
            Text(detail).foregroundStyle(DK.mutedForeground).multilineTextAlignment(.center)
            Button(action, action: perform).buttonStyle(.dk(.primary))
        }
        .padding(Space.s6).frame(maxWidth: .infinity)
    }
}
