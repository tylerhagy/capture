import AppKit
import SwiftUI
import DesignKit

/// Capture's adapter onto DesignKit (Intent, native). Every color is a DesignKit role with a light and a dark value, so Capture follows the Mac's appearance.
/// AppKit views read these as dynamic NSColors; anything drawn into a layer must be resolved again when the appearance changes (see `Themed`).
enum Intent {
    /// Inter through DesignKit. Emphasis is weight 500, never bolder (DesignKit's rule).
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        (weight.rawValue >= NSFont.Weight.medium.rawValue ? TypeRole.caption.nsFont(medium: true) : TypeRole.caption.nsFont()).withSize(size)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { DKFont.ui(size, weight: weight == .regular ? 400 : 500) }
    static let caption: CGFloat = 13, body: CGFloat = 15, title: CGFloat = 17
    static let radius: CGFloat = Radius.base, frame: CGFloat = Radius.frame

    static let ink = NSColor(DK.foreground)
    static let muted = NSColor(DK.mutedForeground)
    static let background = NSColor(DK.popover)
    static let surface = NSColor(DK.sidebar)
    static let wash = NSColor(DK.selected)
    static let track = NSColor(DK.track)
    static let hairline = NSColor(DK.border)
    static let inverse = NSColor(DK.inverse)
    static let inverseForeground = NSColor(DK.inverseForeground)
    static let danger = NSColor(DK.danger)
    /// Recording red: the same in light and dark, so "recording" always reads the same.
    static let red = NSColor(srgbRed: 0.84, green: 0.19, blue: 0.23, alpha: 1)
}

extension Color {
    static let ink = DK.foreground, muted = DK.mutedForeground, surface = DK.sidebar, wash = DK.selected, hairline = DK.border
    static let panel = DK.popover, inverse = DK.inverse, inverseText = DK.inverseForeground
    static let record = Color(nsColor: Intent.red), destructive = DK.danger
}

/// Layer colors are fixed CGColors, so a view that paints its layer repaints when the Mac switches between light and dark.
class Themed: NSView {
    var fill: NSColor? { didSet { paint() } }
    var stroke: NSColor? { didSet { paint() } }
    var strokeWidth: CGFloat = 0.5
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
            layer?.borderColor = stroke?.cgColor; layer?.borderWidth = stroke == nil ? 0 : strokeWidth
        }
    }
}

/// A small, quiet confirmation over whatever app you are in.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    static var last: String?
    static var silent = false                     // the hidden self-tests never put anything on the screen
    static func show(_ text: String) {
        last = text
        if silent { return }
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text); label.font = Intent.font(14, .medium); label.textColor = Intent.inverseForeground; label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 40)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.ignoresMouseEvents = true; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.sharingType = .none
        let v = Themed(frame: NSRect(origin: .zero, size: size)); v.fill = Intent.inverse; v.radius = 20
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2); v.addSubview(label); p.contentView = v
        let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrameOrigin(NSPoint(x: s.midX - size.width / 2, y: s.maxY - size.height - 24))
        p.alphaValue = 0; p.orderFrontRegardless(); panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}
