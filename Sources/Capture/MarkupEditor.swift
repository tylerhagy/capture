import AppKit
import SwiftUI
import CaptureCore

/// The mark-up tools. One key each, as in Figma: the letter is shown in each tool's tip.
enum MarkupTool: String, CaseIterable, Identifiable {
    case select, arrow, box, ellipse, text, pin, highlight, focus, redact, measure, crop
    var id: String { rawValue }
    var key: Character {
        switch self {
        case .select: return "v"; case .arrow: return "a"; case .box: return "r"; case .ellipse: return "o"; case .text: return "t"; case .pin: return "n"
        case .highlight: return "h"; case .focus: return "f"; case .redact: return "b"; case .measure: return "m"; case .crop: return "c"
        }
    }
    var title: String {
        switch self {
        case .select: return "Select"; case .arrow: return "Arrow"; case .box: return "Box"; case .ellipse: return "Ellipse"; case .text: return "Text"
        case .pin: return "Numbered pin"; case .highlight: return "Highlight"; case .focus: return "Focus"; case .redact: return "Redact"
        case .measure: return "Measure"; case .crop: return "Crop"
        }
    }
    var tip: String {
        let what: String
        switch self {
        case .select: what = "Click a mark to change it; drag to move it"
        case .arrow: what = "Drag from what you mean to where it points"
        case .box: what = "Drag around something"
        case .ellipse: what = "Drag to circle something"
        case .text: what = "Click to type a label"
        case .pin: what = "Click to drop 1, 2, 3… each with a note"
        case .highlight: what = "Drag over words to highlight them"
        case .focus: what = "Drag around what matters; the rest goes dim"
        case .redact: what = "Drag over customer data to hide it"
        case .measure: what = "Drag to measure spacing, in points"
        case .crop: what = "Drag to keep part of the picture"
        }
        return "\(title) (\(String(key).uppercased())). \(what)."
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"; case .arrow: return "arrow.up.right"; case .box: return "square"; case .ellipse: return "circle"
        case .text: return "textformat"; case .pin: return "1.circle"; case .highlight: return "highlighter"; case .focus: return "circle.dashed.inset.filled"
        case .redact: return "eye.slash"; case .measure: return "ruler"; case .crop: return "crop"
        }
    }
    var kind: MarkKind? {
        switch self {
        case .arrow: return .arrow; case .box: return .box; case .ellipse: return .ellipse; case .text: return .text; case .pin: return .pin
        case .highlight: return .highlight; case .focus: return .focus; case .redact: return .redact; case .measure: return .measure
        case .select, .crop: return nil
        }
    }
    /// Highlight starts yellow, redaction and focus have no color to choose.
    var usesColor: Bool { ![.select, .crop, .redact, .focus].contains(self) }
}

/// One picture being marked up: its marks, the tool and style in hand, what is selected, and undo.
@MainActor
final class MarkupEditor: ObservableObject {
    let file: URL
    let base: CGImage
    let store: MarkupStore
    @Published var doc: MarkupDoc
    @Published var tool: MarkupTool = .arrow
    @Published var color: MarkColor { didSet { Self.defaults.set(color.rawValue, forKey: "markup.color") } }
    @Published var size: MarkSize { didSet { Self.defaults.set(size.rawValue, forKey: "markup.size") } }
    /// Boxes and ellipses: dashed or solid outline, and how they are filled.
    @Published var dashed: Bool { didSet { Self.defaults.set(dashed, forKey: "markup.dashed") } }
    @Published var fill: MarkFill { didSet { Self.defaults.set(fill.rawValue, forKey: "markup.fill") } }
    @Published var selection: Set<UUID> = []
    @Published var editingText: UUID?
    /// The pin whose note is being typed in the side list, so the canvas can show which one it is.
    @Published var activeNote: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    let wasMarkedUp: Bool
    /// Where the color and size in hand are remembered. The self-test uses its own, never the user's.
    static var defaults = UserDefaults.standard
    private(set) var dirty = false
    private var past: [MarkupDoc] = [], future: [MarkupDoc] = []

    /// Asks the app to save; `copy` also puts the picture on the clipboard, `close` closes the window after.
    var onSave: (_ copy: Bool, _ close: Bool) -> Void = { _, _ in }
    var onRevert: () -> Void = {}
    var onClose: () -> Void = {}

    init(file: URL, base: CGImage, doc: MarkupDoc, store: MarkupStore) {
        self.file = file; self.base = base; self.doc = doc; self.store = store
        wasMarkedUp = store.hasMarkup(file)
        color = MarkColor(rawValue: Self.defaults.string(forKey: "markup.color") ?? "") ?? .red
        size = MarkSize(rawValue: Self.defaults.integer(forKey: "markup.size")) ?? .regular
        dashed = Self.defaults.bool(forKey: "markup.dashed")
        fill = MarkFill(rawValue: Self.defaults.string(forKey: "markup.fill") ?? "") ?? .none
        if wasMarkedUp { tool = .select }
    }

    // MARK: undo
    /// Call before a change, once per gesture.
    func checkpoint() {
        past.append(doc); if past.count > 200 { past.removeFirst() }
        future = []; dirty = true; canUndo = true; canRedo = false
    }
    /// Takes back the last checkpoint when the gesture changed nothing (a click that didn't move anything).
    func uncheckpointLast() { _ = past.popLast(); canUndo = !past.isEmpty }
    func undo() {
        endTextEditing()
        guard let d = past.popLast() else { return }
        future.append(doc); doc = d; dirty = true
        selection = selection.filter { id in d.marks.contains { $0.id == id } }
        canUndo = !past.isEmpty; canRedo = true
    }
    func redo() {
        guard let d = future.popLast() else { return }
        past.append(doc); doc = d; dirty = true
        selection = selection.filter { id in d.marks.contains { $0.id == id } }
        canUndo = true; canRedo = !future.isEmpty
    }

    // MARK: tools and style
    func choose(_ t: MarkupTool) {
        endTextEditing()
        // A red highlight reads as an error: highlighting starts yellow, and the color in hand comes back after.
        if t == .highlight, tool != .highlight { colorBeforeHighlight = color; if ![.yellow, .green, .blue, .orange].contains(color) { color = .yellow } }
        else if tool == .highlight, t != .highlight, let c = colorBeforeHighlight { color = c; colorBeforeHighlight = nil }
        tool = t
        if t != .select { selection = [] }
    }
    private var colorBeforeHighlight: MarkColor?
    var selectedMarks: [Mark] { doc.marks.filter { selection.contains($0.id) } }
    func setColor(_ c: MarkColor) {
        color = c
        let ids = selection.filter { id in doc.marks.contains { $0.id == id && $0.kind != .redact && $0.kind != .focus } }
        guard !ids.isEmpty else { return }
        checkpoint(); for i in doc.marks.indices where ids.contains(doc.marks[i].id) { doc.marks[i].color = c }
    }
    func setSize(_ s: MarkSize) {
        size = s
        guard !selection.isEmpty else { return }
        checkpoint(); for i in doc.marks.indices where selection.contains(doc.marks[i].id) { doc.marks[i].size = s }
    }
    func setDashed(_ on: Bool) {
        dashed = on
        let ids = selectedMarks.filter(\.isShape).map(\.id); guard !ids.isEmpty else { return }
        checkpoint(); for i in doc.marks.indices where ids.contains(doc.marks[i].id) { doc.marks[i].dashed = on }
    }
    func setFill(_ f: MarkFill) {
        fill = f
        let ids = selectedMarks.filter(\.isShape).map(\.id); guard !ids.isEmpty else { return }
        checkpoint(); for i in doc.marks.indices where ids.contains(doc.marks[i].id) { doc.marks[i].fill = f }
    }
    /// The outline and fill controls show for the box and ellipse tools, or when a box or ellipse is selected.
    var shapeStyleShows: Bool { tool == .box || tool == .ellipse || selectedMarks.contains(where: \.isShape) }
    /// What the controls show: the selected shape's own style, else the style in hand.
    var shownDashed: Bool { selectedMarks.first(where: \.isShape)?.dashed ?? dashed }
    var shownFill: MarkFill { selectedMarks.first(where: \.isShape)?.fill ?? fill }
    var shownColor: MarkColor { selectedMarks.first(where: { $0.kind != .redact && $0.kind != .focus })?.color ?? color }
    var shownSize: MarkSize { selectedMarks.first?.size ?? size }
    func stepSize(_ d: Int) { if let s = MarkSize(rawValue: size.rawValue + d) { setSize(s) } }

    // MARK: marks
    func add(_ m: Mark) {
        checkpoint(); doc.marks.append(m); doc.renumber()
        selection = [m.id]
    }
    func update(_ id: UUID, _ change: (inout Mark) -> Void) {
        guard let i = doc.marks.firstIndex(where: { $0.id == id }) else { return }
        change(&doc.marks[i])
    }
    func mark(_ id: UUID) -> Mark? { doc.marks.first { $0.id == id } }
    func deleteSelection() {
        guard !selection.isEmpty else { if tool == .crop, doc.crop != nil { checkpoint(); doc.crop = nil }; return }
        checkpoint(); doc.marks.removeAll { selection.contains($0.id) }; doc.renumber(); selection = []
    }
    func remove(_ id: UUID) { checkpoint(); doc.marks.removeAll { $0.id == id }; doc.renumber(); selection.remove(id) }
    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        let off = CGVector(dx: 12 * doc.scale, dy: 12 * doc.scale)
        let copies = selectedMarks.map { m -> Mark in var c = m.moved(by: off); c.id = UUID(); return c }
        doc.marks.append(contentsOf: copies); doc.renumber(); selection = Set(copies.map(\.id))
    }
    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard !selection.isEmpty else { return }
        checkpoint(); let v = CGVector(dx: dx * doc.scale, dy: dy * doc.scale)
        for i in doc.marks.indices where selection.contains(doc.marks[i].id) { doc.marks[i] = doc.marks[i].moved(by: v) }
    }
    func selectAll() { tool = .select; selection = Set(doc.marks.map(\.id)) }
    func bringToFront() {
        guard !selection.isEmpty else { return }
        checkpoint(); let picked = selectedMarks; doc.marks.removeAll { selection.contains($0.id) }; doc.marks.append(contentsOf: picked); doc.renumber()
    }

    // MARK: words
    private var textBefore: String?
    func beginTextEditing(_ id: UUID) {
        guard let m = mark(id), m.kind == .text else { return }
        checkpoint(); textBefore = m.text; editingText = id; selection = [id]
    }
    func setEditingText(_ s: String) { if let id = editingText { update(id) { $0.text = s } } }
    func endTextEditing(cancel: Bool = false) {
        guard let id = editingText else { return }
        editingText = nil
        if cancel, let t = textBefore { update(id) { $0.text = t } }
        if let m = mark(id), m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.marks.removeAll { $0.id == id }; selection.remove(id)
            if textBefore?.isEmpty ?? true, let last = past.popLast() { _ = last; canUndo = !past.isEmpty }     // an empty new label leaves nothing to undo
        }
        textBefore = nil
    }

    // MARK: notes
    func setNote(_ id: UUID, _ s: String) { update(id) { $0.text = s }; dirty = true }
    func noteBegan(_ id: UUID) { checkpoint(); activeNote = id; selection = [id] }
    func setNotesOnImage(_ on: Bool) { checkpoint(); doc.notesOnImage = on }

    // MARK: crop
    func setCrop(_ r: CGRect?) { doc.crop = r.map { $0.intersection(doc.bounds).integral } }

    // MARK: out
    func rendered() -> CGImage? { MarkupRenderer.render(base: base, doc: doc) }
    func save(copy: Bool, close: Bool) { endTextEditing(); onSave(copy, close) }
    func markSaved() { dirty = false }
}
