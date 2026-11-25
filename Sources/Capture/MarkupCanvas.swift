import AppKit
import CaptureCore

/// The picture and its marks, fitted to the window. Tools stay in hand, so three arrows are three drags. A click on a mark, with any tool,
/// selects it; a selected mark moves by its body and reshapes by its handles. Shift keeps lines level or at 45° and boxes square.
final class MarkupCanvas: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let editor: MarkupEditor
    private enum Drag {
        case none
        case pending(start: CGPoint, hit: UUID?, shift: Bool)          // a drawing tool pressed; a drag draws, a click selects or places
        case create(Mark)
        case move(last: CGPoint, moved: Bool)
        case handle(UUID, Int)
        case crop(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropHandle(Int)
    }
    private var drag: Drag = .none
    private var draft: Mark?
    private var hover: UUID?
    private let field = NSTextField()

    init(editor: MarkupEditor) {
        self.editor = editor
        super.init(frame: .zero)
        field.isBordered = false; field.drawsBackground = true; field.focusRingType = .none; field.isHidden = true
        field.usesSingleLineMode = false; field.cell?.wraps = false; field.cell?.isScrollable = true; field.delegate = self
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    // MARK: fitting the picture
    /// Image pixels → view points.
    var zoom: CGFloat {
        let pad: CGFloat = 28, w = editor.doc.width, h = editor.doc.height
        guard w > 0, h > 0, bounds.width > pad * 2, bounds.height > pad * 2 else { return 1 }
        return min((bounds.width - pad * 2) / w, (bounds.height - pad * 2) / h, 1 / editor.doc.scale * 1.5)    // never blown up past 1.5× actual size
    }
    var imageRect: CGRect {
        let z = zoom, w = editor.doc.width * z, h = editor.doc.height * z
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }
    func toImage(_ p: CGPoint) -> CGPoint { let r = imageRect, z = zoom; return CGPoint(x: (p.x - r.minX) / z, y: (p.y - r.minY) / z) }
    func toView(_ p: CGPoint) -> CGPoint { let r = imageRect, z = zoom; return CGPoint(x: r.minX + p.x * z, y: r.minY + p.y * z) }
    func toView(_ r: CGRect) -> CGRect { let o = toView(r.origin); return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom) }
    private var slop: CGFloat { 5 / zoom }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect, z = zoom
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 14, color: CGColor(gray: 0, alpha: 0.25))
        ctx.setFillColor(.white); ctx.fill(r)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY); ctx.scaleBy(x: z, y: z)
        ctx.interpolationQuality = .high
        var doc = editor.doc
        if let draft { doc.marks.append(draft) }
        var skip: Set<UUID> = []
        if let e = editor.editingText { skip.insert(e) }
        MarkupRenderer.draw(base: editor.base, doc: doc, in: ctx, skip: skip)
        if let c = doc.crop {
            let p = CGMutablePath(); p.addRect(doc.bounds); p.addRect(c)
            ctx.addPath(p); ctx.setFillColor(CGColor(gray: 0, alpha: editor.tool == .crop ? 0.5 : 0.72)); ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
        drawChrome(ctx)
    }
    private let accent = CGColor(srgbRed: 0.10, green: 0.47, blue: 0.98, alpha: 1)

    /// Selection outlines and handles, in view points so they stay the same size at any zoom.
    private func drawChrome(_ ctx: CGContext) {
        if editor.tool == .crop, let c = editor.doc.crop {
            let v = toView(c)
            ctx.setStrokeColor(.white); ctx.setLineWidth(1.5); ctx.stroke(v)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5)); ctx.setLineWidth(0.5)
            for i in 1...2 {                                       // thirds, as in Photos
                let x = v.minX + v.width * CGFloat(i) / 3, y = v.minY + v.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: v.minY)); ctx.addLine(to: CGPoint(x: x, y: v.maxY)); ctx.move(to: CGPoint(x: v.minX, y: y)); ctx.addLine(to: CGPoint(x: v.maxX, y: y))
            }
            ctx.strokePath()
            for h in corners(v) { handle(ctx, h) }
            sizeLabel(ctx, "\(Int(c.width / editor.doc.scale)) × \(Int(c.height / editor.doc.scale)) pt", below: v)
        }
        if let draft, draft.spansArea {
            sizeLabel(ctx, "\(Int(draft.rect.width / editor.doc.scale)) × \(Int(draft.rect.height / editor.doc.scale)) pt", below: toView(draft.rect))
        }
        if let h = hover, !editor.selection.contains(h), editor.editingText == nil, let m = editor.mark(h) {
            ctx.setStrokeColor(accent.copy(alpha: 0.6)!); ctx.setLineWidth(1)
            if m.kind == .pin { ctx.strokeEllipse(in: outline(m)) } else { ctx.stroke(outline(m).insetBy(dx: -0.5, dy: -0.5)) }
        }
        for m in editor.selectedMarks where m.id != editor.editingText {
            ctx.setStrokeColor(accent); ctx.setLineWidth(1)
            if m.isLine {
                for p in [m.a, m.b] { handle(ctx, toView(p)) }
            } else {
                if m.kind == .pin { ctx.strokeEllipse(in: outline(m)) } else { ctx.stroke(outline(m).insetBy(dx: -0.5, dy: -0.5)) }
                if m.spansArea && editor.selection.count == 1 { for h in corners(toView(m.rect)) { handle(ctx, h) } }
            }
        }
        if let id = editor.activeNote, let m = editor.mark(id) {
            ctx.setStrokeColor(accent); ctx.setLineWidth(2); ctx.strokeEllipse(in: toView(MarkupRenderer.frame(of: m, in: editor.doc)).insetBy(dx: -4, dy: -4))
        }
    }
    private func outline(_ m: Mark) -> CGRect {
        let r = (m.kind == .text || m.kind == .pin) ? MarkupRenderer.frame(of: m, in: editor.doc) : m.rect
        let pad = (m.kind == .text || m.kind == .pin) ? 3 : MarkupRenderer.lineWidth(m, editor.doc) * zoom / 2 + 3
        return toView(r).insetBy(dx: -pad, dy: -pad)
    }
    private func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
    private func handle(_ ctx: CGContext, _ p: CGPoint) {
        let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        ctx.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor(.white); ctx.fillEllipse(in: r)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(accent); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
    }
    private func sizeLabel(_ ctx: CGContext, _ s: String, below v: CGRect) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        let sz = a.size(), r = CGRect(x: v.midX - sz.width / 2 - 6, y: min(v.maxY + 6, bounds.maxY - sz.height - 8), width: sz.width + 12, height: sz.height + 4)
        ctx.setFillColor(accent); ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); ctx.fillPath()
        NSGraphicsContext.saveGraphicsState(); a.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2)); NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: pointer
    private func handleIndex(at v: CGPoint) -> (UUID, Int)? {
        guard editor.selection.count == 1, let m = editor.selectedMarks.first else { return nil }
        let pts = m.isLine ? [m.a, m.b].map(toView) : (m.spansArea ? corners(toView(m.rect)) : [])
        for (i, p) in pts.enumerated() where hypot(p.x - v.x, p.y - v.y) <= 8 { return (m.id, i) }
        return nil
    }
    private func cropHandle(at v: CGPoint) -> Int? {
        guard editor.tool == .crop, let c = editor.doc.crop else { return nil }
        for (i, p) in corners(toView(c)).enumerated() where hypot(p.x - v.x, p.y - v.y) <= 10 { return i }
        return nil
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil), p = toImage(v)
        let h = editor.doc.hit(p, slop: slop)
        if h != hover { hover = h; needsDisplay = true }
        updateCursor(v)
    }
    override func mouseExited(with event: NSEvent) { if hover != nil { hover = nil; needsDisplay = true } }
    private func updateCursor(_ v: CGPoint) {
        if handleIndex(at: v) != nil || cropHandle(at: v) != nil { NSCursor.crosshair.set(); return }
        let p = toImage(v)
        if let h = editor.doc.hit(p, slop: slop), editor.selection.contains(h) || editor.tool == .select { NSCursor.openHand.set(); return }
        if editor.tool == .crop, let c = editor.doc.crop, c.contains(p) { NSCursor.openHand.set(); return }
        switch editor.tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if editor.editingText != nil { finishText(); }
        let v = convert(e.locationInWindow, from: nil), p = toImage(v), shift = e.modifierFlags.contains(.shift)
        if e.clickCount == 2, let id = editor.doc.hit(p, slop: slop), let m = editor.mark(id) {
            if m.kind == .text { editor.beginTextEditing(id); showField(); return }
            if m.kind == .pin { editor.activeNote = id; NotificationCenter.default.post(name: .markupFocusNote, object: id); return }
        }
        if editor.tool == .crop {
            if let i = cropHandle(at: v) { editor.checkpoint(); drag = .cropHandle(i); return }
            if let c = editor.doc.crop, c.contains(p) { editor.checkpoint(); drag = .cropMove(last: p); return }
            editor.checkpoint(); drag = .crop(start: p); return
        }
        if let (id, i) = handleIndex(at: v) { editor.checkpoint(); drag = .handle(id, i); return }
        let hit = editor.doc.hit(p, slop: slop)
        if let hit, editor.selection.contains(hit) {
            if shift { editor.selection.remove(hit); needsDisplay = true; return }
            editor.checkpoint(); drag = .move(last: p, moved: false); return
        }
        if editor.tool == .select {
            if let hit {
                if shift { editor.selection.insert(hit) } else { editor.selection = [hit] }
                editor.checkpoint(); drag = .move(last: p, moved: false)
            } else { editor.selection = [] }
            needsDisplay = true; return
        }
        editor.selection = []
        drag = .pending(start: p, hit: hit, shift: shift)
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil), p = toImage(v), shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .none: return
        case .pending(let start, _, _):
            guard hypot((p.x - start.x) * zoom, (p.y - start.y) * zoom) > 3, let kind = editor.tool.kind, kind != .pin, kind != .text else { return }
            let m = Mark(kind: kind, a: start, b: p, color: editor.color, size: editor.size, dashed: editor.dashed, fill: editor.fill)
            drag = .create(m); draft = m; mouseDragged(with: e); return
        case .create(var m):
            m.b = clampPoint(p)
            if shift { m.b = m.isLine ? Geometry.snap45(from: m.a, to: m.b) : Geometry.square(from: m.a, to: m.b) }
            else if m.kind == .measure { m.b = axisSnap(m.a, m.b) }
            drag = .create(m); draft = m
        case .move(let last, _):
            let d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
            for id in editor.selection { editor.update(id) { $0 = $0.moved(by: d) } }
            drag = .move(last: p, moved: true)
        case .handle(let id, let i):
            editor.update(id) { m in
                if m.isLine {
                    var q = clampPoint(p)
                    if shift { q = Geometry.snap45(from: i == 0 ? m.b : m.a, to: q) } else if m.kind == .measure { q = axisSnap(i == 0 ? m.b : m.a, q) }
                    if i == 0 { m.a = q } else { m.b = q }
                } else {
                    let r = m.rect, opposite = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][i]
                    var q = clampPoint(p); if shift { q = Geometry.square(from: opposite, to: q) }
                    m.a = opposite; m.b = q
                }
            }
        case .crop(let start):
            var q = clampPoint(p); if shift { q = Geometry.square(from: start, to: q) }
            editor.setCrop(Mark(kind: .box, a: clampPoint(start), b: q).rect)
        case .cropMove(let last):
            guard var c = editor.doc.crop else { return }
            c = c.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            c.origin.x = max(0, min(c.origin.x, editor.doc.width - c.width)); c.origin.y = max(0, min(c.origin.y, editor.doc.height - c.height))
            editor.doc.crop = c.integral; drag = .cropMove(last: p)
        case .cropHandle(let i):
            guard let c = editor.doc.crop else { return }
            let opposite = [CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY)][i]
            editor.setCrop(Mark(kind: .box, a: opposite, b: clampPoint(p)).rect)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .pending(let start, let hit, _):
            if let hit { editor.selection = [hit] }
            else if editor.tool == .pin, editor.doc.bounds.contains(start) {
                editor.add(Mark(kind: .pin, a: start, color: editor.color, size: editor.size))
                if let id = editor.selection.first { editor.activeNote = nil; NotificationCenter.default.post(name: .markupPinAdded, object: id) }
            } else if editor.tool == .text, editor.doc.bounds.contains(start) {
                editor.add(Mark(kind: .text, a: start, color: editor.color, size: editor.size))
                if let id = editor.selection.first { editor.beginTextEditing(id); editor.uncheckpointLast(); showField() }
            }
        case .create(let m):
            draft = nil
            let big = m.isLine ? hypot((m.b.x - m.a.x) * zoom, (m.b.y - m.a.y) * zoom) > 6 : (m.rect.width * zoom > 4 && m.rect.height * zoom > 4)
            if big { editor.add(m) }
        case .move(_, let moved): if !moved { editor.uncheckpointLast() }
        case .crop:
            if let c = editor.doc.crop, c.width * zoom < 8 || c.height * zoom < 8 { editor.doc.crop = nil }
        default: break
        }
        drag = .none; draft = nil
        needsDisplay = true
    }
    private func clampPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: max(0, min(editor.doc.width, p.x)), y: max(0, min(editor.doc.height, p.y))) }
    /// Spacing is measured across or down: a measure within 8° of level or upright snaps to it.
    private func axisSnap(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let ang = abs(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi
        if ang < 8 || ang > 172 { return CGPoint(x: b.x, y: a.y) }
        if abs(ang - 90) < 8 { return CGPoint(x: a.x, y: b.y) }
        return b
    }

    // MARK: keys
    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased().first else { super.keyDown(with: e); return }
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 51, 117: editor.deleteSelection(); needsDisplay = true; return          // ⌫ and ⌦
        case 53:                                                                     // Esc
            if case .create = drag { drag = .none; draft = nil }
            else if !editor.selection.isEmpty { editor.selection = [] }
            else if editor.tool != .select { editor.choose(.select) }
            needsDisplay = true; return
        case 36, 76:                                                                 // Return
            if editor.tool == .crop { editor.choose(.select) }
            else if editor.selection.count == 1, let m = editor.selectedMarks.first, m.kind == .text { editor.beginTextEditing(m.id); showField() }
            else if editor.selection.count == 1, let m = editor.selectedMarks.first, m.kind == .pin { NotificationCenter.default.post(name: .markupFocusNote, object: m.id) }
            needsDisplay = true; return
        case 123: editor.nudge(-step, 0); return
        case 124: editor.nudge(step, 0); return
        case 125: editor.nudge(0, step); return
        case 126: editor.nudge(0, -step); return
        default: break
        }
        if let t = MarkupTool.allCases.first(where: { $0.key == ch }) { editor.choose(t); needsDisplay = true; window?.invalidateCursorRects(for: self); return }
        if let n = Int(String(ch)), n >= 1, n <= MarkColor.allCases.count { editor.setColor(MarkColor.allCases[n - 1]); return }
        if ch == "[" { editor.stepSize(-1); return }
        if ch == "]" { editor.stepSize(1); return }
        super.keyDown(with: e)
    }
    // Edit menu and its keys (⌘Z, ⇧⌘Z, ⌘C, ⌘A, ⌘D); the text field handles its own while typing.
    @objc func undo(_ sender: Any?) { editor.undo(); needsDisplay = true }
    @objc func redo(_ sender: Any?) { editor.redo(); needsDisplay = true }
    @objc func copy(_ sender: Any?) { editor.save(copy: true, close: false) }
    override func selectAll(_ sender: Any?) { editor.selectAll(); needsDisplay = true }
    @objc func duplicate(_ sender: Any?) { editor.duplicateSelection(); needsDisplay = true }
    @objc func delete(_ sender: Any?) { editor.deleteSelection(); needsDisplay = true }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editor.canUndo
        case #selector(redo(_:)): return editor.canRedo
        case #selector(duplicate(_:)), #selector(delete(_:)): return !editor.selection.isEmpty
        default: return true
        }
    }

    // MARK: typing a label in place
    func showField() {
        guard let id = editor.editingText, let m = editor.mark(id) else { return }
        let z = zoom, pad = CGSize(width: m.size.type * 0.5 * editor.doc.scale * z, height: m.size.type * 0.3 * editor.doc.scale * z)
        field.font = NSFont.systemFont(ofSize: m.size.type * editor.doc.scale * z, weight: .semibold)
        field.textColor = NSColor(cgColor: m.color.textOn); field.backgroundColor = NSColor(cgColor: m.color.cg())
        field.stringValue = m.text
        layoutField(m, pad: pad)
        field.isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (m.text as NSString).length, length: 0)
        needsDisplay = true
    }
    private func layoutField(_ m: Mark, pad: CGSize) {
        let f = toView(MarkupRenderer.frame(of: m, in: editor.doc))
        field.frame = CGRect(x: f.minX + pad.width - 2, y: f.minY + pad.height, width: max(60, f.width - pad.width * 2 + 24), height: f.height - pad.height * 2 + 2)
        field.wantsLayer = true; field.layer?.cornerRadius = 3
    }
    func controlTextDidChange(_ n: Notification) {
        editor.setEditingText(field.stringValue)
        if let id = editor.editingText, let m = editor.mark(id) {
            let z = zoom; layoutField(m, pad: CGSize(width: m.size.type * 0.5 * editor.doc.scale * z, height: m.size.type * 0.3 * editor.doc.scale * z))
        }
        needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) && !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) { finishText(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { textView.insertNewlineIgnoringFieldEditor(nil); return true }     // ⇧↩ a new line
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishText(); return true }        // Esc keeps what was typed, as everywhere on the Mac
        return false
    }
    func controlTextDidEndEditing(_ n: Notification) { if editor.editingText != nil { finishText() } }
    func finishText(cancel: Bool = false) {
        guard editor.editingText != nil else { return }
        editor.setEditingText(field.stringValue)
        editor.endTextEditing(cancel: cancel)
        field.isHidden = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    override func layout() { super.layout(); if editor.editingText != nil, let id = editor.editingText, let m = editor.mark(id) { let z = zoom; layoutField(m, pad: CGSize(width: m.size.type * 0.5 * editor.doc.scale * z, height: m.size.type * 0.3 * editor.doc.scale * z)) } }
}

extension Notification.Name {
    static let markupFocusNote = Notification.Name("markup.focusNote")
    static let markupPinAdded = Notification.Name("markup.pinAdded")
}
