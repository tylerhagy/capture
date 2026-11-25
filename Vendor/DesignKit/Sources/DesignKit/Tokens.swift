import SwiftUI
import AppKit
import CoreText

// DesignKit: a native SwiftUI port of the design system from Intent (github.com/intent-hq/cloudlands-fe,
// Apache-2.0, see NOTICE in this folder). Values are taken from its canonical `src/lib/styles/tokens.css`
// and `docs/DESIGN_SYSTEM.md`; the rules in DESIGN_SYSTEM.md (five type roles, three surfaces, hover is
// preview, press collapses, selection persists, exits are crisp, never bounce, never uppercase) apply here too.
// Nothing here uses Intent's name, mark, sounds or icons.

// MARK: Color roles

public enum DK {
    /// HSL triple as written in tokens.css ("h s% l%").
    static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> NSColor {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var (r, g, b) = (0.0, 0.0, 0.0)
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: a)
    }

    static func pair(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: a.redComponent * t + b.redComponent * (1 - t), green: a.greenComponent * t + b.greenComponent * (1 - t),
                       blue: a.blueComponent * t + b.blueComponent * (1 - t), alpha: 1)
    }

    // Raw light/dark values live in Generated.swift (DK.L / DK.D), generated from tokens/tokens.json.

    // Semantic roles (DESIGN_SYSTEM.md › Choose a semantic role). Use these, never physical colors.
    public static let background = pair(L.background, D.background)        // canvas
    public static let foreground = pair(L.foreground, D.foreground)
    public static let card = pair(L.card, D.card)              // contained section
    public static let popover = pair(L.popover, D.popover)           // floating overlay
    public static let primary = pair(L.primary, D.primary)                  // primary action fill
    public static let primaryInk = pair(L.primaryInk, D.primaryInk)        // primary as text (links)
    public static let primaryForeground = pair(L.primaryForeground, D.primaryForeground)
    public static let secondary = pair(L.secondary, D.secondary)
    public static let secondaryForeground = pair(L.secondaryForeground, D.secondaryForeground)
    public static let accent = pair(L.accent, D.accent)                     // solid emphasized surface
    public static let accentForeground = pair(L.accentForeground, D.accentForeground)
    public static let muted = pair(L.muted, D.muted)
    public static let mutedForeground = pair(L.mutedForeground, D.mutedForeground)      // secondary: the line that explains
    public static let subtleForeground = pair(L.subtleForeground, D.subtleForeground)  // meta and section labels
    public static let shortcutForeground = pair(mix(L.mutedForeground, L.background, 0.75), mix(D.mutedForeground, D.background, 0.75))
    public static let danger = pair(L.danger, D.danger)
    public static let dangerBackground = pair(L.dangerBackground, D.dangerBackground)
    public static let border = pair(L.border, D.border)                     // decorative hairline
    public static let input = pair(L.input, D.input)                        // control boundary on hover/focus
    public static let ring = pair(L.ring, D.ring)                           // keyboard focus
    public static let info = pair(L.info, D.info)
    public static let success = pair(L.success, D.success)
    public static let successForeground = pair(L.successForeground, D.successForeground)
    public static let warning = pair(L.warning, D.warning)
    public static let warningInk = pair(L.warningInk, D.warningInk)
    public static let warningForeground = pair(L.warningForeground, D.warningForeground)
    public static let sidebar = pair(L.sidebar, D.sidebar)                  // navigation chrome only
    public static let hover = pair(L.hover, D.hover)                        // preview
    public static let active = pair(L.active, D.active)                     // pressed
    public static let selected = pair(L.selected, D.selected)               // persistent selection
    /// A raised indicator on a track (segmented tabs): card in light, a lifted gray in dark.
    public static let surfaceRaised = pair(L.surfaceRaised, D.surfaceRaised)
    /// The track behind segmented tabs.
    public static let track = pair(L.track, D.track)
    /// Inverse surface (tooltips, value bubbles): paints the foreground color.
    public static let inverse = pair(L.foreground, D.foreground)
    public static let inverseForeground = pair(L.background, D.background)

    /// Categorical/status palette for Badge (Tailwind 500s as used by badge.variants.ts).
    public enum Tint: String, CaseIterable, Sendable {
        case gray, red, orange, amber, yellow, lime, green, emerald, teal, cyan, blue, indigo, violet, purple, fuchsia, pink, rose
        var ns: NSColor {
            func hex(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
            switch self {
            case .gray: return hex(0x71717A)
            case .red: return hex(0xFB2C36)
            case .orange: return hex(0xFF6900)
            case .amber: return hex(0xFE9A00)
            case .yellow: return hex(0xF0B100)
            case .lime: return hex(0x7CCF00)
            case .green: return hex(0x00C950)
            case .emerald: return hex(0x00BC7D)
            case .teal: return hex(0x00BBA7)
            case .cyan: return hex(0x00B8DB)
            case .blue: return hex(0x2B7FFF)
            case .indigo: return hex(0x615FFF)
            case .violet: return hex(0x8E51FF)
            case .purple: return hex(0xAD46FF)
            case .fuchsia: return hex(0xE12AFB)
            case .pink: return hex(0xF6339A)
            case .rose: return hex(0xFF2056)
            }
        }
        public var color: Color { Color(nsColor: ns) }
        /// Solid badge fill: 15% of the hue over the canvas; gray uses the accent role.
        public var fill: Color {
            self == .gray ? DK.accent : DK.pair(DK.mix(ns, L.background, 0.15), DK.mix(ns, D.background, 0.15))
        }
        public var dot: Color { self == .gray ? DK.mutedForeground : color }
    }
}

// MARK: Spacing, sizes, shape





public enum Elevation: Sendable { case none, raised, overlay }

public extension View {
    /// --elevation-raised (a quiet one-pixel lift) or --elevation-overlay (floating overlays only).
    func elevation(_ e: Elevation) -> some View { modifier(ElevationModifier(e: e)) }
}

struct ElevationModifier: ViewModifier {
    let e: Elevation
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let layers: [(Double, Double, Double, Double)]
        switch e {
        case .none: layers = []
        case .raised: layers = dark ? GenElevation.darkRaised : GenElevation.lightRaised
        case .overlay: layers = dark ? GenElevation.darkOverlay : GenElevation.lightOverlay
        }
        // CSS blur → SwiftUI radius is about half. Layers are applied smallest first.
        return layers.reversed().reduce(AnyView(content)) { v, l in
            AnyView(v.shadow(color: .black.opacity(l.3), radius: l.2 / 2, x: l.0, y: l.1))
        }
    }
}

// MARK: Motion (80 / 160 / 240 ms; crisp shorter exits; never overshoot)

public enum MotionTier: Sendable { case fast, moderate, slow }

public enum DKMotion {
    public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func enterDuration(_ t: MotionTier) -> Double { GenMotion.enter[t] ?? 0.16 }
    static func exitDuration(_ t: MotionTier) -> Double { GenMotion.exit[t] ?? 0.12 }
    /// Enter/settle. The linear() springs in tokens.css are monotonic ease-outs; this curve matches them closely.
    public static func enter(_ t: MotionTier = .moderate) -> Animation? {
        reduced ? nil : .timingCurve(GenMotion.enterCurve.0, GenMotion.enterCurve.1, GenMotion.enterCurve.2, GenMotion.enterCurve.3, duration: enterDuration(t))
    }
    /// Crisp exit: cubic-bezier(.33, 1, .68, 1) at the tier's shorter exit duration.
    public static func exit(_ t: MotionTier = .moderate) -> Animation? {
        reduced ? nil : .timingCurve(GenMotion.exitCurve.0, GenMotion.exitCurve.1, GenMotion.exitCurve.2, GenMotion.exitCurve.3, duration: exitDuration(t))
    }
    /// Enter with the tier, leave crisply (fade + small offset, no scale bounce).
    public static func appear(_ t: MotionTier = .moderate, y: CGFloat = 4) -> AnyTransition {
        if reduced { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: y)).animation(enter(t)!),
                           removal: .opacity.animation(exit(t)!))
    }
}

// MARK: Fonts and the five type roles

public enum DKFonts {
    nonisolated(unsafe) private static var registered = false
    /// Registers the bundled OFL fonts (Inter, Source Serif 4, JetBrains Mono). Safe to call repeatedly.
    public static func register() {
        guard !registered else { return }
        registered = true
        for dir in candidateDirs() {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { $0.pathExtension.lowercased() == "ttf" }
            guard !fonts.isEmpty else { continue }
            for f in fonts { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
            return
        }
    }
    static func candidateDirs() -> [URL] {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("Fonts")) }
        if let env = ProcessInfo.processInfo.environment["DESIGNKIT_FONTS"] { c.append(URL(fileURLWithPath: env)) }
        // Development builds: <repo>/Resources/Fonts, found from this source file's location.
        let here = URL(fileURLWithPath: #filePath)
        c.append(here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        return c
    }

    enum Family { case ui, editorial, code }

    static func nsFont(_ family: Family, size: CGFloat, weight: CGFloat, italic: Bool = false) -> NSFont {
        register()
        let name: String
        switch family {
        case .ui: name = GenType.familyNames[.ui] ?? "Inter Variable"
        case .editorial: name = GenType.familyNames[.editorial] ?? "Source Serif 4 Variable"
        case .code: name = GenType.familyNames[.code] ?? "JetBrains Mono"
        }
        var attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: name]
        var variation: [NSNumber: NSNumber] = [NSNumber(value: 0x77676874): NSNumber(value: Double(weight))]   // 'wght'
        if family == .editorial { variation[NSNumber(value: 0x6F70737A)] = NSNumber(value: Double(size)) }       // 'opsz' = auto
        attrs[kCTFontVariationAttribute] = variation
        if italic { attrs[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue] }
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(desc, size, nil) as NSFont
        // If the bundled font is missing, fall back to the system face rather than Helvetica.
        if f.familyName != name {
            switch family {
            case .ui: return NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: (weight - 400) / 500))
            case .editorial: return NSFont(name: "Iowan Old Style", size: size) ?? NSFont.systemFont(ofSize: size)
            case .code: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }
        return f
    }
}

/// The five visual roles (DESIGN_SYSTEM.md › Non-color scales). Emphasis is weight 500 on the same role, never another size.
public enum TypeRole: Sendable, CaseIterable {
    case meta      // 12/16: times, counts, paths, helper text (with subtleForeground)
    case caption   // 13/18, -0.01em: compact controls, navigation, short metadata
    case body      // 15/22, -0.016em: messages, documents, explanatory copy
    case title     // 17/24, 500, -0.016em: section titles
    case display   // 22/28, 500, -0.016em: page titles
    case code      // 13/20 JetBrains Mono

    public var size: CGFloat { GenType.spec(self).size }
    public var lineHeight: CGFloat { GenType.spec(self).lineHeight }
    public var weight: CGFloat { GenType.spec(self).weight }
    public var tracking: CGFloat { GenType.spec(self).trackingEm * size }

    public func nsFont(medium: Bool = false) -> NSFont {
        DKFonts.nsFont(GenType.spec(self).family == .code ? .code : GenType.spec(self).family == .editorial ? .editorial : .ui, size: size, weight: medium ? GenType.emphasisWeight : weight)
    }
    public func font(medium: Bool = false) -> Font { Font(nsFont(medium: medium)) }
}

public extension View {
    /// Apply a type role: family, size, weight, tracking and CSS-style line height (half-leading above and below).
    func type(_ role: TypeRole, medium: Bool = false) -> some View {
        let f = role.nsFont(medium: medium)
        let natural = ceil(f.ascender - f.descender + f.leading)
        let extra = max(0, role.lineHeight - natural)
        return self.font(Font(f)).tracking(role.tracking).lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// Inter at an exact size and weight, for the few sanctioned exceptions (badge microtext 11/12 at 500).
public enum DKFont {
    public static func ui(_ size: CGFloat, weight: CGFloat = 400) -> Font { Font(DKFonts.nsFont(.ui, size: size, weight: weight)) }
}

public enum Editorial {
    /// Intent's serif note: Source Serif 4, 18px / 1.48, optical sizing auto.
    public static func font(size: CGFloat? = nil, weight: CGFloat = 400, italic: Bool = false) -> NSFont {
        DKFonts.nsFont(.editorial, size: size ?? GenType.editorialSize, weight: weight, italic: italic)
    }
    public static let lineHeightMultiple: CGFloat = GenType.editorialLineHeightMultiple
}
