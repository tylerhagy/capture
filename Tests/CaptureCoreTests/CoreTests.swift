import XCTest
import CoreGraphics
@testable import CaptureCore

// MARK: pictures made for the tests
/// A tall "page": text-like dark marks on white, with plain gaps, from a fixed seed.
private func page(width: Int, height: Int, seed: UInt64) -> [UInt8] {
    var rng = seed, px = [UInt8](repeating: 255, count: width * height * 4)
    func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
    var y = 10
    while y < height - 20 {
        let lineH = 8 + Int(next() % 10), gap = 6 + Int(next() % 30)
        var x = 12
        while x < width - 40 {
            let wordW = 10 + Int(next() % 50), shade = UInt8(20 + next() % 120)
            for yy in y..<min(y + lineH, height) { for xx in x..<min(x + wordW, width) { let i = (yy * width + xx) * 4; px[i] = shade; px[i + 1] = shade; px[i + 2] = shade } }
            x += wordW + 6 + Int(next() % 10)
        }
        y += lineH + gap
    }
    return px
}
private func band(_ width: Int, _ height: Int, _ shade: UInt8) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width { let v: UInt8 = (x / 16 + y / 4) % 2 == 0 ? shade : shade &+ 40; let i = (y * width + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v } }
    return px
}
private func rows(_ px: [UInt8], width: Int, from: Int, to: Int) -> [UInt8] { Array(px[(from * width * 4)..<(to * width * 4)]) }
private func image(_ px: [UInt8], width: Int) -> CGImage {
    let h = px.count / (width * 4)
    let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    px.withUnsafeBytes { memcpy(ctx.data!, $0.baseAddress!, px.count) }
    return ctx.makeImage()!
}

final class StitcherTests: XCTestCase {
    let W = 320

    /// Frames of a page under a sticky header and footer, each scrolled `step` rows further. The result is header + the whole page seen + footer.
    func frames(pageH: Int, view: Int, header: Int, footer: Int, step: Int) -> (frames: [CGImage], expected: CGImage, offsets: [Int]) {
        let content = page(width: W, height: pageH, seed: 7), head = band(W, header, 60), foot = band(W, footer, 140)
        let inner = view - header - footer
        var offsets: [Int] = [], off = 0
        while true { offsets.append(off); if off + inner >= pageH { break }; off = min(off + step, pageH - inner) }
        let fs = offsets.map { image(head + rows(content, width: W, from: $0, to: $0 + inner) + foot, width: W) }
        let expected = image(head + rows(content, width: W, from: 0, to: offsets.last! + inner) + foot, width: W)
        return (fs, expected, offsets)
    }
    func assertSame(_ a: CGImage?, _ b: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no picture", file: file, line: line) }
        XCTAssertEqual(a.height, b.height, "height", file: file, line: line)
        XCTAssertEqual(a.width, b.width, file: file, line: line)
        guard a.height == b.height, let sa = Stitcher.signature(a), let sb = Stitcher.signature(b) else { return }
        let bad = zip(sa, sb).filter { Stitcher.diff($0, $1) > 1 }.count
        XCTAssertEqual(bad, 0, "rows that differ", file: file, line: line)
    }

    func testStickyHeaderAndFooter() {
        let (fs, expected, _) = frames(pageH: 2400, view: 600, header: 60, footer: 40, step: 330)
        assertSame(Stitcher.stitch(fs), expected)
    }
    func testNoChromeAndHints() {
        let (fs, expected, offsets) = frames(pageH: 1800, view: 500, header: 0, footer: 0, step: 300)
        let hints: [Int?] = [nil] + zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        assertSame(Stitcher.stitch(fs, hints: hints), expected)
    }
    func testSmallSteps() {          // a person scrolling slowly by hand: small, uneven moves
        let content = page(width: W, height: 1400, seed: 3)
        let offs = [0, 40, 95, 180, 230, 400, 410, 560, 760, 900]
        let fs = offs.map { image(rows(content, width: W, from: $0, to: $0 + 500), width: W) }
        assertSame(Stitcher.stitch(fs), image(rows(content, width: W, from: 0, to: 1400), width: W))
    }
    func testRepeatedFrameIsSkippedAndSameIsDetected() {
        let (fs, expected, _) = frames(pageH: 1500, view: 500, header: 50, footer: 0, step: 300)
        var withRepeat = fs; withRepeat.insert(fs[1], at: 2)
        assertSame(Stitcher.stitch(withRepeat), expected)
        XCTAssertTrue(Stitcher.same(Stitcher.signature(fs[1])!, Stitcher.signature(fs[1])!))
        XCTAssertFalse(Stitcher.same(Stitcher.signature(fs[0])!, Stitcher.signature(fs[1])!))
    }
    func testOneFrameAndCap() {
        let (fs, _, _) = frames(pageH: 3000, view: 500, header: 0, footer: 0, step: 400)
        XCTAssertEqual(Stitcher.stitch([fs[0]])?.height, 500)
        XCTAssertEqual(Stitcher.stitch(fs, maxHeight: 1200)?.height, 1200)
    }
    func testUnrelatedFrameIsSkipped() {
        let (fs, expected, _) = frames(pageH: 1500, view: 500, header: 0, footer: 0, step: 300)
        var mixed = fs; mixed.insert(image(page(width: W, height: 500, seed: 99), width: W), at: 2)
        assertSame(Stitcher.stitch(mixed), expected)
    }
}

final class PasteStackTests: XCTestCase {
    let a = URL(fileURLWithPath: "/a.png"), b = URL(fileURLWithPath: "/b.png"), c = URL(fileURLWithPath: "/c.png")
    func testPastesInOrder() {
        var s = PasteStack(expiry: 600); let t = Date()
        XCTAssertEqual(s.push(a, now: t), a)                       // the first goes straight on the clipboard
        XCTAssertNil(s.push(b, now: t)); XCTAssertNil(s.push(c, now: t))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.pasted(now: t), b); XCTAssertEqual(s.pasted(now: t), c); XCTAssertNil(s.pasted(now: t))
        XCTAssertEqual(s.count, 0)
    }
    func testExpiresAfterIdle() {
        var s = PasteStack(expiry: 600); let t = Date()
        _ = s.push(a, now: t); _ = s.push(b, now: t)
        XCTAssertEqual(s.push(c, now: t.addingTimeInterval(601)), c)      // an old stack is let go; the new capture is on the clipboard
        XCTAssertEqual(s.items, [c])
        var never = PasteStack(expiry: 0); _ = never.push(a, now: t); _ = never.push(b, now: t.addingTimeInterval(99_999)); XCTAssertEqual(never.count, 2)
    }
    func testRemoveAndMany() {
        var s = PasteStack(); XCTAssertEqual(s.push(contentsOf: [a, b, c]), a)
        XCTAssertEqual(s.remove(a), b); XCTAssertNil(s.remove(c)); XCTAssertEqual(s.items, [b])
        XCTAssertNil(s.push(contentsOf: [c])); XCTAssertEqual(s.moveToFront(c), c); XCTAssertEqual(s.items, [c, b]); XCTAssertNil(s.moveToFront(a))
        s.clear(); XCTAssertEqual(s.count, 0)
    }
}

final class LibraryTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    func lib() throws -> Library { let l = try Library(root: dir); l.remove = { try FileManager.default.removeItem(at: $0) }; return l }

    func testSaveNamesKindsAndOrder() throws {
        let l = try lib(), t = Date().addingTimeInterval(-3600)
        let one = try l.save(Data([1]), prefix: "Screenshot", ext: "png", at: t)
        let two = try l.save(Data([2]), prefix: "Screenshot", ext: "png", at: t)            // same second: never over the first
        XCTAssertNotEqual(one, two); XCTAssertTrue(two.lastPathComponent.hasSuffix("(2).png"))
        try FileManager.default.setAttributes([.creationDate: t.addingTimeInterval(-100)], ofItemAtPath: one.path)
        let audio = try l.save(Data([3]), prefix: "Voice thought", ext: "m4a")
        try "words".write(to: audio.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        let textOnly = try l.save(Data("hi".utf8), prefix: "Voice thought", ext: "txt", at: t.addingTimeInterval(5))
        let items = l.items()
        XCTAssertEqual(items.count, 4, "the words beside a recording are not a separate item")
        XCTAssertEqual(items.first?.id, textOnly.lastPathComponent, "newest first (by when the file was made)"); XCTAssertNotNil(audio)
        XCTAssertEqual(items.first(where: { $0.id == textOnly.lastPathComponent })?.kind, .voice)
        XCTAssertEqual(items.last?.url.lastPathComponent, one.lastPathComponent)
    }
    func testPinsAndCleanup() throws {
        let l = try lib(), now = Date()
        let old = try l.save(Data([1]), prefix: "Screenshot", ext: "png"), oldPinned = try l.save(Data([2]), prefix: "Screenshot", ext: "png"), fresh = try l.save(Data([3]), prefix: "Screen recording", ext: "mov")
        for u in [old, oldPinned] { try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: u.path) }
        l.setPinned([oldPinned.lastPathComponent], true)
        XCTAssertEqual(l.cleanup(olderThan: 0, now: now).count, 0, "0 means never")
        let gone = l.cleanup(olderThan: 30, now: now)
        XCTAssertEqual(gone.map(\.lastPathComponent), [old.lastPathComponent])
        XCTAssertEqual(Set(l.items().map(\.url.lastPathComponent)), [oldPinned.lastPathComponent, fresh.lastPathComponent])
    }
    func testAdoptMovesAndTrashTakesWords() throws {
        let l = try lib()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString).png"); try Data([9]).write(to: outside)
        let inside = try l.adopt(outside, prefix: nil, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path)); XCTAssertTrue(l.contains(inside))
        let audio = try l.save(Data([3]), prefix: "Voice thought", ext: "m4a"), words = audio.deletingPathExtension().appendingPathExtension("txt")
        try "w".write(to: words, atomically: true, encoding: .utf8)
        l.trash([audio]); XCTAssertFalse(FileManager.default.fileExists(atPath: words.path))
    }
}

final class ShortcutTests: XCTestCase {
    func testDefaultsDisplayAndRules() {
        let d = UserDefaults(suiteName: "capture.test.\(UUID().uuidString)")!, store = ShortcutStore(defaults: d)
        XCTAssertEqual(store.shortcut(.screenshot)?.display, "⌃⇧⌘S")
        XCTAssertEqual(store.shortcut(.voice)?.display, "⌃⌘R")
        XCTAssertNil(store.shortcut(.clearStack))
        XCTAssertNotNil(store.set(Shortcut(keyCode: KeyNames.s, modifiers: Shortcut.shift), for: .record), "needs ⌘, ⌃ or ⌥")
        XCTAssertEqual(store.set(Shortcut(keyCode: KeyNames.four, modifiers: Shortcut.command | Shortcut.shift), for: .record), "⇧⌘4 is used by macOS screenshots.")
        XCTAssertEqual(store.set(store.shortcut(.screenshot)!, for: .record), "⌃⇧⌘S is already used for Screenshot.")
        XCTAssertEqual(store.shortcut(.record)?.display, "⌃⇧⌘R", "a refused shortcut changes nothing")
        let f19 = Shortcut(keyCode: 80, modifiers: 0)
        XCTAssertNil(store.set(f19, for: .clearStack), "a function key alone is fine"); XCTAssertEqual(store.shortcut(.clearStack)?.display, "F19")
        XCTAssertNil(store.set(nil, for: .voice)); XCTAssertNil(store.shortcut(.voice), "cleared stays cleared")
        XCTAssertNil(store.reset(.voice)); XCTAssertEqual(store.shortcut(.voice)?.display, "⌃⌘R")
        ShortcutRules.macKeysHandedOver = true; defer { ShortcutRules.macKeysHandedOver = false }
        XCTAssertNil(store.set(CaptureAction.screenshot.macStyleShortcut, for: .screenshot), "⇧⌘4 is free once macOS hands it over")
        XCTAssertEqual(store.shortcut(.screenshot)?.display, "⇧⌘4"); XCTAssertEqual(CaptureAction.voice.macStyleShortcut?.display, "⇧⌘2")
    }
}

final class NativeMessagingTests: XCTestCase {
    func testFramesAndParts() {
        let png = Data((0..<5000).map { UInt8($0 % 251) })
        let chunks = stride(from: 0, to: png.count, by: 1200).map { png[$0..<min($0 + 1200, png.count)] }
        var stream = Data()
        for (i, c) in chunks.enumerated() { stream += NativeMessaging.frame(try! JSONEncoder().encode(NativeMessaging.Part(id: "x", index: i, total: chunks.count, data: Data(c).base64EncodedString(), title: "Jira: board / sprint"))) }
        var at = 0
        var asm = NativeMessaging.Assembly()
        while let m = NativeMessaging.read({ n in let d = stream.subdata(in: at..<min(at + n, stream.count)); at += d.count; return d }) {
            XCTAssertTrue(asm.add(try! JSONDecoder().decode(NativeMessaging.Part.self, from: m)))
        }
        XCTAssertEqual(asm.complete, png)
        XCTAssertEqual(NativeMessaging.fileName(title: asm.title), "Web page – Jira  board   sprint")
        XCTAssertEqual(NativeMessaging.fileName(title: nil), "Web page")
    }
}

final class GeometryTests: XCTestCase {
    func testTranscriptAndRects() {
        var t = TranscriptAssembler(); t.beginRequest(); t.update("hello there"); t.update("hello there friend", isFinal: true); t.beginRequest(); t.update("again")
        XCTAssertEqual(t.text, "hello there friend again")
        XCTAssertEqual(CaptureGeometry.sourceRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), viewHeight: 1000), CGRect(x: 10, y: 930, width: 100, height: 50))
    }
}
