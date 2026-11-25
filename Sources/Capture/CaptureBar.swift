import AppKit
import DesignKit

enum CapturePhase: Equatable { case choosing, recording, saving, scrolling }

/// A button with words. A filled black or red button is what happens next; a button with a line around it is a setting; a plain word is a way out.
final class PillButton: NSButton {
    enum Style { case primary, danger, destructive, option, text, chosen, unchosen }
    var style: Style = .text, label = "", symbol: String?, isOn = false, fixedWidth: CGFloat?

    convenience init(_ label: String, symbol: String? = nil, style: Style = .text, on: Bool? = nil, width: CGFloat? = nil, target: AnyObject?, action: Selector) {
        self.init(frame: .zero); self.label = label; self.symbol = symbol; self.style = style; self.isOn = on ?? false; self.fixedWidth = width; self.target = target; self.action = action
        isBordered = false; wantsLayer = true; setButtonType(.momentaryChange); imagePosition = .imageLeading; imageHugsTitle = true; alignment = .center; update()
    }
    func update() {
        let ink = Intent.ink, grey = Intent.muted
        var bg = NSColor.clear, fg = ink, border: NSColor?, weight = NSFont.Weight.medium, sym = symbol, radius: CGFloat = 15
        switch style {
        case .primary: bg = NSColor(DK.primary); fg = NSColor(DK.primaryForeground)
        case .danger: bg = Intent.red; fg = .white
        case .destructive: bg = Intent.wash; fg = Intent.danger
        case .chosen: bg = Intent.background; fg = ink; radius = 13
        case .unchosen: fg = grey; weight = .regular; radius = 13
        case .option: bg = Intent.background; border = isOn ? ink : Intent.hairline; fg = isOn ? ink : grey
        case .text: fg = grey; weight = .regular
        }
        colors = (bg, border)
        layer?.cornerRadius = radius; paintLayer()
        attributedTitle = NSAttributedString(string: label, attributes: [.foregroundColor: fg, .font: Intent.font(Intent.caption, weight)])
        if let sym { image = NSImage(systemSymbolName: sym, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)); contentTintColor = fg } else { image = nil }
        sizeToFit(); frame.size = NSSize(width: fixedWidth ?? (frame.width + (style == .text ? 10 : 20)), height: style == .chosen || style == .unchosen ? 28 : 32)
    }
    private var colors: (NSColor, NSColor?) = (.clear, nil)
    private func paintLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = colors.0.cgColor; layer?.borderWidth = colors.1 == nil ? 0 : 1; layer?.borderColor = colors.1?.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paintLayer() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var intrinsicContentSize: NSSize { frame.size }
    override func accessibilityLabel() -> String? { label }
}

/// A row of choices in one pale rounded box, the chosen one in black: Area | Window | Screen.
final class SegmentGroup: Themed {
    init(_ items: [(String, String)], selected: Int, target: AnyObject, action: Selector) {
        super.init(frame: .zero); fill = Intent.track; radius = Intent.radius + 2
        var x: CGFloat = 2
        for (i, (symbol, label)) in items.enumerated() {
            let b = PillButton(label, symbol: symbol, style: i == selected ? .chosen : .unchosen, target: target, action: action); b.tag = i
            b.frame.origin = NSPoint(x: x, y: 2); addSubview(b); x += b.frame.width + 1
        }
        frame.size = NSSize(width: x + 1, height: 32)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The small bar that stays on screen while you capture. One row of controls, one quiet line of help underneath. Never part of what is captured.
final class CapturePanel: NSPanel {
    var onChange: () -> Void = {}, onStop: () -> Void = {}, onExit: () -> Void = {}, onRecord: () -> Void = {}, onKeepRecording: () -> Void = {}
    var onPause: () -> Void = {}, onResume: () -> Void = {}, onDone: () -> Void = {}
    private let options: CaptureOptions
    private let box = Themed(frame: .zero)
    private var parts: [NSView] = []
    private let hintLabel = NSTextField(labelWithString: "")
    private(set) var placed = false
    private(set) var centerX: CGFloat?
    /// For tests: the words on the bar's controls, left to right.
    var labels: [String] { parts.flatMap { v -> [String] in if v is SegmentGroup { return v.subviews.compactMap { ($0 as? PillButton)?.label } }; return [(v as? PillButton)?.label ?? (v as? NSTextField)?.stringValue].compactMap { $0 } } }

    init(options: CaptureOptions) {
        self.options = options
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; hidesOnDeactivate = false; isOpaque = false; backgroundColor = .clear; hasShadow = true; isReleasedWhenClosed = false; isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        box.fill = Intent.background; box.stroke = Intent.hairline; box.radius = 20
        contentView = box
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in MainActor.assumeIsolated { if let s = self, s.placed { s.centerX = s.frame.midX } } }
        hintLabel.font = Intent.font(Intent.caption); hintLabel.textColor = Intent.muted; hintLabel.lineBreakMode = .byTruncatingTail
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func pickTarget(_ b: PillButton) { options.mode = [CaptureMode.area, .window, .screen][b.tag]; onChange() }
    @objc private func keepRecording() { onKeepRecording() }
    @objc private func stop() { onStop() }
    @objc private func pauseRecording() { onPause() }
    @objc private func resumeRecording() { onResume() }
    @objc private func record() { onRecord() }
    @objc private func done() { onDone() }
    @objc private func exit_() { onExit() }
    @objc private func soundMenu(_ b: NSButton) {
        let m = NSMenu()
        let mic = NSMenuItem(title: "Microphone", action: #selector(toggleMic), keyEquivalent: ""); mic.target = self; mic.state = options.mic ? .on : .off
        let sys = NSMenuItem(title: "Mac sound", action: #selector(toggleSystem), keyEquivalent: ""); sys.target = self; sys.state = options.system ? .on : .off
        m.addItem(mic); m.addItem(sys); m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
    @objc private func toggleMic() { options.mic.toggle(); onChange() }
    @objc private func toggleSystem() { options.system.toggle(); onChange() }
    private func divider() -> NSView { let v = Themed(frame: NSRect(x: 0, y: 0, width: 1, height: 22)); v.fill = Intent.hairline; return v }
    var soundSummary: String { options.mic && options.system ? "Mic + Mac" : options.mic ? "Mic" : options.system ? "Mac sound" : "Off" }
    private func text(_ s: String, color: NSColor = Intent.ink, size: CGFloat = 14) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = Intent.font(size, .semibold); l.textColor = color; l.sizeToFit(); return l }

    func render(phase: CapturePhase, seconds: Int, hint: String, canRecord: Bool? = nil, confirmingStop: Bool = false, paused: Bool = false, frames: Int = 0) {
        parts.forEach { $0.removeFromSuperview() }; parts = []; hintLabel.removeFromSuperview()
        var views: [NSView] = []
        switch phase {
        case .recording where confirmingStop:
            views = [text("Stop recording?"), PillButton("Keep recording", style: .option, target: self, action: #selector(keepRecording)), PillButton("Stop and save", symbol: "stop.fill", style: .danger, target: self, action: #selector(stop))]
        case .recording:
            let time = NSTextField(labelWithString: String(format: "%d:%02d", seconds / 60, seconds % 60)); time.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold); time.textColor = Intent.ink; time.sizeToFit()
            if paused { time.textColor = Intent.muted }
            let pauseButton = paused ? PillButton("Resume", symbol: "play.fill", style: .primary, target: self, action: #selector(resumeRecording)) : PillButton("Pause", symbol: "pause.fill", style: .option, target: self, action: #selector(pauseRecording))
            views = [text(paused ? "Paused" : "● Recording", color: paused ? Intent.muted : Intent.red), time, pauseButton, PillButton("Stop recording", symbol: "stop.fill", style: .danger, target: self, action: #selector(stop))]
        case .saving:
            views = [text("Saving…")]
        case .scrolling:
            views = [text("● Capturing", color: Intent.red), text("\(frames) \(frames == 1 ? "frame" : "frames")", color: Intent.muted),
                     PillButton("Done", symbol: "checkmark", style: .primary, target: self, action: #selector(done)), PillButton("Cancel", style: .text, target: self, action: #selector(exit_))]
        case .choosing:
            if !options.scrolling {
                views.append(SegmentGroup([("rectangle.dashed", "Area"), ("macwindow", "Window"), ("display", "Screen")], selected: [CaptureMode.area, .window, .screen].firstIndex(of: options.mode) ?? 0, target: self, action: #selector(pickTarget)))
            } else {
                views.append(text("Scrolling capture"))
            }
            if options.video {
                views.append(divider())
                views.append(PillButton("Sound: \(soundSummary)", symbol: "speaker.wave.2", style: .option, width: 138, target: self, action: #selector(soundMenu)))
                views.append(divider())
                views.append(PillButton("Record", symbol: "circle.fill", style: .danger, target: self, action: #selector(record)))       // always enabled: with nothing chosen it says what to do
                _ = canRecord
            }
            views.append(PillButton("Exit", style: .text, target: self, action: #selector(exit_)))
        }
        var x: CGFloat = 14; let rowH: CGFloat = 34, top: CGFloat = 12, y0: CGFloat = 10 + 16 + 6
        for v in views { v.frame.origin = NSPoint(x: x, y: y0 + (rowH - v.frame.height) / 2); box.addSubview(v); parts.append(v); x += v.frame.width + 8 }
        hintLabel.stringValue = hint; hintLabel.sizeToFit()
        let width = max(x + 6, hintLabel.frame.width + 36, 340)
        hintLabel.frame = NSRect(x: 18, y: 10, width: width - 36, height: 16); box.addSubview(hintLabel)
        let h = y0 + rowH + top
        setContentSize(NSSize(width: width, height: h)); box.frame = NSRect(x: 0, y: 0, width: width, height: h)
        if let cx = centerX, placed { setFrameOrigin(NSPoint(x: cx - width / 2, y: frame.minY)); centerX = cx }
    }
    func show(on screen: NSScreen?) {
        if !placed, let s = screen ?? NSScreen.main { setFrameOrigin(NSPoint(x: s.frame.midX - frame.width / 2, y: s.frame.minY + 92)); placed = true; centerX = s.frame.midX }
        orderFrontRegardless()
    }
    func hide() { orderOut(nil); placed = false; centerX = nil }
    func recentre() { if let s = screen ?? NSScreen.main { var f = frame; f.origin.x = min(max(f.origin.x, s.frame.minX), s.frame.maxX - f.width); setFrameOrigin(f.origin) } }
}
