import SwiftUI
import AppKit
import CaptureCore
import DesignKit

@MainActor
final class SettingsModel: ObservableObject {
    @Published var shortcuts: [CaptureAction: Shortcut] = [:]
    @Published var problems: [CaptureAction: String] = [:]          // why a shortcut was refused, or that another app owns it
    @Published var recordingFor: CaptureAction?
    @Published var inputMonitoring = false
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var macLocation = ""
    @Published var macRouted = false
    @Published var macNote: String?
    @Published var libraryPath = ""
    @Published var openAtLogin = false
    @Published var chromeNote: String?
    @Published var macKeys = false
    var act: (Action) -> Void = { _ in }
    enum Action {
        case setShortcut(CaptureAction, Shortcut?), resetShortcut(CaptureAction), beginRecording(CaptureAction), endRecording
        case askInputMonitoring, askAccessibility, askScreenRecording, routeMac(Bool), macKeys(Bool), revealLibrary, openAtLogin(Bool), setUpChrome, quit, changed
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("stack.enabled") private var stackEnabled = true
    @AppStorage("stack.expirySeconds") private var expiry = Clipboard.expirySeconds()
    @AppStorage("badge.enabled") private var badge = true
    @AppStorage("watch.native") private var watchNative = true
    @AppStorage("capture.stayOpen") private var stayOpen = false
    @AppStorage("markup.afterScreenshot") private var markupAfter = false
    @AppStorage("voice.keepAudio") private var keepAudio = true
    @AppStorage("library.cleanupDays") private var cleanupDays = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Shortcuts") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Use the Mac’s screenshot keys")
                            Text("⇧⌘4 screenshot, ⇧⌘3 whole screen, ⇧⌘5 record, ⇧⌘6 scrolling, ⇧⌘2 voice. macOS’s own screenshot tool steps aside; turning this off gives the keys back.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                        }.layoutPriority(1)
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.macKeys }, set: { model.act(.macKeys($0)) })).labelsHidden().toggleStyle(.dkSwitch)
                    }
                    ForEach(CaptureAction.allCases, id: \.self) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(a.title)
                                Spacer()
                                ShortcutField(text: label(a), recording: model.recordingFor == a,
                                              begin: { model.act(.beginRecording(a)) },
                                              keys: { s in model.act(.setShortcut(a, s)) },
                                              cancel: { model.act(.endRecording) })
                                    .frame(width: 150, height: 28)
                                Pill(title: "Reset", style: .text) { model.act(.resetShortcut(a)) }
                            }
                            if let p = model.problems[a] { Text(p).font(Intent.ui(12)).foregroundStyle(Color.destructive) }
                        }
                    }
                    Text("Click a shortcut, then press the new keys. Delete removes it; Esc keeps the old one.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                }
                section("Clipboard") {
                    toggle("Paste captures in order", $stackEnabled, detail: "Each Cmd+V (or Ctrl+V in Claude Code) pastes the next capture.")
                    permission("Input Monitoring", on: model.inputMonitoring, why: "Lets Capture notice a paste. It never reads what you type.") { model.act(.askInputMonitoring) }
                    HStack {
                        Text("Let the queue go after")
                        Spacer()
                        Picker("", selection: $expiry) {
                            Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("2 minutes").tag(120); Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600); Text("30 minutes").tag(1800); Text("Never").tag(0)
                        }.labelsHidden().frame(width: 140)
                    }
                    toggle("Show the count by the pointer", $badge, detail: "When two or more captures are waiting.")
                }
                section("macOS screenshots") {
                    toggle("Copy ⇧⌘3, ⇧⌘4 and ⇧⌘5 captures too", $watchNative, detail: "They go on the clipboard and into the library.")
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.macRouted ? "Saving into the library" : "Saving to \(model.macLocation)")
                            Text(model.macRouted ? "No floating thumbnail, so they’re copied at once." : "Send them to the library to keep the Desktop clear, with no floating thumbnail.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                            if let n = model.macNote { Text(n).font(Intent.ui(12)).foregroundStyle(Color.muted) }
                        }
                        Spacer()
                        Pill(title: model.macRouted ? "Put back" : "Send to library", style: model.macRouted ? .option : .primary) { model.act(.routeMac(!model.macRouted)) }
                    }
                    Text("To give ⇧⌘4 itself to Capture, turn it off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots, then set it here.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                }
                section("Capturing") {
                    toggle("Stay in capture mode after a screenshot", $stayOpen, detail: "Off: one screenshot, then back to work.")
                    toggle("Mark up each screenshot", $markupAfter, detail: "Opens it to mark up as soon as it is taken. Off: double-click one in the panel, or press the Mark up shortcut.")
                    permission("Screen Recording", on: model.screenRecording, why: "Needed for every screenshot and recording.") { model.act(.askScreenRecording) }
                    permission("Accessibility", on: model.accessibility, why: "Lets a scrolling capture scroll for you. Without it, you scroll by hand.") { model.act(.askAccessibility) }
                    toggle("Keep the audio with voice thoughts", $keepAudio, detail: "The words are always kept.")
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Chrome full pages")
                            Text(model.chromeNote ?? "An exact full-page picture from a Chrome button, into the library and the clipboard.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                        }
                        Spacer()
                        Pill(title: "Set up", style: .option) { model.act(.setUpChrome) }
                    }
                }
                section("Library") {
                    HStack {
                        Text(model.libraryPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Pill(title: "Show in Finder", style: .option) { model.act(.revealLibrary) }
                    }
                    HStack {
                        Text("Move to Trash after")
                        Spacer()
                        Picker("", selection: $cleanupDays) { Text("Never").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.labelsHidden().frame(width: 140)
                    }
                    Text("Pinned captures are always kept.").font(Intent.ui(12)).foregroundStyle(Color.muted)
                }
                section("General") {
                    HStack {
                        Text("Open at login")
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { model.act(.openAtLogin($0)) })).labelsHidden().toggleStyle(.dkSwitch)
                    }
                    HStack { Spacer(); Pill(title: "Quit Capture", style: .destructive) { model.act(.quit) } }
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 680)
        .background(DK.background)
        .font(Intent.ui(13))
        .foregroundStyle(Color.ink)
        .onChange(of: stackEnabled) { model.act(.changed) }
        .onChange(of: expiry) { model.act(.changed) }
        .onChange(of: badge) { model.act(.changed) }
        .onChange(of: watchNative) { model.act(.changed) }
        .onChange(of: cleanupDays) { model.act(.changed) }
    }

    private func label(_ a: CaptureAction) -> String { model.recordingFor == a ? "Press keys…" : (model.shortcuts[a]?.display ?? "None") }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Intent.ui(15, .semibold))
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Intent.frame).fill(Color.surface))
        }
    }
    private func toggle(_ title: String, _ b: Binding<Bool>, detail: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(Intent.ui(12)).foregroundStyle(Color.muted) }.layoutPriority(1)
            Spacer()
            Toggle("", isOn: b).labelsHidden().toggleStyle(.dkSwitch)
        }
    }
    private func permission(_ name: String, on: Bool, why: String, ask: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: on ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(on ? Color.ink : Color.destructive)
            VStack(alignment: .leading, spacing: 3) { Text("\(name): \(on ? "allowed" : "not allowed")"); Text(why).font(Intent.ui(12)).foregroundStyle(Color.muted) }
            Spacer()
            if !on { Pill(title: "Allow", style: .option, action: ask) }
        }
    }
}

/// A field that records a shortcut: click it, press keys. Delete clears it; Esc keeps the old one.
struct ShortcutField: NSViewRepresentable {
    let text: String; let recording: Bool
    let begin: () -> Void; let keys: (Shortcut?) -> Void; let cancel: () -> Void
    func makeNSView(context: Context) -> RecorderView { let v = RecorderView(); update(v); return v }
    func updateNSView(_ v: RecorderView, context: Context) { update(v) }
    private func update(_ v: RecorderView) {
        v.text = text; v.recording = recording; v.onBegin = begin; v.onKeys = keys; v.onCancel = cancel; v.needsDisplay = true
        if recording, v.window?.firstResponder !== v { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }

    final class RecorderView: NSView {
        var text = "", recording = false
        var onBegin: () -> Void = {}, onKeys: (Shortcut?) -> Void = { _ in }, onCancel: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); onBegin() }
        override func resignFirstResponder() -> Bool { if recording { onCancel() }; return true }
        override func keyDown(with e: NSEvent) {
            guard recording else { super.keyDown(with: e); return }
            switch e.keyCode {
            case 53: onCancel()                                        // Esc keeps the old one
            case 51, 117: onKeys(nil)                                  // Delete clears it
            default: onKeys(Shortcut(keyCode: UInt32(e.keyCode), modifiers: Self.carbon(e.modifierFlags)))
            }
        }
        override func performKeyEquivalent(with e: NSEvent) -> Bool { if recording, e.type == .keyDown { keyDown(with: e); return true }; return super.performKeyEquivalent(with: e) }
        static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if f.contains(.command) { m |= Shortcut.command }; if f.contains(.shift) { m |= Shortcut.shift }
            if f.contains(.option) { m |= Shortcut.option }; if f.contains(.control) { m |= Shortcut.control }
            return m
        }
        override func draw(_ dirty: NSRect) {
            let r = bounds.insetBy(dx: 1, dy: 1), p = NSBezierPath(roundedRect: r, xRadius: Intent.radius, yRadius: Intent.radius)
            Intent.background.setFill(); p.fill()
            (recording ? Intent.ink : Intent.hairline).setStroke(); p.lineWidth = recording ? 2 : 1; p.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: Intent.font(13, recording ? .regular : .semibold), .foregroundColor: recording ? Intent.muted : Intent.ink]
            let s = text as NSString, size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
