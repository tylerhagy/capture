import CoreGraphics
import Foundation

/// Joins frames of a region taken while it scrolled into one tall picture.
///
/// Each frame is reduced to a signature: for every pixel row, a few dozen grey samples across it (the far edges are left out, where scroll bars come and go).
/// Two frames are compared in three parts: rows that did not move at the top (a sticky header), rows that did not move at the bottom (a sticky footer),
/// and the band between, which is searched for how far it moved up. Only the newly revealed rows of each frame are added.
public enum Stitcher {
    public typealias Signature = [[UInt8]]
    static let samples = 64
    /// Rows this alike (mean grey difference, 0–255) count as the same row.
    static let sameRow: Float = 1.5
    /// A band that matches no better than this is not a match (the page jumped, or something changed).
    static let goodMatch: Float = 6

    public struct Match: Equatable, Sendable {
        public var top: Int        // rows that stayed put at the top
        public var bottom: Int     // rows that stayed put at the bottom
        public var shift: Int      // how many rows the band between moved up; 0 means nothing moved
    }

    // MARK: signatures
    public static func signature(_ image: CGImage) -> Signature? {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let left = max(1, w / 100), right = w - max(4, w * 4 / 100)            // leave out the edges, where an overlay scroll bar appears while scrolling
        let span = max(1, right - left)
        let cols = (0..<samples).map { left + $0 * span / samples }
        return (0..<h).map { y in let row = y * w; return cols.map { buf[row + $0] } }       // row 0 is the top of the picture
    }

    @inline(__always) static func diff(_ a: [UInt8], _ b: [UInt8]) -> Float {
        var s = 0; for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Float(s) / Float(a.count)
    }

    /// Whether two frames show the same thing (the page has stopped scrolling).
    public static func same(_ a: Signature, _ b: Signature) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where diff(a[i], b[i]) >= sameRow { return false }
        return true
    }

    // MARK: matching two frames
    /// How `b` follows `a`. `hint` is the expected move in rows (known when we scrolled it ourselves); it settles ties on plain, repetitive pages.
    public static func match(_ a: Signature, _ b: Signature, hint: Int? = nil) -> Match? {
        let h = min(a.count, b.count)
        guard h > 16 else { return nil }
        var top = 0
        while top < h && diff(a[top], b[top]) < sameRow { top += 1 }
        if top == h { return Match(top: h, bottom: 0, shift: 0) }
        top = min(top, h * 2 / 5)
        var bottom = 0
        while bottom < h - top && diff(a[h - 1 - bottom], b[h - 1 - bottom]) < sameRow { bottom += 1 }
        bottom = min(bottom, h * 2 / 5)
        let lo = top, n = h - bottom - top
        guard n > 16 else { return nil }
        let minOverlap = max(8, n / 10)
        guard n - minOverlap >= 1 else { return nil }
        var errs = [Float](repeating: .infinity, count: n)
        var best = Float.infinity
        for d in 1...(n - minOverlap) {
            let overlap = n - d, step = max(1, overlap / 160)
            var s: Float = 0, c = 0, i = 0
            while i < overlap {
                s += diff(a[lo + d + i], b[lo + i]); c += 1
                if c > 24, s / Float(c) > best + 10 { break }                     // already far worse than the best: stop early
                i += step
            }
            let e = s / Float(max(c, 1)); errs[d] = e
            if e < best { best = e }
        }
        guard best < goodMatch else { return nil }
        let finite = errs.filter { $0.isFinite }.sorted()                              // the match has to stand out from the rest, or it is luck (plain gaps match anything)
        if finite.count > 8, best > 0.5, best > finite[finite.count / 2] * 0.35 { return nil }
        let near = (1...(n - minOverlap)).filter { errs[$0] <= best + 0.75 }
        let shift: Int
        if let hint, hint > 0 { shift = near.min { abs($0 - hint) < abs($1 - hint) } ?? near[0] } else { shift = near.min() ?? 1 }
        return Match(top: top, bottom: bottom, shift: shift)
    }

    // MARK: joining
    /// Joins the frames into one picture. `hints[i]` is the expected move between frame i-1 and frame i. Frames that do not follow on are skipped.
    /// `maxHeight` caps the result (in pixels), so a page that never ends still gives a picture.
    public static func stitch(_ frames: [CGImage], hints: [Int?] = [], maxHeight: Int = 32_000) -> CGImage? {
        guard let first = frames.first else { return nil }
        let sigs = frames.map { signature($0) }
        guard let s0 = sigs[0] else { return first }
        _ = s0
        var pieces: [(CGImage, Int, Int)] = []          // image, first row, end row (top-down, pixels)
        // `emitted`: in the last accepted frame, the row up to which its content is already in the picture. Rows below it (a footer, or plain rows that only
        // looked like one) are added later from the next frame, or from the last frame at the very end, so nothing is lost or repeated.
        var last = 0, emitted = 0, total = 0, started = false
        for i in 1..<max(frames.count, 1) where i < frames.count {
            guard total < maxHeight, let a = sigs[last], let b = sigs[i], frames[i].width == frames[last].width, frames[i].height == frames[last].height,
                  let m = match(a, b, hint: i < hints.count ? hints[i] : nil), m.shift > 0 else { continue }
            let h = frames[i].height
            if !started { emitted = frames[0].height - m.bottom; pieces.append((frames[0], 0, emitted)); total = emitted; started = true }
            let from = max(0, emitted - m.shift), to = max(h - m.bottom, from)
            if to > from { pieces.append((frames[i], from, to)); total += to - from }
            last = i; emitted = to
        }
        guard started else { return first }
        let lh = frames[last].height
        if emitted < lh { pieces.append((frames[last], emitted, lh)); total += lh - emitted }
        let w = first.width
        guard let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = 0                                                                  // from the top
        for (img, r0, r1) in pieces where r1 > r0 {
            guard let cut = img.cropping(to: CGRect(x: 0, y: r0, width: w, height: r1 - r0)) else { continue }
            let hgt = r1 - r0
            ctx.draw(cut, in: CGRect(x: 0, y: total - y - hgt, width: w, height: hgt))
            y += hgt
        }
        guard let whole = ctx.makeImage() else { return nil }
        return total > maxHeight ? whole.cropping(to: CGRect(x: 0, y: 0, width: w, height: maxHeight)) : whole
    }
}
