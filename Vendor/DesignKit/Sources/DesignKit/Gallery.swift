import SwiftUI

/// The live catalog (Intent's /sandbox, native): every token and component, in the current appearance.
/// Keep it open while building a screen: "which padding?" is one glance away.
public struct DesignGallery: View {
    /// Development aid: start the catalog at a later section (used for screenshots).
    var startAt: Int
    public init(startAt: Int = 0) { self.startAt = startAt }
    @State private var counter = 0
    @State private var tab = "Overview"
    @State private var seg = 0
    @State private var on = true
    @State private var checked = true
    @State private var text = ""
    @State private var area = ""
    @State private var selectedRow = "Second row"

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                ScreenHeader("DesignKit", description: "A design system, ported from Intent (Apache-2.0). Five type roles, three surfaces, one interaction model.") {
                    Button("Primary") {}.buttonStyle(.dk(.primary))
                }
                section("Color roles") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.s3)], alignment: .leading, spacing: Space.s3) {
                        swatch("background", DK.background); swatch("foreground", DK.foreground); swatch("card", DK.card)
                        swatch("sidebar", DK.sidebar); swatch("primary", DK.primary); swatch("primary ink", DK.primaryInk)
                        swatch("secondary", DK.secondary); swatch("accent", DK.accent); swatch("muted", DK.muted)
                        swatch("muted foreground", DK.mutedForeground); swatch("shortcut foreground", DK.shortcutForeground)
                        swatch("border", DK.border); swatch("ring", DK.ring); swatch("hover", DK.hover); swatch("active", DK.active)
                        swatch("selected", DK.selected); swatch("danger", DK.danger); swatch("danger background", DK.dangerBackground)
                        swatch("success", DK.success); swatch("warning", DK.warning); swatch("info", DK.info)
                    }
                }
                section("Type roles") {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        typeRow("Display · 22/28 · 500", .display, "Projects")
                        typeRow("Title · 17/24 · 500", .title, "Where is the work going?")
                        typeRow("Body · 15/22 · 400", .body, "Suggestions never change your text on their own.")
                        typeRow("Caption · 13/18 · 400", .caption, "In progress · Work · 86 words")
                        typeRow("Code · 13/20", .code, "~/Library/Application Support/Draft")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Editorial · Source Serif 4 · 18/1.48").type(.caption).foregroundStyle(DK.mutedForeground)
                            Text("I think that, in many ways, the meeting was basically kind of useful.").font(Font(Editorial.font(size: 18)))
                        }
                    }
                }
                section("Buttons") {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        HStack(spacing: Space.s2) {
                            Button("Primary") {}.buttonStyle(.dk(.primary))
                            Button("Secondary") {}.buttonStyle(.dk(.secondary))
                            Button("Outline") {}.buttonStyle(.dk(.outline))
                            Button("Ghost") {}.buttonStyle(.dk(.ghost))
                            Button("Ghost light") {}.buttonStyle(.dk(.ghostLight))
                            Button("Link") {}.buttonStyle(.dk(.link))
                            Button("Delete") {}.buttonStyle(.dk(.destructive))
                        }
                        HStack(spacing: Space.s2) {
                            Button("Compact 28") {}.buttonStyle(.dk(.secondary, size: .compact))
                            Button("Medium 32") {}.buttonStyle(.dk(.secondary))
                            Button("Large 36") {}.buttonStyle(.dk(.secondary, size: .large))
                            Button { } label: { Label("With icon", systemImage: "plus") }.buttonStyle(.dk(.primary))
                            IconButton("ellipsis", label: "More") {}
                            IconButton("xmark", label: "Close", size: .compact) {}
                            Button("Disabled") {}.buttonStyle(.dk(.primary)).disabled(true)
                        }
                    }
                }
                section("Badges and hints") {
                    HStack(spacing: Space.s2) {
                        Badge("Draft"); Badge("In progress", tint: .blue); Badge("Complete", tint: .green)
                        Badge("Needs attention", tint: .amber); Badge("Failed", tint: .red)
                        Badge("Dot", tint: .green, style: .dot); Badge("Compact", tint: .violet, compact: true)
                        ShortcutChip("⌘K"); InversePill("Tooltip"); InlineCode("forms.json")
                    }
                }
                section("Tabs") {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        SegmentedTabs(selection: $seg, items: [(0, "Recent", 0), (1, "Repo", 0), (2, "Status", 3)])
                        UnderlineTabs(selection: $tab, items: [("Overview", "Overview", 0), ("Brief", "Brief", 0), ("Noticed", "Noticed", 2)])
                    }
                }
                section("Text entry and toggles") {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        TextField("Search titles, text and tags", text: $text).textFieldStyle(.dk).frame(maxWidth: 360)
                        DKTextArea("Write a line in your words", text: $area, minHeight: 72).frame(maxWidth: 360)
                        HStack(spacing: Space.s6) {
                            Toggle("Keep out of learning", isOn: $on).toggleStyle(.dkSwitch).frame(width: 220)
                            Toggle("Include samples", isOn: $checked).toggleStyle(.dkCheckbox)
                            TriggerLabel("Chapter / long-form", icon: "text.book.closed", emphasized: true, bordered: true, chevron: true)
                            TriggerLabel("In progress")
                        }
                    }
                }
                section("Rows (hover moves as one highlight)") {
                    HStack(alignment: .top, spacing: Space.s5) {
                        VStack(alignment: .leading, spacing: 2) {
                            GroupLabel("Navigation")
                            ProximityGroup {
                                VStack(spacing: 2) {
                                    NavRow("Write", icon: "square.and.pencil", current: true) {}
                                    NavRow("Review", icon: "checkmark.bubble", count: 2) {}
                                    NavRow("Me", icon: "person.crop.circle", attention: true) {}
                                }
                            }
                        }.frame(width: 220)
                        VStack(alignment: .leading, spacing: 2) {
                            GroupLabel("Content rows")
                            ProximityGroup {
                                VStack(spacing: 2) {
                                    ForEach(["First row", "Second row", "Third row"], id: \.self) { r in
                                        ListRow(r, icon: "doc.text", description: "Leading artwork sits on the first line, not the block's center.", selected: selectedRow == r)
                                            .onTapGesture { selectedRow = r }
                                    }
                                }
                            }
                        }.frame(maxWidth: 420)
                    }
                }
                section("Surfaces") {
                    HStack(alignment: .top, spacing: Space.s4) {
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Text("Contained section").type(.title)
                            Text("One boundary per group. Never nested.").type(.body).foregroundStyle(DK.mutedForeground)
                        }.containedSection()
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Floating overlay").type(.caption, medium: true).padding(10)
                            Text("Menus and popovers only").type(.caption).foregroundStyle(DK.mutedForeground).padding(.horizontal, 10).padding(.bottom, 10)
                        }.overlaySurface().frame(width: 220)
                        NotifyView("Saved a version", actionLabel: "Undo", action: {}, dismiss: {})
                    }
                }
                section("Settings group") {
                    SettingsGroup("Learning", description: "What the app may learn from, by domain.") {
                        SettingsRow("Work writing", description: "Decisions can become evidence within Work.") { Toggle("", isOn: $on).toggleStyle(.dkSwitch).labelsHidden().frame(width: 40) }
                        SettingsRow("Personal messages", description: "Kept out of learning by default.", last: true) { TriggerLabel("Off", bordered: true, chevron: true) }
                    }.frame(maxWidth: Measure.form)
                }
                section("States") {
                    HStack(alignment: .top, spacing: Space.s4) {
                        VStack(alignment: .leading, spacing: Space.s2) { Skeleton(width: 220); Skeleton(width: 160); Skeleton(width: 190) }
                            .containedSection()
                        EmptyStateView(icon: "tray", title: "Inbox is empty", message: "Captures wait here until you decide what they are.", actionTitle: "Capture something", action: {})
                            .frame(height: 220).containedSection(padding: 0)
                    }
                }
                section("Motion") {
                    Text("Fast 80 ms (hover, press, color) · Moderate 160 ms (moving highlights, menus, selection) · Slow 240 ms (panels, takeovers). Exits are shorter and crisp. Nothing overshoots or bounces. Reduced motion settles instantly.")
                        .type(.body).foregroundStyle(DK.mutedForeground).frame(maxWidth: Measure.form, alignment: .leading)
                }
            }
            .padding(Space.s6)
            .frame(maxWidth: Measure.wide, alignment: .leading)
        }
        .background(DK.background)
    }

    static let order = ["Color roles", "Type roles", "Buttons", "Badges and hints", "Tabs", "Text entry and toggles",
                        "Rows (hover moves as one highlight)", "Surfaces", "Settings group", "States", "Motion"]
    @ViewBuilder
    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        if (Self.order.firstIndex(of: title) ?? 0) >= startAt {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(title).type(.title)
                c()
            }
        }
    }
    func swatch(_ name: String, _ c: Color) -> some View {
        HStack(spacing: Space.s2) {
            RoundedRectangle(cornerRadius: 6).fill(c).frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DK.border))
            Text(name).type(.caption).foregroundStyle(DK.mutedForeground)
        }
    }
    func typeRow(_ label: String, _ role: TypeRole, _ sample: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).type(.caption).foregroundStyle(DK.mutedForeground)
            Text(sample).type(role).foregroundStyle(DK.foreground)
        }
    }
}
