import AppKit
import SwiftUI
import CaptureCore
import DesignKit

/// The mark-up window: tools across the top, the picture, and the pins' notes at the side once there are pins.
struct MarkupView: View {
    @ObservedObject var editor: MarkupEditor
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.hairline)
            HStack(spacing: 0) {
                CanvasHost(editor: editor).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface)
                if !editor.doc.pins.isEmpty {
                    Divider().overlay(Color.hairline)
                    NotesList(editor: editor).frame(width: 268)
                }
            }
        }
        .background(Color.panel)
        .font(Intent.ui(13))
        .foregroundStyle(Color.ink)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarkupTool.allCases) { t in
                    ToolButton(tool: t, on: editor.tool == t) { editor.choose(t) }
                    if t == .select || t == .measure { Rectangle().fill(Color.hairline).frame(width: 1, height: 18).padding(.horizontal, 4) }
                }
            }
            Rectangle().fill(Color.hairline).frame(width: 1, height: 22)
            HStack(spacing: 5) {
                ForEach(Array(MarkColor.allCases.enumerated()), id: \.element) { i, c in
                    Swatch(color: c, on: editor.shownColor == c, dimmed: !styleApplies) { editor.setColor(c) }.help("\(c.title) (\(i + 1))")
                }
            }
            HStack(spacing: 2) {
                ForEach(MarkSize.allCases, id: \.self) { s in
                    SizeButton(size: s, on: editor.shownSize == s) { editor.setSize(s) }.help("\(s.title) ([ and ])")
                }
            }
            if editor.shapeStyleShows {
                Rectangle().fill(Color.hairline).frame(width: 1, height: 22)
                HStack(spacing: 2) {
                    ShapeStyleButton(glyph: .outline(dashed: false), on: !editor.shownDashed, tint: editor.shownColor) { editor.setDashed(false) }.help("Solid outline")
                    ShapeStyleButton(glyph: .outline(dashed: true), on: editor.shownDashed, tint: editor.shownColor) { editor.setDashed(true) }.help("Dashed outline")
                }
                HStack(spacing: 2) {
                    ForEach(MarkFill.allCases, id: \.self) { f in
                        ShapeStyleButton(glyph: .fill(f), on: editor.shownFill == f, tint: editor.shownColor) { editor.setFill(f) }.help(f.title)
                    }
                }
            }
            Spacer(minLength: 8)
            if editor.tool == .crop && editor.doc.crop != nil { Pill(title: "Remove crop", style: .text) { editor.checkpoint(); editor.doc.crop = nil } }
            if editor.wasMarkedUp { Pill(title: "Revert to original", style: .text) { editor.onRevert() }.help("Puts the picture back as it was taken and removes every mark") }
            Pill(title: "Copy", symbol: "doc.on.doc", style: .option) { editor.save(copy: true, close: false) }.help("Saves and copies (⌘C)")
            Pill(title: "Done", style: .primary) { editor.save(copy: true, close: true) }.help("Saves, copies, and closes (⌘↩)")
        }
        .padding(.horizontal, 12).frame(height: 46)
    }
    private var styleApplies: Bool {
        if !editor.selection.isEmpty { return editor.selectedMarks.contains { $0.kind != .redact && $0.kind != .focus } }
        return editor.tool.usesColor || editor.tool == .select
    }
}

private struct ToolButton: View {
    let tool: MarkupTool; let on: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol).font(.system(size: 14, weight: on ? .semibold : .regular))
                .frame(width: 30, height: 28)
                .foregroundStyle(on ? Color.inverseText : Color.ink)
                .background(RoundedRectangle(cornerRadius: Intent.radius).fill(on ? Color.inverse : (hover ? Color.wash : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(tool.tip).accessibilityLabel(tool.title)
    }
}

private struct Swatch: View {
    let color: MarkColor; let on: Bool; let dimmed: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(Color(cgColor: color.cg())).frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.panel, lineWidth: on ? 2 : 0).padding(on ? 0 : 0))
                .padding(3)
                .overlay(Circle().stroke(on ? Color.ink : Color.hairline, lineWidth: on ? 2 : 1))
                .opacity(dimmed ? 0.45 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(color.title)
    }
}

private struct SizeButton: View {
    let size: MarkSize; let on: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Capsule().fill(Color.ink).frame(width: 16, height: [1.5, 3.0, 5.0][size.rawValue - 1])
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Intent.radius).fill(on ? Color.wash : (hover ? Color.wash.opacity(0.5) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: Intent.radius).stroke(on ? Color.ink.opacity(0.5) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel(size.title)
    }
}

/// A small picture of an outline or a fill, in the color in hand, so each choice shows what it makes.
private struct ShapeStyleButton: View {
    enum Glyph { case outline(dashed: Bool), fill(MarkFill) }
    let glyph: Glyph; let on: Bool; let tint: MarkColor; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            face.frame(width: 15, height: 15)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Intent.radius).fill(on ? Color.wash : (hover ? Color.wash.opacity(0.5) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: Intent.radius).stroke(on ? Color.ink.opacity(0.5) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
    @ViewBuilder private var face: some View {
        let c = Color(cgColor: tint.cg())
        switch glyph {
        case .outline(let dashed):
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 1.6, dash: dashed ? [3, 2.2] : []))
        case .fill(let f):
            ZStack {
                if f != .none { RoundedRectangle(cornerRadius: 2.5).fill(c.opacity(Double(f.alpha))) }
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(f == .solid ? c : Color.ink, lineWidth: 1.6)
                if f == .none { Path { p in p.move(to: CGPoint(x: 2, y: 13)); p.addLine(to: CGPoint(x: 13, y: 2)) }.stroke(Color.muted, lineWidth: 1.2) }
            }
        }
    }
}

/// The pins in order, each with its note. Typing here is the same as typing on the picture: the note travels with the pin.
private struct NotesList: View {
    @ObservedObject var editor: MarkupEditor
    @FocusState private var focused: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(Intent.ui(13, .semibold))
                Spacer()
                Pill(title: "Copy notes", style: .text) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editor.doc.notesText, forType: .string); Toast.show("Notes copied")
                }
                .help("Copies the notes as a numbered list, for Jira or Teams")
            }
            .padding(.horizontal, 14).frame(height: 40)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(editor.doc.pins) { pin in row(pin).id(pin.id) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onReceive(NotificationCenter.default.publisher(for: .markupFocusNote)) { n in
                    guard let id = n.object as? UUID else { return }
                    focused = id; withAnimation { proxy.scrollTo(id) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .markupPinAdded)) { n in
                    guard let id = n.object as? UUID else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            Divider().overlay(Color.hairline)
            HStack {
                Text("Print notes under the picture").font(Intent.ui(12))
                Spacer()
                Toggle("", isOn: Binding(get: { editor.doc.notesOnImage }, set: { editor.setNotesOnImage($0) })).labelsHidden().toggleStyle(.dkSwitch)
            }
            .padding(.horizontal, 14).frame(height: 44)
        }
        .onChange(of: focused) { id in
            if let id { editor.noteBegan(id) } else { editor.activeNote = nil }
        }
    }
    private func row(_ pin: Mark) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(pin.number)").font(Intent.ui(11, .medium)).foregroundStyle(Color(cgColor: pin.color.textOn))
                .frame(width: 20, height: 20).background(Circle().fill(Color(cgColor: pin.color.cg()))).padding(.top, 4)
            TextField("Add a note", text: Binding(get: { editor.mark(pin.id)?.text ?? "" }, set: { editor.setNote(pin.id, $0) }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).padding(.vertical, 5)
                .focused($focused, equals: pin.id)
            Button { editor.remove(pin.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.muted).frame(width: 20, height: 20) }
                .buttonStyle(.plain).help("Remove pin \(pin.number)").padding(.top, 4)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Intent.radius).fill(editor.selection.contains(pin.id) || focused == pin.id ? Color.wash : .clear))
        .contentShape(Rectangle())
        .onTapGesture { focused = pin.id }
    }
}

private struct CanvasHost: NSViewRepresentable {
    @ObservedObject var editor: MarkupEditor
    func makeNSView(context: Context) -> MarkupCanvas { MarkupCanvas(editor: editor) }
    func updateNSView(_ v: MarkupCanvas, context: Context) { v.needsDisplay = true }
}

/// One mark-up window per picture. Closing saves (the original is always kept, so nothing is lost); Done also copies.
@MainActor
final class MarkupWindowController: NSObject, NSWindowDelegate {
    let editor: MarkupEditor
    let window: NSWindow
    var onClosed: () -> Void = {}

    init(editor: MarkupEditor) {
        self.editor = editor
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let pts = CGSize(width: editor.doc.width / editor.doc.scale, height: editor.doc.height / editor.doc.scale)
        let side: CGFloat = editor.doc.pins.isEmpty ? 0 : 268
        let w = min(max(pts.width + 56 + side, 1000), screen.width * 0.9), h = min(max(pts.height + 56 + 46, 520), screen.height * 0.9)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = editor.file.deletingPathExtension().lastPathComponent
        window.representedURL = editor.file
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 420)            // the whole toolbar, with the outline and fill choices showing
        window.contentView = NSHostingView(rootView: MarkupView(editor: editor))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("")
    }
    /// The hidden self-test opens editors off screen and never activates the app.
    static var invisible = false
    func show() {
        if Self.invisible { window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil); window.contentView?.layoutSubtreeIfNeeded(); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let c = canvas { window.makeFirstResponder(c) }
    }
    var canvas: MarkupCanvas? { find(window.contentView) }
    private func find(_ v: NSView?) -> MarkupCanvas? {
        guard let v else { return nil }
        if let c = v as? MarkupCanvas { return c }
        for s in v.subviews { if let c = find(s) { return c } }
        return nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas?.finishText()
        if editor.dirty { editor.save(copy: false, close: false) }
        return true
    }
    func windowWillClose(_ n: Notification) { onClosed() }
    @objc func markupDone(_ sender: Any?) { canvas?.finishText(); editor.save(copy: true, close: true) }
    @objc func markupSave(_ sender: Any?) { canvas?.finishText(); editor.save(copy: false, close: false) }
}
