import SwiftUI
import AppKit

// Controls: Button, icon button, Badge, ShortcutChip, text entry, Switch, Checkbox, Tabs.
// Interaction model (DESIGN_SYSTEM.md › Interaction rules): hover is preview (--hover), press collapses
// (--active, the raised edge goes away, the footprint never moves), selection persists (--selected).

// MARK: Button

public enum ButtonVariant: Sendable {
    case primary      // bg primary, primary-foreground, raised
    case secondary    // bg secondary, raised (the default)
    case destructive  // bg danger, danger-background text, raised
    case outline      // 1px border, transparent
    case ghost        // transparent; hover fills
    case ghostLight   // muted text that turns foreground on hover
    case link         // primary ink, underline on hover
    case plain        // inherits everything
}

public enum ButtonSize: Sendable { case compact, medium, large }

public struct DKButtonStyle: ButtonStyle {
    public var variant: ButtonVariant
    public var size: ButtonSize
    public var iconOnly: Bool
    public var fullWidth: Bool
    /// Ink override for ghost/outline text actions (e.g. a destructive "Remove" that should not be a filled button).
    public var tint: Color?
    public init(_ variant: ButtonVariant = .secondary, size: ButtonSize = .medium, iconOnly: Bool = false, fullWidth: Bool = false, tint: Color? = nil) {
        self.variant = variant; self.size = size; self.iconOnly = iconOnly; self.fullWidth = fullWidth; self.tint = tint
    }
    public func makeBody(configuration: Configuration) -> some View {
        DKButtonBody(configuration: configuration, variant: variant, size: size, iconOnly: iconOnly, fullWidth: fullWidth, tint: tint)
    }
}

public extension ButtonStyle where Self == DKButtonStyle {
    static func dk(_ v: ButtonVariant = .secondary, size: ButtonSize = .medium, iconOnly: Bool = false, fullWidth: Bool = false, tint: Color? = nil) -> DKButtonStyle {
        DKButtonStyle(v, size: size, iconOnly: iconOnly, fullWidth: fullWidth, tint: tint)
    }
}

struct DKButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ButtonVariant
    let size: ButtonSize
    let iconOnly: Bool
    let fullWidth: Bool
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @State private var hover = false

    var effectiveSize: ButtonSize { controlSize == .small || controlSize == .mini ? .compact : controlSize == .large ? .large : size }
    var height: CGFloat { effectiveSize == .compact ? Control.compact : effectiveSize == .large ? Control.large : Control.medium }
    var hPad: CGFloat { iconOnly ? 0 : (effectiveSize == .compact ? 12 : 16) }
    var pressed: Bool { configuration.isPressed && enabled }

    var fill: Color {
        switch variant {
        case .primary: DK.primary
        case .secondary: DK.secondary
        case .destructive: DK.danger
        case .outline, .ghost, .ghostLight: pressed ? DK.active : (hover && enabled ? DK.hover : .clear)
        case .link, .plain: .clear
        }
    }
    var ink: Color {
        if let tint, variant == .ghost || variant == .outline || variant == .ghostLight || variant == .link { return tint }
        return switch variant {
        case .primary: DK.primaryForeground
        case .secondary: DK.secondaryForeground
        case .destructive: DK.dangerBackground
        case .outline, .ghost: DK.foreground
        case .ghostLight: hover && enabled ? DK.foreground : DK.mutedForeground
        case .link: DK.primaryInk
        case .plain: Color.primary
        }
    }
    var solid: Bool { variant == .primary || variant == .secondary || variant == .destructive }

    var body: some View {
        if variant == .plain {
            configuration.label.contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: Radius.base, style: .circular).fill(configuration.isPressed && enabled ? DK.active : (hover && enabled ? DK.hover : .clear)))
                .opacity(enabled ? 1 : 0.5).onHover { hover = $0 }.dkPointer(enabled)
                .animation(DKMotion.enter(.fast), value: hover)
        } else if variant == .link {
            configuration.label.type(.caption).foregroundStyle(ink)
                .underline(hover && enabled, color: ink)
                .opacity(enabled ? (pressed ? 0.8 : 1) : 0.5)
                .overlay { Rectangle().fill(Color.white.opacity(0.001)) }
                .contentShape(Rectangle()).onHover { hover = $0 }.dkPointer(enabled)
                .animation(DKMotion.enter(.fast), value: hover)
        } else {
            HStack(spacing: 6) { configuration.label }
                .type(.caption)
                .imageScale(.medium)
                .lineLimit(1)
                .foregroundStyle(ink)
                .padding(.horizontal, hPad)
                .fixedSize(horizontal: !fullWidth, vertical: false)
                .frame(minWidth: iconOnly ? height : nil, maxWidth: fullWidth ? .infinity : nil)
                .frame(width: iconOnly ? height : nil, height: height)
                .background {
                    let shape = RoundedRectangle(cornerRadius: Radius.base, style: .circular)
                    ZStack {
                        shape.fill(fill)
                        // brightness(.95) on hover, (.90) on press, for solid fills
                        if solid { shape.fill(Color.black.opacity(pressed ? 0.16 : hover && enabled ? 0.08 : 0)) }
                    }
                    .elevation(solid ? .raised : .none)
                }
                .overlay {
                    if variant == .outline {
                        RoundedRectangle(cornerRadius: Radius.base, style: .circular).strokeBorder(DK.border)
                    } else if variant == .ghost && hover && enabled && !pressed {
                        RoundedRectangle(cornerRadius: Radius.base, style: .circular).strokeBorder(DK.hover)
                    }
                }
                .opacity(enabled ? 1 : 0.5)
                // The whole button is the click target, text included: a near-invisible layer on top, so nothing inside the label can take the click.
                .overlay { RoundedRectangle(cornerRadius: Radius.base).fill(Color.white.opacity(0.001)) }
                .contentShape(RoundedRectangle(cornerRadius: Radius.base))
                .onHover { hover = $0 }
                .dkPointer(enabled)
                .animation(DKMotion.enter(.fast), value: hover)
                .animation(DKMotion.enter(.fast), value: pressed)
        }
    }
}

/// Icon-only ghost button with a tooltip; the label doubles as the accessibility name.
public struct IconButton: View {
    let system: String
    let label: String
    var size: ButtonSize = .medium
    var variant: ButtonVariant = .ghost
    let action: () -> Void
    public init(_ system: String, label: String, size: ButtonSize = .medium, variant: ButtonVariant = .ghost, action: @escaping () -> Void) {
        self.system = system; self.label = label; self.size = size; self.variant = variant; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: size == .compact ? 13 : 15, weight: .regular))
        }
        .buttonStyle(.dk(variant, size: size, iconOnly: true))
        .help(label).accessibilityLabel(label)
    }
}

/// The visible face of a Menu or picker trigger: compact, quiet, hover previews. `bordered` gives Intent's select trigger.
public struct TriggerLabel: View {
    let text: String
    var icon: String?
    var emphasized: Bool
    var bordered: Bool
    var chevron: Bool
    public init(_ text: String, icon: String? = nil, emphasized: Bool = false, bordered: Bool = false, chevron: Bool = false) {
        self.text = text; self.icon = icon; self.emphasized = emphasized; self.bordered = bordered; self.chevron = chevron
    }
    @State private var hover = false
    public var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .regular)).foregroundStyle(DK.mutedForeground) }
            Text(text).lineLimit(1)
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(DK.mutedForeground) }
        }
        .type(.caption, medium: emphasized)
        .foregroundStyle(emphasized || hover ? DK.foreground : DK.mutedForeground)
        .padding(.horizontal, 8)
        .frame(height: Control.compact)
        .background(RoundedRectangle(cornerRadius: Radius.base).fill(hover ? DK.hover : .clear))
        .overlay { if bordered { RoundedRectangle(cornerRadius: Radius.base).strokeBorder(DK.border) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DKMotion.enter(.fast), value: hover)
        .fixedSize()
    }
}

// MARK: Badge

public struct Badge: View {
    public enum Style: Sendable { case solid, dot }
    let text: String
    var tint: DK.Tint
    var style: Style
    var compact: Bool
    var icon: String?
    public init(_ text: String, tint: DK.Tint = .gray, style: Style = .solid, compact: Bool = false, icon: String? = nil) {
        self.text = text; self.tint = tint; self.style = style; self.compact = compact; self.icon = icon
    }
    public var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if style == .dot { Circle().fill(tint.dot).frame(width: compact ? 6 : 7, height: compact ? 6 : 7) }
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
            Text(text).font(Font(DKFonts.nsFont(.ui, size: compact ? 11 : 12, weight: 500))).lineLimit(1)
        }
        .foregroundStyle(DK.foreground)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 20 : 24)
        .background(RoundedRectangle(cornerRadius: Radius.base).fill(style == .solid ? tint.fill : Color.clear))
        .overlay { if style == .dot { RoundedRectangle(cornerRadius: Radius.base).strokeBorder(DK.border) } }
        .fixedSize()
    }
}

/// Keyboard shortcut hint in the quiet shortcut ink.
public struct ShortcutChip: View {
    let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View { Text(keys).type(.caption).foregroundStyle(DK.shortcutForeground).fixedSize() }
}

// MARK: Text entry (border hairline, hover preview, caret-only focus)

public struct DKFieldStyle: TextFieldStyle {
    public enum Variant: Sendable { case standard, search, inline }
    var variant: Variant
    var invalid: Bool
    public init(_ variant: Variant = .standard, invalid: Bool = false) { self.variant = variant; self.invalid = invalid }
    public func _body(configuration: TextField<Self._Label>) -> some View {
        FieldChrome(variant: variant, invalid: invalid, height: Control.medium) { configuration.textFieldStyle(.plain) }
    }
}

public extension TextFieldStyle where Self == DKFieldStyle {
    static var dk: DKFieldStyle { DKFieldStyle() }
    static func dk(_ v: DKFieldStyle.Variant, invalid: Bool = false) -> DKFieldStyle { DKFieldStyle(v, invalid: invalid) }
}

struct FieldChrome<Content: View>: View {
    let variant: DKFieldStyle.Variant
    let invalid: Bool
    let height: CGFloat?
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        if variant == .inline {
            content().type(.body)
        } else {
            content()
                .type(.caption)
                .foregroundStyle(DK.foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: height)
                .background(RoundedRectangle(cornerRadius: Radius.base).fill(hover && enabled && variant == .standard ? DK.hover : .clear))
                .overlay {
                    if variant == .standard {
                        RoundedRectangle(cornerRadius: Radius.base).strokeBorder(invalid ? DK.danger : DK.border)
                    }
                }
                .opacity(enabled ? 1 : 0.6)
                .onHover { hover = $0 }
                .animation(DKMotion.enter(.fast), value: hover)
        }
    }
}

/// Multiline entry with the same chrome as a field (Textarea).
public struct DKTextArea: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var role: TypeRole
    public init(_ placeholder: String = "", text: Binding<String>, minHeight: CGFloat = 80, role: TypeRole = .caption) {
        _text = text; self.placeholder = placeholder; self.minHeight = minHeight; self.role = role
    }
    @State private var hover = false
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).type(role).foregroundStyle(DK.mutedForeground).padding(.horizontal, 12).padding(.vertical, 8).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(role.font()).tracking(role.tracking)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.vertical, 8)
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: Radius.base).fill(hover ? DK.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: Radius.base).strokeBorder(DK.border))
        .onHover { hover = $0 }
        .animation(DKMotion.enter(.fast), value: hover)
    }
}

// MARK: Switch and Checkbox (checked = primary)

public struct DKSwitchStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { SwitchBody(configuration: configuration) }
    struct SwitchBody: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            HStack(spacing: Space.s2) {
                configuration.label.type(.caption).foregroundStyle(DK.foreground)
                Spacer(minLength: Space.s2)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? DK.primary : (hover ? DK.accent : DK.muted))
                    Capsule().strokeBorder(configuration.isOn ? DK.primary : DK.border)
                    Circle().fill(configuration.isOn ? DK.primaryForeground : DK.card).frame(width: 14, height: 14)
                        .elevation(.raised).padding(2)
                }
                .frame(width: 32, height: 18)
                .elevation(.raised)
                .animation(DKMotion.enter(.fast), value: configuration.isOn)
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .onHover { hover = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

public struct DKCheckboxStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(configuration.isOn ? DK.primary : Color.clear)
                RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? DK.primary : DK.mutedForeground.opacity(0.5))
                if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DK.primaryForeground) }
            }
            .frame(width: 16, height: 16)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            configuration.label.type(.caption).foregroundStyle(DK.foreground)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .animation(DKMotion.enter(.fast), value: configuration.isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

public extension ToggleStyle where Self == DKSwitchStyle { static var dkSwitch: DKSwitchStyle { DKSwitchStyle() } }
public extension ToggleStyle where Self == DKCheckboxStyle { static var dkCheckbox: DKCheckboxStyle { DKCheckboxStyle() } }

// MARK: Tabs

/// Segmented tabs: muted track, a raised card indicator that slides (moderate, never overshoots).
public struct SegmentedTabs<Key: Hashable>: View {
    @Binding var selection: Key
    let items: [(key: Key, label: String, count: Int)]
    var compact: Bool
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme
    public init(selection: Binding<Key>, items: [(key: Key, label: String, count: Int)], compact: Bool = false) {
        _selection = selection; self.items = items; self.compact = compact
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.key) { it in
                let on = selection == it.key
                Button { withAnimation(DKMotion.enter(.moderate)) { selection = it.key } } label: {
                    HStack(spacing: 6) {
                        Text(it.label)
                        if it.count > 0 { Text("\(it.count)").monospacedDigit().foregroundStyle(on ? DK.mutedForeground : DK.shortcutForeground) }
                    }
                    .type(.caption, medium: on)
                    .foregroundStyle(on ? DK.foreground : DK.mutedForeground)
                    .padding(.horizontal, 12)
                    .frame(height: compact ? 24 : Control.compact)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Radius.base)
                                .fill(DK.surfaceRaised)
                                .elevation(.raised)
                                .matchedGeometryEffect(id: "indicator", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(TabPress())
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Radius.base + 2).fill(DK.track))
        .fixedSize()
    }
}

struct TabPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabPressBody(configuration: configuration)
    }
    struct TabPressBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .brightness(hover ? -0.02 : 0)
                .onHover { hover = $0 }
                .dkPointer()
        }
    }
}

/// Underline tabs (h-12, 2px foreground rule under the selected tab).
public struct UnderlineTabs<Key: Hashable>: View {
    @Binding var selection: Key
    let items: [(key: Key, label: String, count: Int)]
    @Namespace private var ns
    public init(selection: Binding<Key>, items: [(key: Key, label: String, count: Int)]) { _selection = selection; self.items = items }
    public var body: some View {
        HStack(spacing: Space.s5) {
            ForEach(items, id: \.key) { it in
                let on = selection == it.key
                Button { withAnimation(DKMotion.enter(.moderate)) { selection = it.key } } label: {
                    HStack(spacing: 6) {
                        Text(it.label)
                        if it.count > 0 { Text("\(it.count)").monospacedDigit().foregroundStyle(DK.shortcutForeground) }
                    }
                    .type(.caption, medium: on)
                    .foregroundStyle(on ? DK.foreground : DK.mutedForeground)
                    .padding(.horizontal, 4)
                    .frame(height: 40)
                    .overlay(alignment: .bottom) {
                        if on { Rectangle().fill(DK.foreground).frame(height: 2).matchedGeometryEffect(id: "rule", in: ns) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DK.border).frame(height: 1) }
    }
}

/// The pointing hand over anything that can be clicked. The system pointer style where there is one (it holds inside menu bar panels),
/// otherwise re-asserted on each mouse move.
struct DKPointer: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(active ? .link : nil)
        } else {
            content.onContinuousHover { phase in
                switch phase {
                case .active: if active { NSCursor.pointingHand.set() }
                case .ended: NSCursor.arrow.set()
                }
            }
        }
    }
}

public extension View {
    func dkPointer(_ active: Bool = true) -> some View { modifier(DKPointer(active: active)) }
}
