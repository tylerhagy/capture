import SwiftUI
import AppKit
import QuickLookThumbnailing
import CaptureCore
import DesignKit

/// What the menu bar panel shows. The app delegate fills it and handles what it asks for.
@MainActor
final class AppModel: ObservableObject {
    /// One row of types, no "All": each kind has its own list. Walkthroughs are videos made elsewhere and found under ~/Movies, so they are not captures.
    enum Filter: String, CaseIterable { case screenshot = "Screenshots", recording = "Recordings", voice = "Voice", walkthrough = "Walkthroughs" }
    @Published var items: [CaptureItem] = []
    @Published var walkthroughs: [Walkthrough] = []
    @Published var filter: Filter = .screenshot
    @Published var selection: [String] = []                   // in the order chosen, which is the paste order
    @Published var queue: [URL] = []
    @Published var queueEnabled = true
    @Published var recording: String?                          // "0:12" while the screen is recorded
    @Published var voice: String?                              // "0:05" while a voice thought is heard
    @Published var shortcuts: [CaptureAction: String] = [:]
    @Published var scanningWalkthroughs = false

    var act: (Action) -> Void = { _ in }
    enum Action {
        case tool(CaptureAction), stopRecording, stopVoice, settings, clearQueue, queueFront(URL), queueRemove(URL)
        case copy([URL]), reveal([URL]), open(URL), markup(URL), pin([URL], Bool), delete([URL])
        case share([URL]), refreshWalkthroughs, enqueue([URL])
    }

    var shown: [CaptureItem] {
        switch filter {
        case .walkthrough: return []
        case .screenshot: return items.filter { $0.kind == .screenshot }
        case .recording: return items.filter { $0.kind == .recording }
        case .voice: return items.filter { $0.kind == .voice }
        }
    }
    var selectedURLs: [URL] { selection.compactMap { id in items.first { $0.id == id }?.url } }
    private var anchor: String?                                // the last one clicked, where a Shift-click range starts
    func toggle(_ item: CaptureItem) { if let i = selection.firstIndex(of: item.id) { selection.remove(at: i) } else { selection.append(item.id) } }
    /// A click on a tile or its circle. Shift-click selects everything from the last one clicked to this one, in list order.
    func click(_ item: CaptureItem) {
        let ids = shown.map(\.id)
        if NSEvent.modifierFlags.contains(.shift), let a = anchor, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: item.id) {
            for id in ids[min(i, j)...max(i, j)] where !selection.contains(id) { selection.append(id) }
        } else { toggle(item) }
        anchor = item.id
    }
    var allSelected: Bool { !shown.isEmpty && shown.allSatisfy { selection.contains($0.id) } }
    /// Select all (or, when everything shown is already selected, none). Only what the filter shows.
    func toggleAll() { selection = allSelected ? [] : shown.map(\.id); anchor = nil }
    /// What the filter hides is never left selected, so a bulk action only touches what is on screen.
    func keepShownSelected() { let ids = Set(shown.map(\.id)); selection.removeAll { !ids.contains($0) } }
}

/// Thumbnails from Quick Look, kept in memory.
@MainActor
final class Thumbs: ObservableObject {
    static let shared = Thumbs()
    @Published private(set) var images: [URL: NSImage] = [:]
    private var asked: Set<URL> = []
    func image(_ url: URL, size: CGSize) -> NSImage? {
        if let i = images[url] { return i }
        if !asked.contains(url) {
            asked.insert(url)
            let r = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { rep, _ in
                guard let img = rep?.nsImage else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.images[url] = img } }
            }
        }
        return nil
    }
    var pending: Int { asked.count - images.count }
    /// The file changed (marked up): draw its thumbnail again.
    func forget(_ url: URL) { images[url] = nil; asked.remove(url) }
}

// MARK: the panel
struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var dropping = false
    var body: some View {
        VStack(spacing: 0) {
            header
            tools.padding(.horizontal, 14).padding(.bottom, 12)
            if model.recording != nil || model.voice != nil { live.padding(.horizontal, 14).padding(.bottom, 12) }
            if model.queue.count >= 1 && model.queueEnabled { queue.padding(.horizontal, 14).padding(.bottom, 12) }
            Divider().overlay(Color.hairline)
            tabs.padding(.horizontal, 14).padding(.top, 10)
            if model.filter == .walkthrough { WalkthroughsView(model: model) } else { CapturesView(model: model) }
        }
        .onChange(of: model.filter) { model.keepShownSelected(); if model.filter == .walkthrough { model.act(.refreshWalkthroughs) } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { model.act(.enqueue([u])) } } } }
            return true
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: Intent.frame).strokeBorder(DK.foreground, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(6).allowsHitTesting(false) } }
        .frame(width: 392, height: 620)
        .background(Color.panel)
        .font(Intent.ui(13))
        .foregroundStyle(Color.ink)
    }

    private var header: some View {
        HStack {
            Text("Capture").font(Intent.ui(17, .semibold))
            Spacer()
            IconButton("gearshape", label: "Settings", size: .compact) { model.act(.settings) }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            ToolTile(symbol: "camera.viewfinder", title: "Screenshot", keys: model.shortcuts[.screenshot]) { model.act(.tool(.screenshot)) }
            ToolTile(symbol: "arrow.down.to.line.compact", title: "Scrolling", keys: model.shortcuts[.scrolling]) { model.act(.tool(.scrolling)) }
            ToolTile(symbol: "record.circle", title: "Record", keys: model.shortcuts[.record]) { model.act(.tool(.record)) }
            ToolTile(symbol: "waveform", title: "Voice", keys: model.shortcuts[.voice]) { model.act(.tool(.voice)) }
        }
    }

    private var live: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.record).frame(width: 8, height: 8)
            Text(model.recording != nil ? "Recording" : "Listening").font(Intent.ui(13, .semibold))
            Text(model.recording ?? model.voice ?? "").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.muted)
            Spacer()
            Pill(title: "Stop", symbol: "stop.fill", style: .danger) { model.act(model.recording != nil ? .stopRecording : .stopVoice) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Intent.frame).fill(Color.surface))
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paste queue").font(Intent.ui(13, .semibold))
                Text("\(model.queue.count)").font(Intent.ui(13, .semibold)).foregroundStyle(Color.muted)
                Spacer()
                Pill(title: "Clear", style: .text) { model.act(.clearQueue) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.queue.enumerated()), id: \.element) { i, u in
                        QueueTile(url: u, n: i + 1, model: model)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Intent.frame).fill(Color.surface))
    }

    private var tabs: some View {
        SegmentedTabs(selection: $model.filter, items: AppModel.Filter.allCases.map { (key: $0, label: $0.rawValue, count: 0) }, compact: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// MARK: captures
struct CapturesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var thumbs = Thumbs.shared
    @State private var confirmingTrash = false
    @AppStorage("library.cleanupDays") private var cleanupDays = 0       // pins only matter when cleanup is on
    let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    var body: some View {
        VStack(spacing: 0) {
            if !model.shown.isEmpty {
                HStack(spacing: 8) {
                    Button { model.toggleAll() } label: {
                        HStack(spacing: 8) {
                            SelectAllMark(state: model.allSelected ? .all : (model.selection.isEmpty ? .none : .some))
                            Text(model.allSelected ? "Clear selection" : "Select all").font(Intent.ui(12, .medium))
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).dkPointer().keyboardShortcut("a", modifiers: .command).help("Select all (⌘A)")
                    Spacer()
                    Text("\(model.shown.count) \(model.filter.rawValue.lowercased())").font(Intent.ui(12)).foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            if model.shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26)).foregroundStyle(Color.muted)
                    Text("Nothing here yet").foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.shown) { item in tile(item) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            if !model.selection.isEmpty { selectionBar }
        }
        .onChange(of: model.selection.isEmpty) { if model.selection.isEmpty { confirmingTrash = false } }
    }
    private func tile(_ item: CaptureItem) -> some View {
        let order = model.selection.firstIndex(of: item.id)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Thumb(url: item.url, kind: item.kind, size: CGSize(width: 112, height: 78))
                    .overlay(RoundedRectangle(cornerRadius: Intent.radius).stroke(order != nil ? Color.ink : Color.hairline, lineWidth: order != nil ? 2 : 1))
                SelectCircle(order: order.map { $0 + 1 }).onTapGesture { model.click(item) }
                if item.pinned, cleanupDays > 0 { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.ink).padding(5).background(Circle().fill(Color.panel)).padding(4).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            Text(Self.when(item.date)).font(Intent.ui(11)).foregroundStyle(Color.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.act(item.kind == .screenshot ? .markup(item.url) : .open(item.url)) }
        .onTapGesture { model.click(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .dkPointer()
        .help(item.name)
    }
    private var selectionBar: some View {
        let urls = model.selectedURLs, allPinned = model.items.filter { model.selection.contains($0.id) }.allSatisfy(\.pinned)
        let pinned = model.items.filter { model.selection.contains($0.id) && $0.pinned }.count
        if confirmingTrash {
            return AnyView(HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Move \(urls.count) to Trash?").font(Intent.ui(12, .semibold)).lineLimit(1)
                    Text(pinned > 0 && cleanupDays > 0 ? "\(pinned) pinned. You can put them back from the Trash." : "You can put them back from the Trash.").font(Intent.ui(11)).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer()
                Pill(title: "Cancel", style: .text) { confirmingTrash = false }
                Pill(title: "Move to Trash", symbol: "trash", style: .danger) { confirmingTrash = false; model.act(.delete(urls)) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.panel.shadow(.drop(color: .black.opacity(0.12), radius: 6, y: -2))))
        }
        return AnyView(HStack(spacing: 6) {
            Text("\(urls.count) selected").font(Intent.ui(12, .semibold)).lineLimit(1).fixedSize()
            IconButton("xmark", label: "Clear selection", size: .compact) { model.selection = [] }
            Spacer()
            if urls.count == 1, CaptureKind.of(urls[0]) == .screenshot { IconButton("pencil.tip.crop.circle", label: "Mark up", size: .compact) { model.act(.markup(urls[0])) } }
            IconButton("folder", label: "Show in Finder", size: .compact) { model.act(.reveal(urls)) }
            if cleanupDays > 0 { IconButton(allPinned ? "pin.slash" : "pin", label: allPinned ? "Unpin" : "Pin, so cleanup keeps it", size: .compact) { model.act(.pin(urls, !allPinned)) } }
            IconButton("trash", label: "Move to Trash", size: .compact) { if urls.count > 1 { confirmingTrash = true } else { model.act(.delete(urls)) } }
            Pill(title: "Copy", style: .primary) { model.act(.copy(urls)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.panel.shadow(.drop(color: .black.opacity(0.12), radius: 6, y: -2))))
    }
    static func when(_ d: Date) -> String {
        let cal = Calendar.current, f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        if cal.isDateInToday(d) { f.dateFormat = "h:mm a"; return "Today " + f.string(from: d) }
        if cal.isDateInYesterday(d) { f.dateFormat = "h:mm a"; return "Yesterday " + f.string(from: d) }
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}

// MARK: walkthroughs
struct WalkthroughsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.scanningWalkthroughs ? "Looking in Movies…" : "\(model.walkthroughs.count) recent").font(Intent.ui(12)).foregroundStyle(Color.muted)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if model.walkthroughs.isEmpty && !model.scanningWalkthroughs {
                VStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 26)).foregroundStyle(Color.muted)
                    Text("No walkthroughs yet").foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.walkthroughs) { w in row(w); Divider().overlay(Color.hairline).padding(.leading, 14) }
                    }
                }
            }
        }
    }
    private func row(_ w: Walkthrough) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.act(.open(w.video)) } label: {
                ZStack {
                    Thumb(url: w.video, kind: .recording, size: CGSize(width: 96, height: 60), videoMark: false)
                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white).padding(8).background(Circle().fill(Color.black.opacity(0.55)))
                }
            }.buttonStyle(.plain).dkPointer().help("Play")
            VStack(alignment: .leading, spacing: 3) {
                Text(WalkthroughIndex.split(w.title).name).font(Intent.ui(13, .semibold)).lineLimit(2)
                Text(w.place).font(Intent.ui(11)).foregroundStyle(Color.muted).lineLimit(1)
                Text(WalkthroughIndex.split(w.title).date ?? CapturesView.when(w.date)).font(Intent.ui(11)).foregroundStyle(Color.muted)
                HStack(spacing: 4) {
                    Pill(title: "Copy", style: .option, compact: true) { model.act(.copy([w.video])) }
                    Pill(title: "Share", symbol: "square.and.arrow.up", style: .option, compact: true) { model.act(.share([w.video])) }
                    if let s = w.short { Pill(title: "Short cut", symbol: "play.fill", style: .option, compact: true) { model.act(.open(s)) } }
                    IconButton("folder", label: "Show in Finder", size: .compact) { model.act(.reveal([w.video])) }
                }.padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onDrag { NSItemProvider(contentsOf: w.video) ?? NSItemProvider() }
    }
}

// MARK: pieces
struct Thumb: View {
    let url: URL; let kind: CaptureKind; let size: CGSize; var videoMark = true
    @ObservedObject var thumbs = Thumbs.shared
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Intent.radius).fill(Color.surface)
            if kind == .voice {
                VStack(spacing: 4) {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold))
                    Text(snippet).font(Intent.ui(10)).foregroundStyle(Color.muted).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 6)
                }
            } else if let img = thumbs.image(url, size: size) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
            } else {
                Image(systemName: kind == .recording ? "film" : "photo").foregroundStyle(Color.muted)
            }
            if kind == .recording && videoMark { Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.white).padding(4).background(Capsule().fill(Color.black.opacity(0.55))).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(4) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Intent.radius))
    }
    private var snippet: String {
        let t = url.pathExtension.lowercased() == "txt" ? url : url.deletingPathExtension().appendingPathExtension("txt")
        return (try? String(contentsOf: t, encoding: .utf8)).map { String($0.prefix(60)) } ?? ""
    }
}

/// One capture waiting in the paste queue. Click: paste this one next. ×: take it out of the queue. Double-click: open it. Drag: drop it anywhere.
struct QueueTile: View {
    let url: URL; let n: Int; @ObservedObject var model: AppModel
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Thumb(url: url, kind: CaptureKind.of(url), size: CGSize(width: 72, height: 50))
                .overlay(RoundedRectangle(cornerRadius: Intent.radius).stroke(n == 1 ? Color.ink : (hover ? Color.muted : .clear), lineWidth: n == 1 ? 2 : 1))
            NumberBadge(n: n, next: n == 1)
            if hover {
                Button { model.act(.queueRemove(url)) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: 16, height: 16).background(Circle().fill(Color.ink))
                }
                .buttonStyle(.plain).help("Take out of the queue").padding(4).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 72, height: 50)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.act(CaptureKind.of(url) == .screenshot ? .markup(url) : .open(url)) }
        .onTapGesture { if n != 1 { model.act(.queueFront(url)) } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .dkPointer()
        .help(n == 1 ? "Pastes next. Drag it out, or double-click to mark up." : "Click to paste this one next. Double-click to mark up.")
    }
}

/// The circle on each capture. Empty ring: you can select this. Filled, with its place in the paste order: it is selected.
/// The fill is the app's primary color (the one the Copy button wears), so selecting and the action it leads to read as one thing.
struct SelectCircle: View {
    let order: Int?
    var body: some View {
        ZStack {
            if let order {
                Circle().fill(DK.primary)
                Circle().strokeBorder(DK.foreground, lineWidth: 1)
                Text("\(order)").font(Intent.ui(11, .semibold)).foregroundStyle(DK.primaryForeground)
            } else {
                Circle().fill(Color.black.opacity(0.18))
                Circle().strokeBorder(Color.white, lineWidth: 1.5)
                Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5).padding(-0.75)
            }
        }
        .frame(width: 20, height: 20)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        .padding(5)
        .contentShape(Circle())
        .dkPointer()
    }
}

/// The mark by "Select all": empty, a dash while some are selected, a check when all are.
struct SelectAllMark: View {
    enum State { case none, some, all }
    let state: State
    var body: some View {
        ZStack {
            if state == .none { Circle().strokeBorder(DK.mutedForeground, lineWidth: 1.5) }
            else {
                Circle().fill(DK.primary); Circle().strokeBorder(DK.foreground, lineWidth: 1)
                Image(systemName: state == .all ? "checkmark" : "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(DK.primaryForeground)
            }
        }.frame(width: 18, height: 18)
    }
}

struct NumberBadge: View {
    let n: Int; let next: Bool
    var body: some View {
        Text("\(n)").font(Intent.ui(11, .medium)).foregroundStyle(Color.inverseText).frame(minWidth: 18, minHeight: 18)
            .background(Circle().fill(Color.inverse.opacity(next ? 1 : 0.7))).overlay(Circle().stroke(Color.panel, lineWidth: 1.5)).padding(4)
    }
}

struct ToolTile: View {
    let symbol: String, title: String, keys: String?; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(height: 22)
                Text(title).font(Intent.ui(12, .medium))
                ShortcutChip(keys ?? "No shortcut").font(Intent.ui(10))
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Intent.frame).fill(hover ? Color.wash : Color.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.dkPointer()
    }
}

/// Capture's buttons, drawn by DesignKit.
struct Pill: View {
    enum Style { case primary, danger, option, text, destructive }
    let title: String; var symbol: String? = nil; let style: Style; var compact = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: compact ? 9 : 11, weight: .medium)) }
                Text(title).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.dk(variant, size: .compact, tint: style == .destructive ? DK.danger : nil))
        .controlSize(compact ? .mini : .small)
    }
    private var variant: ButtonVariant {
        switch style { case .primary: return .primary; case .danger: return .destructive; case .option: return .outline; case .text: return .ghostLight; case .destructive: return .ghost }
    }
}
