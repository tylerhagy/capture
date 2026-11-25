import SwiftUI
import AppKit

// Surfaces, rows and screen patterns. Three default surfaces only (DESIGN_SYSTEM.md › Default surface choices):
// canvas (background), contained section (card, one boundary per group), floating overlay (popover).

// MARK: Proximity highlight: one hover background that eases between rows (moderate tier)

final class HoverTracker: ObservableObject {
    @Published var hovered: AnyHashable?
}

private struct HoverTrackerKey: EnvironmentKey { static let defaultValue: HoverTracker? = nil }
private struct HoverNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var hoverTracker: HoverTracker? { get { self[HoverTrackerKey.self] } set { self[HoverTrackerKey.self] = newValue } }
    var hoverNamespace: Namespace.ID? { get { self[HoverNamespaceKey.self] } set { self[HoverNamespaceKey.self] = newValue } }
}

/// Wrap a list of rows so hover moves as one continuous preview background instead of blinking row to row.
public struct ProximityGroup<Content: View>: View {
    @StateObject private var tracker = HoverTracker()
    @Namespace private var ns
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .environment(\.hoverTracker, tracker)
            .environment(\.hoverNamespace, ns)
            .onHover { if !$0 { withAnimation(DKMotion.exit(.moderate)) { tracker.hovered = nil } } }
    }
}

struct RowSurface: ViewModifier {
    let id: AnyHashable
    let selected: Bool
    let active: Bool
    @Environment(\.hoverTracker) private var tracker
    @Environment(\.hoverNamespace) private var ns
    @State private var localHover = false
    func body(content: Content) -> some View {
        let hovered = tracker.map { $0.hovered == id } ?? localHover
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: Radius.base, style: .circular)
                ZStack {
                    if selected { shape.fill(DK.selected) }
                    if active { shape.fill(DK.active) }
                    if hovered && !selected && !active {
                        if let ns { shape.fill(DK.hover).matchedGeometryEffect(id: "proximity", in: ns) } else { shape.fill(DK.hover) }
                    }
                }
            }
            .onHover { inside in
                if let tracker {
                    if inside { withAnimation(DKMotion.enter(.moderate)) { tracker.hovered = id } }
                } else {
                    withAnimation(DKMotion.enter(.fast)) { localHover = inside }
                }
            }
    }
}

public extension View {
    /// Row interaction surface: hover preview (joins a ProximityGroup if present), persistent selection, pressed state.
    func rowSurface<ID: Hashable>(id: ID, selected: Bool = false, active: Bool = false) -> some View {
        modifier(RowSurface(id: AnyHashable(id), selected: selected, active: active))
    }
}

// MARK: Navigation row (sidebar): 32 regular / 28 compact, caption, muted until hovered or current

public struct NavRow: View {
    let icon: String?
    let title: String
    var count: Int
    var current: Bool
    var compact: Bool
    var attention: Bool
    let action: () -> Void
    public init(_ title: String, icon: String? = nil, count: Int = 0, current: Bool = false, compact: Bool = false, attention: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.count = count; self.current = current; self.compact = compact; self.attention = attention; self.action = action
    }
    @Environment(\.hoverTracker) private var tracker
    public var body: some View {
        let lit = current || tracker?.hovered == AnyHashable(title)
        Button(action: action) {
            HStack(spacing: Space.s2) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: lit ? .medium : .regular))
                        .frame(width: 16, height: 16).foregroundStyle(lit ? DK.foreground : DK.mutedForeground)
                }
                Text(title).type(.caption).lineLimit(1).foregroundStyle(lit ? DK.foreground : DK.mutedForeground)
                Spacer(minLength: Space.s1)
                if attention { Circle().fill(DK.warning).frame(width: 6, height: 6).accessibilityLabel("Needs you") }
                if count > 0 { Text("\(count)").type(.caption).monospacedDigit().foregroundStyle(DK.shortcutForeground) }
            }
            .padding(.leading, Space.s2).padding(.trailing, 10)
            .frame(height: compact ? Control.compact : Control.medium)
            .contentShape(Rectangle())
            .rowSurface(id: title, active: current)
        }
        .buttonStyle(.plain).dkPointer()
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .animation(DKMotion.enter(.fast), value: lit)
    }
}

/// Small sentence-case group label above navigation or a list (never uppercase, never tracked).
public struct GroupLabel: View {
    let text: String
    var trailing: AnyView?
    public init(_ text: String) { self.text = text; trailing = nil }
    public init<T: View>(_ text: String, @ViewBuilder trailing: () -> T) { self.text = text; self.trailing = AnyView(trailing()) }
    public var body: some View {
        HStack(spacing: Space.s2) {
            Text(text).type(.caption, medium: true).foregroundStyle(DK.subtleForeground)   // a heading reads lighter than what it heads
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: Control.medium)
    }
}

// MARK: Content row: leading artwork centered on the first line, title + quiet description, trailing slot

public struct ListRow<Trailing: View>: View {
    let icon: String?
    let title: String
    var subtitle: String?
    var description: String?
    var selected: Bool
    var titleRole: TypeRole
    let trailing: Trailing
    public init(_ title: String, icon: String? = nil, subtitle: String? = nil, description: String? = nil, selected: Bool = false,
                titleRole: TypeRole = .caption, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.icon = icon; self.subtitle = subtitle; self.description = description
        self.selected = selected; self.titleRole = titleRole; self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            if let icon { RowIcon(system: icon) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).type(titleRole).foregroundStyle(DK.foreground).lineLimit(2)
                    if let subtitle { Text(subtitle).type(.caption).foregroundStyle(DK.mutedForeground).lineLimit(1) }
                }
                if let description { Text(description).type(.caption).foregroundStyle(DK.mutedForeground).lineLimit(3) }
            }
            Spacer(minLength: Space.s2)
            trailing
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
        .frame(minHeight: description == nil ? 36 : 48, alignment: .leading)
        .contentShape(Rectangle())
        .rowSurface(id: title, selected: selected)
    }
}

public extension ListRow where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, subtitle: String? = nil, description: String? = nil, selected: Bool = false, titleRole: TypeRole = .caption) {
        self.init(title, icon: icon, subtitle: subtitle, description: description, selected: selected, titleRole: titleRole) { EmptyView() }
    }
}

/// The small muted tile that holds a row's leading glyph (as in Intent's note rows).
public struct RowIcon: View {
    let system: String
    var tint: Color?
    public init(system: String, tint: Color? = nil) { self.system = system; self.tint = tint }
    public var body: some View {
        Image(systemName: system).font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint ?? DK.mutedForeground)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(DK.muted.opacity(0.7)))
    }
}

// MARK: Contained section, settings group, separator

public extension View {
    /// Contained section: card fill and one hairline boundary. Do not nest these.
    func containedSection(padding: CGFloat = Space.s4, radius: CGFloat = Radius.frame) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .circular).fill(DK.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .circular).strokeBorder(DK.border))
    }
    /// A floating overlay surface: popover fill, hairline, overlay elevation.
    func overlaySurface(padding: CGFloat = Space.s1) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Radius.base).fill(DK.popover))
            .overlay(RoundedRectangle(cornerRadius: Radius.base).strokeBorder(DK.border))
            .elevation(.overlay)
    }
}

/// Settings-style group: title above, rows inside one rounded card separated by hairlines.
public struct SettingsGroup<Content: View>: View {
    let title: String?
    var description: String?
    let content: Content
    public init(_ title: String? = nil, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.description = description; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).type(.title).foregroundStyle(DK.foreground)
                    if let description { Text(description).type(.body).foregroundStyle(DK.mutedForeground) }
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.frame).fill(DK.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.frame).strokeBorder(DK.border))
        }
    }
}

/// One settings row: label + description on the left, control on the right, aligned to the first tier.
public struct SettingsRow<Control: View>: View {
    let label: String
    var description: String?
    var last: Bool
    let control: Control
    public init(_ label: String, description: String? = nil, last: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label; self.description = description; self.last = last; self.control = control()
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).type(.body).foregroundStyle(DK.foreground)
                if let description { Text(description).type(.caption).foregroundStyle(DK.mutedForeground) }
            }
            Spacer(minLength: Space.s4)
            control
        }
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s4)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(DK.border).frame(height: 1).padding(.horizontal, 0) } }
    }
}

public struct Hairline: View {
    var vertical = false
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle().fill(DK.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: Screen header, empty / loading states

public struct ScreenHeader<Actions: View>: View {
    let title: String
    var description: String?
    var eyebrow: String?
    let actions: Actions
    public init(_ title: String, description: String? = nil, eyebrow: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.description = description; self.eyebrow = eyebrow; self.actions = actions()
    }
    public var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow { Text(eyebrow).type(.caption).foregroundStyle(DK.mutedForeground) }
                Text(title).type(.display).foregroundStyle(DK.foreground)
                if let description { Text(description).type(.body).foregroundStyle(DK.mutedForeground).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.s3)
            HStack(spacing: Space.s2) { actions }
        }
    }
}

public extension ScreenHeader where Actions == EmptyView {
    init(_ title: String, description: String? = nil, eyebrow: String? = nil) {
        self.init(title, description: description, eyebrow: eyebrow) { EmptyView() }
    }
}

/// Empty state: centered, quiet. Says what the place is for and offers the one obvious next step.
public struct EmptyStateView: View {
    let icon: String?
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondary: (() -> Void)?
    public init(icon: String? = nil, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
                secondaryTitle: String? = nil, secondary: (() -> Void)? = nil) {
        self.icon = icon; self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action
        self.secondaryTitle = secondaryTitle; self.secondary = secondary
    }
    public var body: some View {
        VStack(spacing: Space.s2) {
            if let icon { Image(systemName: icon).font(.system(size: 18, weight: .regular)).foregroundStyle(DK.mutedForeground).padding(.bottom, 4) }
            Text(title).type(.title).foregroundStyle(DK.foreground)
            Text(message).type(.body).foregroundStyle(DK.mutedForeground).multilineTextAlignment(.center).frame(maxWidth: 400)
            if actionTitle != nil || secondaryTitle != nil {
                HStack(spacing: Space.s2) {
                    if let t = actionTitle, let a = action { Button(t, action: a).buttonStyle(.dk(.primary)) }
                    if let t = secondaryTitle, let a = secondary { Button(t, action: a).buttonStyle(.dk(.ghost)) }
                }.padding(.top, Space.s3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Space.s6)
    }
}

/// Skeleton block with a quiet shimmer (off under reduced motion).
public struct Skeleton: View {
    var width: CGFloat?
    var height: CGFloat
    public init(width: CGFloat? = nil, height: CGFloat = 12) { self.width = width; self.height = height }
    @State private var phase: CGFloat = -1
    public var body: some View {
        RoundedRectangle(cornerRadius: Radius.base).fill(DK.muted.opacity(0.75))
            .overlay {
                if !DKMotion.reduced {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, DK.background.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width / 2).offset(x: phase * g.size.width)
                    }.clipShape(RoundedRectangle(cornerRadius: Radius.base))
                }
            }
            .frame(width: width, height: height)
            .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 2 } }
    }
}

// MARK: Notify (toast): a small floating overlay, one line, optional action

public struct NotifyView: View {
    public enum Kind: Sendable { case success, error, info }
    let text: String
    var kind: Kind
    var actionLabel: String?
    var action: (() -> Void)?
    var leading: AnyView?
    let dismiss: () -> Void
    /// `leading` replaces the status icon with a small picture of what happened (Arrange draws the windows it just placed).
    public init(_ text: String, kind: Kind = .success, actionLabel: String? = nil, action: (() -> Void)? = nil, leading: AnyView? = nil, dismiss: @escaping () -> Void) {
        self.text = text; self.kind = kind; self.actionLabel = actionLabel; self.action = action; self.leading = leading; self.dismiss = dismiss
    }
    public var body: some View {
        HStack(alignment: leading == nil ? .firstTextBaseline : .center, spacing: Space.s2) {
            if let leading { leading }
            else {
                Image(systemName: kind == .error ? "exclamationmark.circle" : kind == .info ? "info.circle" : "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(kind == .error ? DK.danger : kind == .info ? DK.info : DK.success)
            }
            Text(text).type(.caption).foregroundStyle(DK.foreground).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let l = actionLabel, let a = action {
                Button(l) { a(); dismiss() }.buttonStyle(.dk(.secondary, size: .compact))
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(.dk(.ghostLight, size: .compact, iconOnly: true)).accessibilityLabel("Dismiss")
        }
        .padding(.leading, Space.s3).padding(.trailing, Space.s1).padding(.vertical, Space.s1)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: Radius.base).fill(DK.popover))
        .overlay(RoundedRectangle(cornerRadius: Radius.base).strokeBorder(DK.border))
        .elevation(.overlay)
        .frame(maxWidth: 480)
    }
}

/// Inverse pill (tooltip-like label on the foreground color).
public struct InversePill: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).type(.caption).foregroundStyle(DK.inverseForeground)
            .padding(.horizontal, Space.s2).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Radius.base).fill(DK.inverse))
    }
}

public struct InlineCode: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).type(.code).foregroundStyle(DK.foreground).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: Radius.base).fill(DK.muted))
    }
}

// MARK: App frame: translucent window chrome, the work in one white panel (rounded-xl, hairline, small shadow)

public struct VibrantBackground: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState
        return v
    }
    public func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

public extension View {
    /// The main work panel inside the window frame.
    func workPanel() -> some View {
        self.background(RoundedRectangle(cornerRadius: Radius.frame, style: .circular).fill(DK.background))
            .clipShape(RoundedRectangle(cornerRadius: Radius.frame, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: Radius.frame, style: .circular).strokeBorder(DK.border))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}
