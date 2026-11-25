import XCTest
import CoreGraphics
@testable import CaptureCore

/// A picture with fine detail (a checkerboard of 2 px squares) and a solid red block at the top left, so redaction and drawing can be told apart.
private func picture(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
        ctx.setFillColor(CGColor(gray: (x / 2 + y / 2) % 2 == 0 ? 0 : 1, alpha: 1)); ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
    } }
    return ctx.makeImage()!
}
/// The color at (x, y) with y counted from the top.
private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self), i = (y * img.width + x) * 4      // bitmap memory runs from the top row
    return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
}
/// How much neighboring pixels differ across a region: high for the checkerboard, low once pixelated.
private func detail(_ img: CGImage, _ r: CGRect) -> Int {
    var total = 0
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX - 1) { total += abs(pixel(img, x, y).r - pixel(img, x + 1, y).r) } }
    return total / max(1, Int(r.width * r.height))
}

final class MarkupTests: XCTestCase {
    func testPinsNumberInOrderAndCloseGaps() {
        var d = MarkupDoc(width: 400, height: 300, scale: 2)
        for x in [50, 150, 250] { d.marks.append(Mark(kind: .pin, a: CGPoint(x: x, y: 50))) }
        d.marks.insert(Mark(kind: .arrow, a: .zero, b: CGPoint(x: 10, y: 10)), at: 1)
        d.renumber()
        XCTAssertEqual(d.pins.map(\.number), [1, 2, 3])
        d.marks.removeAll { $0.kind == .pin && $0.number == 2 }; d.renumber()
        XCTAssertEqual(d.pins.map(\.number), [1, 2], "taking a pin out closes the gap")
        XCTAssertEqual(d.nextPinNumber, 3)
        d.marks[0].text = "Make the total bigger"; d.marks[2].text = "  Move Save to the right \n"
        XCTAssertEqual(d.notesText, "1. Make the total bigger\n2. Move Save to the right")
    }

    func testFindingMarks() {
        var d = MarkupDoc(width: 1000, height: 800, scale: 1)
        let box = Mark(kind: .box, a: CGPoint(x: 100, y: 100), b: CGPoint(x: 400, y: 300))
        let arrow = Mark(kind: .arrow, a: CGPoint(x: 500, y: 500), b: CGPoint(x: 700, y: 500))
        let pin = Mark(kind: .pin, a: CGPoint(x: 250, y: 200))
        d.marks = [box, arrow, pin]; d.renumber()
        XCTAssertEqual(d.hit(CGPoint(x: 100, y: 200), slop: 4), box.id, "on the outline")
        XCTAssertEqual(d.hit(CGPoint(x: 600, y: 503), slop: 4), arrow.id, "near the line")
        XCTAssertEqual(d.hit(CGPoint(x: 250, y: 200), slop: 4), pin.id, "the pin on top wins over the box under it")
        XCTAssertEqual(d.hit(CGPoint(x: 160, y: 140), slop: 4), box.id, "inside an empty box still picks the box")
        XCTAssertNil(d.hit(CGPoint(x: 900, y: 700), slop: 4))
    }

    func testSnapping() {
        let p = Geometry.snap45(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(p.y, 0, accuracy: 0.01, "nearly level becomes level")
        let q = Geometry.square(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: -20))
        XCTAssertEqual(q, CGPoint(x: 60, y: -40))
    }

    func testMeasureIsInPoints() {
        let d = MarkupDoc(width: 1000, height: 800, scale: 2)
        XCTAssertEqual(MarkupRenderer.measureValue(Mark(kind: .measure, a: CGPoint(x: 10, y: 10), b: CGPoint(x: 58, y: 10)), d), 24, "48 Retina pixels are 24 pt")
    }

    func testRenderDrawsCropsAndRedacts() throws {
        let base = picture(200, 120)
        var d = MarkupDoc(width: 200, height: 120, scale: 1)
        d.marks = [Mark(kind: .box, a: CGPoint(x: 20, y: 20), b: CGPoint(x: 80, y: 80), color: .blue, size: .thick),
                   Mark(kind: .redact, a: CGPoint(x: 110, y: 20), b: CGPoint(x: 190, y: 100))]
        let out = try XCTUnwrap(MarkupRenderer.render(base: base, doc: d))
        XCTAssertEqual(out.width, 200); XCTAssertEqual(out.height, 120)
        let edge = pixel(out, 20, 50)
        XCTAssertTrue(edge.b > 180 && edge.r < 80, "the blue box is drawn where it was placed (top-left origin): \(edge)")
        XCTAssertGreaterThan(detail(base, CGRect(x: 120, y: 30, width: 60, height: 60)), 100, "the original has fine detail there")
        XCTAssertLessThan(detail(out, CGRect(x: 120, y: 30, width: 60, height: 60)), 20, "redacted: the detail is gone")
        d.crop = CGRect(x: 10, y: 10, width: 100, height: 50)
        let cropped = try XCTUnwrap(MarkupRenderer.render(base: base, doc: d))
        XCTAssertEqual(cropped.width, 100); XCTAssertEqual(cropped.height, 50)
        let e2 = pixel(cropped, 10, 40)
        XCTAssertTrue(e2.b > 180 && e2.r < 80, "the crop keeps marks in place: \(e2)")
    }

    func testFocusDimsOutside() throws {
        let base = picture(100, 100)
        var d = MarkupDoc(width: 100, height: 100, scale: 1)
        d.marks = [Mark(kind: .focus, a: CGPoint(x: 30, y: 30), b: CGPoint(x: 70, y: 70))]
        let out = try XCTUnwrap(MarkupRenderer.render(base: base, doc: d))
        XCTAssertEqual(pixel(out, 51, 50).r, pixel(base, 51, 50).r, "inside stays as it was")
        XCTAssertLessThan(pixel(out, 5, 4).r, 140, "outside goes dim (white became \(pixel(out, 5, 4).r))")
    }

    func testNotesPrintUnderThePicture() throws {
        let base = picture(300, 200)
        var d = MarkupDoc(width: 300, height: 200, scale: 1)
        d.marks = [Mark(kind: .pin, a: CGPoint(x: 50, y: 50), text: "Label is unclear"), Mark(kind: .pin, a: CGPoint(x: 90, y: 50))]; d.renumber()
        XCTAssertEqual(try XCTUnwrap(MarkupRenderer.render(base: base, doc: d)).height, 200, "off by default")
        d.notesOnImage = true
        XCTAssertGreaterThan(try XCTUnwrap(MarkupRenderer.render(base: base, doc: d)).height, 220, "on: the notes add a strip under it")
    }

    func testStoreKeepsOriginalAndReopensEditable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot 1.png"), store = MarkupStore(root: dir)
        let originalBytes = try MarkupStore.png(picture(120, 80), scale: 1); try originalBytes.write(to: file)
        var (base, doc) = try XCTUnwrap(store.open(file, fallbackScale: 2))
        XCTAssertEqual(doc.scale, 2, "72 dpi says nothing (Capture's own screenshots are written that way), so the screen's scale is used"); XCTAssertTrue(doc.marks.isEmpty)
        doc.marks.append(Mark(kind: .arrow, a: CGPoint(x: 10, y: 10), b: CGPoint(x: 90, y: 60)))
        try store.save(file, base: base, doc: doc)
        XCTAssertNotEqual(try Data(contentsOf: file), originalBytes, "the library file is the marked-up picture")
        XCTAssertEqual(try Data(contentsOf: store.originalURL(file)), originalBytes, "the original is kept to the side")
        let again = try XCTUnwrap(store.open(file, fallbackScale: 2))
        XCTAssertEqual(again.doc.marks, doc.marks, "marks come back editable")
        doc.marks.append(Mark(kind: .pin, a: CGPoint(x: 50, y: 50)))
        try store.save(file, base: again.base, doc: doc)
        XCTAssertEqual(try Data(contentsOf: store.originalURL(file)), originalBytes, "saving again never replaces the original with a marked-up one")
        try store.revert(file)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes, "Revert puts the original back")
        XCTAssertFalse(store.hasMarkup(file))
        // trashing a marked-up capture takes its side files too
        try store.save(file, base: base, doc: doc)
        let lib = try Library(root: dir); lib.remove = { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(lib.items().count, 1, "the side folder is not a capture")
        lib.trash([file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalURL(file).path))
    }

    func testRetinaScaleFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.png"); try MarkupStore.png(picture(40, 40), scale: 2).write(to: file)
        XCTAssertEqual(MarkupStore(root: dir).open(file, fallbackScale: 1)?.doc.scale, 2, "144 dpi is Retina")
    }

    func testOutlinesAndFills() throws {
        // a flat white picture, so fill and gaps are easy to read
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let white = ctx.makeImage()!
        var d = MarkupDoc(width: 300, height: 200, scale: 1)
        let box = CGPoint(x: 40, y: 40), end = CGPoint(x: 260, y: 160)
        d.marks = [Mark(kind: .box, a: box, b: end, color: .blue)]
        let plain = try XCTUnwrap(MarkupRenderer.render(base: white, doc: d))
        XCTAssertEqual(pixel(plain, 150, 100).r, 255, "no fill: the inside stays as it was")
        d.marks[0].fill = .tint
        let tint = pixel(try XCTUnwrap(MarkupRenderer.render(base: white, doc: d)), 150, 100)
        XCTAssertTrue(tint.r > 150 && tint.r < 245 && tint.b > 240, "transparent fill: a light tint of blue shows the picture through (\(tint))")
        d.marks[0].fill = .solid
        let solid = pixel(try XCTUnwrap(MarkupRenderer.render(base: white, doc: d)), 150, 100)
        XCTAssertTrue(solid.r < 60 && solid.b > 200, "solid fill covers it (\(solid))")
        d.marks[0].fill = .none
        // along the top edge, a solid outline is blue everywhere; a dashed one has white gaps
        func edgeWhites(_ img: CGImage) -> Int { (60..<240).filter { pixel(img, $0, 40).r > 200 }.count }
        XCTAssertEqual(edgeWhites(plain), 0)
        d.marks[0].dashed = true
        XCTAssertGreaterThan(edgeWhites(try XCTUnwrap(MarkupRenderer.render(base: white, doc: d))), 20, "dashed: gaps along the outline")
        // a filled shape is grabbed by its inside, an outlined one only near its edge (when something else is under it)
        var h = MarkupDoc(width: 300, height: 200, scale: 1)
        let under = Mark(kind: .box, a: CGPoint(x: 10, y: 10), b: CGPoint(x: 290, y: 190))
        var top = Mark(kind: .ellipse, a: box, b: end)
        h.marks = [under, top]
        XCTAssertEqual(h.hit(CGPoint(x: 150, y: 100), slop: 3), top.id, "inside an empty ellipse still picks it when it is on top (second pass)")
        top.fill = .tint; h.marks[1] = top
        XCTAssertEqual(h.hit(CGPoint(x: 150, y: 100), slop: 3), top.id)
    }

    func testOlderMarksOpenUnchanged() throws {
        let json = #"{"version":1,"width":100,"height":80,"scale":2,"notesOnImage":false,"marks":[{"id":"8C1D5E7A-1111-4C3B-9D7E-2F0A1B2C3D4E","kind":"box","a":[1,2],"b":[50,40],"color":"red","size":2,"text":"","number":0}]}"#
        let d = try JSONDecoder().decode(MarkupDoc.self, from: Data(json.utf8))
        XCTAssertEqual(d.marks.first?.fill, MarkFill.none); XCTAssertEqual(d.marks.first?.dashed, false)
        let back = try JSONDecoder().decode(MarkupDoc.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }

    func testPasteNextAfterMarkingUp() {
        var s = PasteStack(expiry: 0)
        let a = URL(fileURLWithPath: "/a.png"), b = URL(fileURLWithPath: "/b.png"), c = URL(fileURLWithPath: "/c.png")
        _ = s.push(contentsOf: [a, b])
        XCTAssertEqual(s.pushFront(b), b); XCTAssertEqual(s.items, [b, a], "a waiting picture moves to the front, once")
        _ = s.pushFront(c); XCTAssertEqual(s.items, [c, b, a], "one that wasn't waiting goes first")
    }
}
