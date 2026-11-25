import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Mark up: arrows, boxes, words, numbered pins with notes, highlight, focus, redaction, measuring and crop, on top of a screenshot.
// Every mark stays an object. The library file is the flattened picture (so paste, Finder and other apps see it); the untouched original and the marks
// live beside it in the library's hidden `.markup` folder, so a picture opens again with every mark still editable, or goes back to the original.
// All geometry is in image pixels with the origin at the top left.

public enum MarkKind: String, Codable, CaseIterable, Sendable {
    case arrow, box, ellipse, text, pin, highlight, focus, redact, measure
}

public enum MarkColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, ink
    public var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .red: return (0.91, 0.16, 0.20)
        case .orange: return (0.98, 0.52, 0.06)
        case .yellow: return (1.00, 0.82, 0.10)
        case .green: return (0.13, 0.70, 0.35)
        case .blue: return (0.10, 0.47, 0.98)
        case .ink: return (0.10, 0.10, 0.12)
        }
    }
    public func cg(_ alpha: CGFloat = 1) -> CGColor { let c = rgb; return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha) }
    /// Words on this color read in white, except on yellow.
    public var textOn: CGColor { self == .yellow ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
    public var title: String { self == .ink ? "Black" : rawValue.capitalized }
}

public enum MarkSize: Int, Codable, CaseIterable, Sendable {
    case thin = 1, regular = 2, thick = 3
    /// Line width in points.
    public var line: CGFloat { [2.0, 3.5, 6.0][rawValue - 1] }
    /// Type size in points, for words and pins.
    public var type: CGFloat { [13.0, 17.0, 24.0][rawValue - 1] }
    public var title: String { ["Thin", "Regular", "Thick"][rawValue - 1] }
}

/// How a box or ellipse is filled: not at all, a see-through tint of its color, or solid.
public enum MarkFill: String, Codable, CaseIterable, Sendable {
    case none, tint, solid
    public var title: String { ["No fill", "Transparent fill", "Solid fill"][Self.allCases.firstIndex(of: self)!] }
    /// How much of the color shows through.
    public var alpha: CGFloat { [0, 0.3, 1][Self.allCases.firstIndex(of: self)!] }
}

public struct Mark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: MarkKind
    /// Start and end. A box, ellipse, highlight, focus or redaction spans them; an arrow and a measure run from a to b; words and pins sit at a.
    public var a: CGPoint
    public var b: CGPoint
    public var color: MarkColor
    public var size: MarkSize
    /// The words of a text mark, or the note of a pin.
    public var text: String
    /// Pins only: 1, 2, 3… in the order they were placed. Kept in step by `MarkupDoc.renumber()`.
    public var number: Int
    /// Boxes and ellipses: a dashed outline, and a fill.
    public var dashed: Bool
    public var fill: MarkFill

    public init(id: UUID = UUID(), kind: MarkKind, a: CGPoint, b: CGPoint? = nil, color: MarkColor = .red, size: MarkSize = .regular, text: String = "", number: Int = 0,
                dashed: Bool = false, fill: MarkFill = .none) {
        self.id = id; self.kind = kind; self.a = a; self.b = b ?? a; self.color = color; self.size = size; self.text = text; self.number = number
        self.dashed = dashed; self.fill = fill
    }
    /// Pictures marked up before outlines and fills existed open as they were: solid outline, no fill.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(MarkKind.self, forKey: .kind)
        a = try c.decode(CGPoint.self, forKey: .a); b = try c.decode(CGPoint.self, forKey: .b)
        color = try c.decode(MarkColor.self, forKey: .color); size = try c.decode(MarkSize.self, forKey: .size)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""; number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false; fill = try c.decodeIfPresent(MarkFill.self, forKey: .fill) ?? .none
    }
    public var isShape: Bool { kind == .box || kind == .ellipse }
    public var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }
    public var spansArea: Bool { [.box, .ellipse, .highlight, .focus, .redact].contains(kind) }
    public var isLine: Bool { kind == .arrow || kind == .measure }
    public func moved(by d: CGVector) -> Mark { var m = self; m.a.x += d.dx; m.a.y += d.dy; m.b.x += d.dx; m.b.y += d.dy; return m }
}

public struct MarkupDoc: Codable, Equatable, Sendable {
    public var version = 1
    /// The original's size in pixels.
    public var width: CGFloat
    public var height: CGFloat
    /// Pixels per point: 2 for a Retina screenshot. Line widths, type and measurements follow it.
    public var scale: CGFloat
    public var marks: [Mark] = []
    /// What is kept when the picture is saved. nil keeps it all.
    public var crop: CGRect?
    /// Prints the pins' notes under the picture, so it explains itself in Teams or Jira.
    public var notesOnImage = false

    public init(width: CGFloat, height: CGFloat, scale: CGFloat) { self.width = width; self.height = height; self.scale = max(1, scale) }
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    public var visible: CGRect { (crop ?? bounds).intersection(bounds).integral }

    /// Pins are numbered in the order they were placed; taking one out closes the gap.
    public mutating func renumber() {
        var n = 0
        for i in marks.indices where marks[i].kind == .pin { n += 1; marks[i].number = n }
    }
    public var pins: [Mark] { marks.filter { $0.kind == .pin }.sorted { $0.number < $1.number } }
    public var nextPinNumber: Int { pins.count + 1 }
    /// The pins' notes as plain text, one line each: "1. Make the total bigger".
    public var notesText: String {
        pins.map { "\($0.number). \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n")
    }
    var printsNotes: Bool { notesOnImage && pins.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    // MARK: finding a mark under the pointer
    /// The topmost mark under `p`, or nil. `slop` is how near counts, in pixels. A line or an outline is found near its stroke first; then the
    /// inside of a box, ellipse or focus is found, so a click inside an empty box still picks it when nothing else is there.
    public func hit(_ p: CGPoint, slop: CGFloat) -> UUID? {
        for m in marks.reversed() {
            let tol = slop + MarkupRenderer.lineWidth(m, self) / 2
            switch m.kind {
            case .arrow, .measure: if Geometry.distance(p, m.a, m.b) <= tol { return m.id }
            case .box, .focus: if Geometry.nearEdge(p, m.rect, tol) || (m.fill != .none && m.rect.contains(p)) { return m.id }
            case .ellipse: if Geometry.nearEllipse(p, m.rect, tol) || (m.fill != .none && Geometry.insideEllipse(p, m.rect)) { return m.id }
            case .highlight, .redact: if m.rect.insetBy(dx: -slop, dy: -slop).contains(p) { return m.id }
            case .text, .pin: if MarkupRenderer.frame(of: m, in: self).insetBy(dx: -slop, dy: -slop).contains(p) { return m.id }
            }
        }
        for m in marks.reversed() where [.box, .ellipse, .focus].contains(m.kind) && m.rect.contains(p) { return m.id }
        return nil
    }
}

public enum Geometry {
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    static func nearEdge(_ p: CGPoint, _ r: CGRect, _ tol: CGFloat) -> Bool {
        r.insetBy(dx: -tol, dy: -tol).contains(p) && !(r.width > 2 * tol && r.height > 2 * tol && r.insetBy(dx: tol, dy: tol).contains(p))
    }
    static func insideEllipse(_ p: CGPoint, _ r: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let dx = (p.x - r.midX) / (r.width / 2), dy = (p.y - r.midY) / (r.height / 2)
        return dx * dx + dy * dy <= 1
    }
    static func nearEllipse(_ p: CGPoint, _ r: CGRect, _ tol: CGFloat) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let rx = r.width / 2, ry = r.height / 2, dx = p.x - r.midX, dy = p.y - r.midY
        let k = sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry))      // 1 on the outline
        return abs(k - 1) * min(rx, ry) <= tol
    }
    /// Keeps a line level, upright or at 45° (Shift while drawing).
    public static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
    }
    /// Keeps a box square (Shift while drawing).
    public static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let s = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? s : -s), y: a.y + (b.y >= a.y ? s : -s))
    }
}

// MARK: drawing
/// Draws a document over its original, on screen and into the saved file alike. The context it is given must have its origin at the top left
/// with y running down, in image pixels.
public enum MarkupRenderer {
    static func pt(_ v: CGFloat, _ doc: MarkupDoc) -> CGFloat { v * doc.scale }
    public static func lineWidth(_ m: Mark, _ doc: MarkupDoc) -> CGFloat { pt(m.size.line, doc) }
    static func font(_ m: Mark, _ doc: MarkupDoc, weight: CGFloat = 0.4) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, pt(m.size.type, doc), nil) ?? CTFontCreateWithName("Helvetica" as CFString, pt(m.size.type, doc), nil)
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, pt(m.size.type, doc), nil)
    }

    /// Where a text mark or a pin sits, in image pixels.
    public static func frame(of m: Mark, in doc: MarkupDoc) -> CGRect {
        switch m.kind {
        case .pin:
            let d = pinDiameter(m, doc); return CGRect(x: m.a.x - d / 2, y: m.a.y - d / 2, width: d, height: d)
        case .text:
            let (size, _) = textLayout(m.text.isEmpty ? " " : m.text, font(m, doc, weight: 0.3))
            let pad = textPadding(m, doc)
            return CGRect(x: m.a.x, y: m.a.y, width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        case .measure:
            let (r, _) = measureLabel(m, doc); return r
        default: return m.rect
        }
    }
    static func pinDiameter(_ m: Mark, _ doc: MarkupDoc) -> CGFloat { pt(m.size.type * 1.6, doc) }
    static func textPadding(_ m: Mark, _ doc: MarkupDoc) -> CGSize { CGSize(width: pt(m.size.type * 0.5, doc), height: pt(m.size.type * 0.3, doc)) }

    static func textLayout(_ s: String, _ f: CTFont) -> (CGSize, [CTLine]) {
        let lines = s.components(separatedBy: "\n").map { line -> CTLine in
            CTLineCreateWithAttributedString(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [kCTFontAttributeName as NSAttributedString.Key: f]))
        }
        let lh = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
        let w = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return (CGSize(width: ceil(w), height: ceil(lh * CGFloat(lines.count))), lines)
    }
    /// Draws text simply: one call per line with its own string.
    static func drawText(_ s: String, font f: CTFont, color: CGColor, at origin: CGPoint, in ctx: CGContext) {
        let asc = CTFontGetAscent(f), lh = asc + CTFontGetDescent(f) + CTFontGetLeading(f)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, line) in s.components(separatedBy: "\n").enumerated() {
            let a = NSAttributedString(string: line.isEmpty ? " " : line, attributes: [kCTFontAttributeName as NSAttributedString.Key: f, kCTForegroundColorAttributeName as NSAttributedString.Key: color])
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + asc + lh * CGFloat(i))
            CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
        }
        ctx.restoreGState()
    }

    /// The original, drawn right way up into a top-left context.
    public static func drawImage(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY + r.minY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }

    /// Everything: the original, redactions, focus, then the marks in the order they were made.
    public static func draw(base: CGImage, doc: MarkupDoc, in ctx: CGContext, skip: Set<UUID> = []) {
        drawImage(base, in: doc.bounds, ctx)
        for m in doc.marks where m.kind == .redact && !skip.contains(m.id) { drawRedaction(m, base: base, doc: doc, ctx) }
        let focus = doc.marks.filter { $0.kind == .focus && !skip.contains($0.id) }
        if !focus.isEmpty { drawFocus(focus, doc, ctx) }
        for m in doc.marks where m.kind != .redact && m.kind != .focus && !skip.contains(m.id) { drawMark(m, doc, ctx) }
    }

    static let halo = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)

    public static func drawMark(_ m: Mark, _ doc: MarkupDoc, _ ctx: CGContext) {
        let w = lineWidth(m, doc)
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch m.kind {
        case .arrow:
            let path = arrowPath(m, doc)
            ctx.addPath(path); ctx.setStrokeColor(halo); ctx.setLineWidth(max(2, w * 0.6)); ctx.strokePath()      // a thin white edge reads on any screen
            ctx.addPath(path); ctx.setFillColor(m.color.cg()); ctx.fillPath()
        case .box, .ellipse:
            let r = m.rect, path = m.kind == .box ? CGPath(roundedRect: r, cornerWidth: min(pt(4, doc), r.width / 2), cornerHeight: min(pt(4, doc), r.height / 2), transform: nil) : CGPath(ellipseIn: r, transform: nil)
            if m.fill != .none { ctx.addPath(path); ctx.setFillColor(m.color.cg(m.fill.alpha)); ctx.fillPath() }
            if m.dashed { ctx.setLineDash(phase: 0, lengths: [w * 2.4, w * 2.0]) }        // round caps make each dash a soft pill
            ctx.addPath(path); ctx.setStrokeColor(halo); ctx.setLineWidth(w + pt(2, doc)); ctx.strokePath()
            ctx.addPath(path); ctx.setStrokeColor(m.color.cg()); ctx.setLineWidth(w); ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(m.color.cg(m.color == .yellow ? 0.55 : 0.35))
            ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: min(pt(2, doc), m.rect.width / 2), cornerHeight: min(pt(2, doc), m.rect.height / 2), transform: nil)); ctx.fillPath()
        case .text:
            let f = font(m, doc, weight: 0.3), r = frame(of: m, in: doc), pad = textPadding(m, doc)
            ctx.setShadow(offset: CGSize(width: 0, height: pt(1, doc)), blur: pt(4, doc), color: CGColor(gray: 0, alpha: 0.25))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: pt(5, doc), cornerHeight: pt(5, doc), transform: nil)); ctx.setFillColor(m.color.cg()); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawText(m.text.isEmpty ? " " : m.text, font: f, color: m.color.textOn, at: CGPoint(x: r.minX + pad.width, y: r.minY + pad.height), in: ctx)
        case .pin:
            let r = frame(of: m, in: doc)
            ctx.setShadow(offset: CGSize(width: 0, height: pt(1, doc)), blur: pt(4, doc), color: CGColor(gray: 0, alpha: 0.3))
            ctx.addEllipse(in: r); ctx.setFillColor(halo); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addEllipse(in: r.insetBy(dx: pt(1.5, doc), dy: pt(1.5, doc))); ctx.setFillColor(m.color.cg()); ctx.fillPath()
            let f = font(m, doc, weight: 0.5), label = "\(m.number)", (size, _) = textLayout(label, f)
            drawText(label, font: f, color: m.color.textOn, at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), in: ctx)
        case .measure:
            drawMeasure(m, doc, ctx)
        case .focus, .redact: break
        }
    }

    public static func arrowPath(_ m: Mark, _ doc: MarkupDoc) -> CGPath {
        let w = lineWidth(m, doc), dx = m.b.x - m.a.x, dy = m.b.y - m.a.y, len = max(hypot(dx, dy), 0.01)
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let head = min(max(w * 4.2, pt(10, doc)), len * 0.6), headHalf = head * 0.55
        let neck = CGPoint(x: m.b.x - ux * head * 0.85, y: m.b.y - uy * head * 0.85)
        let p = CGMutablePath()
        // the shaft tapers from a point at the tail to full width at the head, which reads as drawn
        p.move(to: CGPoint(x: m.a.x + nx * w * 0.15, y: m.a.y + ny * w * 0.15))
        p.addLine(to: CGPoint(x: neck.x + nx * w / 2, y: neck.y + ny * w / 2))
        p.addLine(to: CGPoint(x: m.b.x - ux * head + nx * headHalf, y: m.b.y - uy * head + ny * headHalf))
        p.addLine(to: m.b)
        p.addLine(to: CGPoint(x: m.b.x - ux * head - nx * headHalf, y: m.b.y - uy * head - ny * headHalf))
        p.addLine(to: CGPoint(x: neck.x - nx * w / 2, y: neck.y - ny * w / 2))
        p.addLine(to: CGPoint(x: m.a.x - nx * w * 0.15, y: m.a.y - ny * w * 0.15))
        p.closeSubpath()
        return p
    }

    /// The distance a measure shows, in points (pixels ÷ scale), rounded.
    public static func measureValue(_ m: Mark, _ doc: MarkupDoc) -> Int { Int((hypot(m.b.x - m.a.x, m.b.y - m.a.y) / doc.scale).rounded()) }
    static func measureLabel(_ m: Mark, _ doc: MarkupDoc) -> (CGRect, String) {
        var small = m; small.size = .thin
        let s = "\(measureValue(m, doc)) pt", f = font(small, doc, weight: 0.4), (size, _) = textLayout(s, f)
        let pad = CGSize(width: pt(5, doc), height: pt(2, doc))
        let mid = CGPoint(x: (m.a.x + m.b.x) / 2, y: (m.a.y + m.b.y) / 2)
        let r = CGRect(x: mid.x - size.width / 2 - pad.width, y: mid.y - size.height / 2 - pad.height, width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        return (r, s)
    }
    static func drawMeasure(_ m: Mark, _ doc: MarkupDoc, _ ctx: CGContext) {
        let w = max(pt(1.5, doc), lineWidth(m, doc) * 0.6), dx = m.b.x - m.a.x, dy = m.b.y - m.a.y, len = max(hypot(dx, dy), 0.01)
        let nx = -dy / len * pt(6, doc), ny = dx / len * pt(6, doc)
        let p = CGMutablePath()
        p.move(to: m.a); p.addLine(to: m.b)
        p.move(to: CGPoint(x: m.a.x + nx, y: m.a.y + ny)); p.addLine(to: CGPoint(x: m.a.x - nx, y: m.a.y - ny))
        p.move(to: CGPoint(x: m.b.x + nx, y: m.b.y + ny)); p.addLine(to: CGPoint(x: m.b.x - nx, y: m.b.y - ny))
        ctx.addPath(p); ctx.setStrokeColor(halo); ctx.setLineWidth(w + pt(2, doc)); ctx.strokePath()
        ctx.addPath(p); ctx.setStrokeColor(m.color.cg()); ctx.setLineWidth(w); ctx.strokePath()
        var small = m; small.size = .thin
        let (r, s) = measureLabel(m, doc), f = font(small, doc, weight: 0.4)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); ctx.setFillColor(m.color.cg()); ctx.fillPath()
        drawText(s, font: f, color: m.color.textOn, at: CGPoint(x: r.minX + pt(5, doc), y: r.minY + pt(2, doc)), in: ctx)
    }

    /// Everything outside the focus areas goes dim.
    static func drawFocus(_ marks: [Mark], _ doc: MarkupDoc, _ ctx: CGContext) {
        ctx.saveGState()
        let p = CGMutablePath(); p.addRect(doc.bounds)
        for m in marks { p.addPath(CGPath(roundedRect: m.rect, cornerWidth: min(pt(6, doc), m.rect.width / 2), cornerHeight: min(pt(6, doc), m.rect.height / 2), transform: nil)) }
        ctx.addPath(p); ctx.setFillColor(CGColor(gray: 0, alpha: 0.55)); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Big blocks of the picture's own colors: unreadable, and still clearly "something was here".
    static func drawRedaction(_ m: Mark, base: CGImage, doc: MarkupDoc, _ ctx: CGContext) {
        let r = m.rect.integral.intersection(doc.bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        let block = max(pt(10, doc), min(r.width, r.height) / 6)
        let cols = max(1, Int((r.width / block).rounded(.up))), rows = max(1, Int((r.height / block).rounded(.up)))
        guard let piece = base.cropping(to: r),
              let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .medium
        small.draw(piece, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let tiny = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.clip(to: r)
        drawImage(tiny, in: CGRect(x: r.minX, y: r.minY, width: CGFloat(cols) * block, height: CGFloat(rows) * block), ctx)
        ctx.restoreGState()
    }

    // MARK: the saved picture
    /// The flattened picture: cropped, with the notes printed under it when asked.
    public static func render(base: CGImage, doc: MarkupDoc) -> CGImage? {
        let v = doc.visible
        guard v.width >= 1, v.height >= 1 else { return nil }
        let notes = doc.printsNotes ? notesBlock(doc, width: v.width) : nil
        let W = Int(v.width), H = Int(v.height + (notes?.height ?? 0))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)              // top left, y down, like everything else here
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: v.width, height: v.height))
        ctx.translateBy(x: -v.minX, y: -v.minY)
        draw(base: base, doc: doc, in: ctx)
        ctx.restoreGState()
        if let notes { drawNotes(doc, in: CGRect(x: 0, y: v.height, width: v.width, height: notes.height), ctx) }
        return ctx.makeImage()
    }

    struct NotesBlock { let height: CGFloat }
    static func notesRows(_ doc: MarkupDoc) -> [Mark] { doc.pins.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    static func notesFont(_ doc: MarkupDoc) -> CTFont { var m = Mark(kind: .text, a: .zero); m.size = .regular; return font(m, doc, weight: 0.0) }
    static func notesBlock(_ doc: MarkupDoc, width: CGFloat) -> NotesBlock {
        let f = notesFont(doc), lh = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
        let lines = notesRows(doc).reduce(0) { $0 + wrap($1.text, f, width - pt(64, doc)).count }
        return NotesBlock(height: pt(32, doc) + CGFloat(lines) * lh + CGFloat(max(0, notesRows(doc).count - 1)) * pt(10, doc))
    }
    static func wrap(_ s: String, _ f: CTFont, _ width: CGFloat) -> [String] {
        var out: [String] = []
        for para in s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            var line = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false) {
                let tryLine = line.isEmpty ? String(word) : line + " " + word
                if textLayout(tryLine, f).0.width > width, !line.isEmpty { out.append(line); line = String(word) } else { line = tryLine }
            }
            out.append(line)
        }
        return out
    }
    static func drawNotes(_ doc: MarkupDoc, in r: CGRect, _ ctx: CGContext) {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(r)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.12)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(1, doc.scale)))
        let f = notesFont(doc), lh = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
        var y = r.minY + pt(16, doc)
        for pin in notesRows(doc) {
            var badge = pin; badge.size = .thin
            let d = pinDiameter(badge, doc)
            badge.a = CGPoint(x: r.minX + pt(16, doc) + d / 2, y: y + lh / 2)
            drawMark(badge, doc, ctx)
            let lines = wrap(pin.text, f, r.width - pt(64, doc))
            drawText(lines.joined(separator: "\n"), font: f, color: CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1), at: CGPoint(x: r.minX + pt(48, doc), y: y), in: ctx)
            y += CGFloat(lines.count) * lh + pt(10, doc)
        }
    }
}

// MARK: files
/// Reads and writes marked-up pictures. The library file is always the flattened picture; `.markup/<file name>` keeps the original and
/// `.markup/<file name>.json` keeps the marks.
public struct MarkupStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    var folder: URL { root.appendingPathComponent(".markup", isDirectory: true) }
    public func originalURL(_ file: URL) -> URL { folder.appendingPathComponent(file.lastPathComponent) }
    public func docURL(_ file: URL) -> URL { folder.appendingPathComponent(file.lastPathComponent + ".json") }
    public func hasMarkup(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: docURL(file).path) }
    public func sidecars(_ file: URL) -> [URL] { [originalURL(file), docURL(file)] }

    public static func loadImage(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
        return (img, dpi > 72.5 ? CGFloat(dpi / 72).rounded() : 0)
    }

    /// The original and its marks: from the side folder when it was marked up before, else the file itself with no marks.
    /// `fallbackScale` is used when the file does not say its pixel density (Capture's own screenshots): the screen's.
    public func open(_ file: URL, fallbackScale: CGFloat) -> (base: CGImage, doc: MarkupDoc)? {
        if let d = try? Data(contentsOf: docURL(file)), let doc = try? JSONDecoder().decode(MarkupDoc.self, from: d), let (img, _) = Self.loadImage(originalURL(file)) {
            return (img, doc)
        }
        guard let (img, dpiScale) = Self.loadImage(file) else { return nil }
        return (img, MarkupDoc(width: CGFloat(img.width), height: CGFloat(img.height), scale: dpiScale > 0 ? dpiScale : fallbackScale))
    }

    /// Keeps the original (once), the marks, and writes the flattened picture over the library file.
    public func save(_ file: URL, base: CGImage, doc: MarkupDoc) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: originalURL(file).path) {
            if fm.fileExists(atPath: file.path) { try fm.copyItem(at: file, to: originalURL(file)) } else { try Self.png(base, scale: doc.scale).write(to: originalURL(file)) }
        }
        try JSONEncoder().encode(doc).write(to: docURL(file), options: .atomic)
        guard let flat = MarkupRenderer.render(base: base, doc: doc) else { throw CocoaError(.fileWriteUnknown) }
        try Self.png(flat, scale: doc.scale).write(to: file, options: .atomic)
    }
    /// Puts the original back and forgets the marks.
    public func revert(_ file: URL) throws {
        let fm = FileManager.default, orig = originalURL(file)
        guard fm.fileExists(atPath: orig.path) else { return }
        let data = try Data(contentsOf: orig)
        try data.write(to: file, options: .atomic)
        forget(file)
    }
    public func forget(_ file: URL) { for u in sidecars(file) { try? FileManager.default.removeItem(at: u) } }

    public static func png(_ img: CGImage, scale: CGFloat) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        let dpi = 72 * max(1, scale)
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}
