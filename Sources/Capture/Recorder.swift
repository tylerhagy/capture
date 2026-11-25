import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech
import CaptureCore

/// Screen recording: one stream written straight to a movie file, with the Mac's sound and/or the microphone when asked.
/// Pause closes the piece recorded so far; Resume starts a new piece; Stop joins the pieces. The pieces wait in their own folder, so a quit or crash is put together on the next launch.
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private let library: Library
    var onFinished: (URL) -> Void = { _ in }
    var onStopRequested: () -> Void = {}
    /// True when macOS ended the recording rather than the person; the saved toast then says so.
    var endedOnItsOwn = false
    private var stream: SCStream?, output: SCRecordingOutput?, file: URL?, began = Date()
    private var finishing: CheckedContinuation<Void, Never>?, finishingToken: UUID?, app: String?, stopping = false
    private var segments: [URL] = [], session: URL?, filter: SCContentFilter?, config: SCStreamConfiguration?, outputConfig: SCRecordingOutputConfiguration?
    private var segmentBegan = Date(), before: TimeInterval = 0
    private(set) var paused = false

    static var recoveryRoot: URL {
        if let p = ProcessInfo.processInfo.environment["CAPTURE_RECOVERY_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture/Recording in progress", isDirectory: true)
    }
    var isRecording: Bool { stream != nil || paused }
    var elapsed: TimeInterval { before + (stream == nil ? 0 : Date().timeIntervalSince(segmentBegan)) }

    init(library: Library) { self.library = library }

    struct Note: Codable { var app: String?; var began: Double; var ext: String }

    func start(filter: SCContentFilter, points: CGSize, sourceRect: CGRect?, app: String?, options: CaptureOptions) async -> Bool {
        guard !isRecording else { return false }
        var mic = options.mic; let system = options.system
        if mic, !(await Self.micAllowed()) { mic = false; Toast.show("Microphone is off for Capture, so this recording has no voice") }
        if system, !UserDefaults.standard.bool(forKey: "toldAboutSystemAudio") {
            UserDefaults.standard.set(true, forKey: "toldAboutSystemAudio")
            let a = NSAlert(); a.messageText = "Recording the Mac’s sound"; a.informativeText = "Anything your Mac plays is recorded, including other people on a call. Check that everyone knows, and that your company allows it."
            a.addButton(withTitle: "Record"); a.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true); if a.runModal() != .alertFirstButtonReturn { return false }
        }
        let cfg = SCStreamConfiguration(); self.app = app; if let r = sourceRect { cfg.sourceRect = r }
        let scale = CGFloat(filter.pointPixelScale), cap: CGFloat = 3000, k = min(1, cap / max(points.width * scale, points.height * scale))
        cfg.width = max(2, Int(points.width * scale * k) & ~1); cfg.height = max(2, Int(points.height * scale * k) & ~1)
        cfg.showsCursor = true; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30); cfg.queueDepth = 6
        cfg.capturesAudio = system; cfg.captureMicrophone = mic; cfg.excludesCurrentProcessAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2
        let rc = SCRecordingOutputConfiguration()
        rc.videoCodecType = rc.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        rc.outputFileType = rc.availableOutputFileTypes.contains(.mp4) ? .mp4 : .mov
        self.filter = filter; config = cfg; outputConfig = rc
        let folder = Self.recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { Toast.show("Couldn’t start recording. Try again."); return false }
        session = folder; segments = []; before = 0; paused = false; began = Date()
        let ext = rc.outputFileType == .mp4 ? "mp4" : "mov"
        if let d = try? JSONEncoder().encode(Note(app: app, began: began.timeIntervalSince1970, ext: ext)) { try? d.write(to: folder.appendingPathComponent("recording.json")) }
        guard await startSegment() else { try? FileManager.default.removeItem(at: folder); session = nil; return false }
        stopping = false
        return true
    }

    private func startSegment() async -> Bool {
        guard let filter, let config, let rc = outputConfig, let folder = session else { return false }
        let ext = rc.outputFileType == .mp4 ? "mp4" : "mov", url = folder.appendingPathComponent(String(format: "piece-%03d.%@", segments.count + 1, ext))
        rc.outputURL = url
        let out = SCRecordingOutput(configuration: rc, delegate: self), st = SCStream(filter: filter, configuration: config, delegate: self)
        do { try st.addRecordingOutput(out); try await st.startCapture() }
        catch { NSLog("Capture: could not start recording: \(error)"); Toast.show(segments.isEmpty ? "Couldn’t start recording" : "Couldn’t resume. Stop to keep what you have"); return false }
        stream = st; output = out; file = url; segmentBegan = Date()
        return true
    }
    private func closeSegment() async {
        guard let st = stream else { return }
        let token = UUID(); finishingToken = token
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishing = c
            Task { try? await st.stopCapture(); try? await Task.sleep(nanoseconds: 4_000_000_000); self.resumeFinish(token) }
        }
        before += Date().timeIntervalSince(segmentBegan)
        if let f = file { segments.append(f) }
        stream = nil; output = nil; file = nil
    }
    func pause() async { guard stream != nil, !stopping, !paused else { return }; await closeSegment(); paused = true }
    @discardableResult func resume() async -> Bool {
        guard paused, !stopping else { return false }
        guard await startSegment() else { return false }
        paused = false; return true
    }
    func stop() async {
        guard isRecording, !stopping else { return }; stopping = true
        await closeSegment()
        let pieces = segments, folder = session, at = began
        stream = nil; output = nil; file = nil; paused = false; segments = []; session = nil; filter = nil; config = nil; outputConfig = nil
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
        guard !pieces.isEmpty else { return }
        await assemble(pieces, at: at)
    }
    func assemble(_ pieces: [URL], at: Date) async {
        if pieces.count == 1 { finish(pieces[0], at: at); return }
        let joined = FileManager.default.temporaryDirectory.appendingPathComponent("capture-rec-\(UUID().uuidString).\(pieces[0].pathExtension)")
        do { try await RecordingJoin.join(pieces, to: joined) } catch { NSLog("Capture: could not join the recording: \(error)"); Toast.show("Couldn’t put the recording together."); return }
        finish(joined, at: at)
    }
    func stopForQuit() async { guard isRecording, !stopping else { return }; stopping = true; await closeSegment() }
    @discardableResult
    func recoverIfAny() async -> Int {
        let root = Self.recoveryRoot
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), !dirs.isEmpty else { return 0 }
        var n = 0
        for dir in dirs where dir != session {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let note = (try? Data(contentsOf: dir.appendingPathComponent("recording.json"))).flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("piece-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var whole: [URL] = []
            for f in files { let a = AVURLAsset(url: f); if (try? await a.load(.isPlayable)) == true, let d = try? await a.load(.duration).seconds, d.isFinite, d > 0.3 { whole.append(f) } }
            if !whole.isEmpty { await assemble(whole, at: Date(timeIntervalSince1970: note?.began ?? Date().timeIntervalSince1970)); n += 1 }
            try? FileManager.default.removeItem(at: dir)
        }
        if n > 0 { Toast.show(n == 1 ? "Recovered the recording from last time" : "Recovered \(n) recordings from last time") }
        return n
    }
    private func finish(_ url: URL, at: Date) {
        do { let u = try library.adopt(url, prefix: "Screen recording", move: true, at: at); onFinished(u) }
        catch { NSLog("Capture: could not keep the recording: \(error)"); Toast.show("Couldn’t save the recording. Try again.") }
    }
    private func resumeFinish(_ token: UUID? = nil) { if let token, token != finishingToken { return }; finishing?.resume(); finishing = nil }

    nonisolated func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) { Task { @MainActor in self.resumeFinish() } }
    nonisolated func recordingOutput(_ o: SCRecordingOutput, didFailWithError e: Error) { Task { @MainActor in NSLog("Capture: the recording failed: \(e.localizedDescription)"); self.endedOnItsOwn = true; self.onStopRequested() } }
    nonisolated func stream(_ s: SCStream, didStopWithError e: Error) { Task { @MainActor in if self.stream != nil { self.endedOnItsOwn = true; self.onStopRequested() } } }

    static func micAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Joins the pieces of a paused-and-resumed recording into one video, in order, without re-encoding.
enum RecordingJoin {
    enum Failure: Error { case nothingToJoin, noExport }
    static func join(_ pieces: [URL], to out: URL) async throws {
        guard !pieces.isEmpty else { throw Failure.nothingToJoin }
        let comp = AVMutableComposition()
        var tracks: [AVMediaType: [AVMutableCompositionTrack]] = [:]
        var cursor = CMTime.zero
        for url in pieces {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            for type in [AVMediaType.video, .audio] {
                for (n, src) in (try await asset.loadTracks(withMediaType: type)).enumerated() {
                    if tracks[type, default: []].count <= n, let t = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        if type == .video { t.preferredTransform = try await src.load(.preferredTransform) }
                        tracks[type, default: []].append(t)
                    }
                    guard n < tracks[type, default: []].count else { continue }
                    let own = try await src.load(.timeRange)
                    let length = CMTimeMinimum(own.duration, CMTimeSubtract(duration, own.start))
                    guard length.seconds > 0 else { continue }
                    try tracks[type]![n].insertTimeRange(CMTimeRange(start: own.start, duration: length), of: src, at: CMTimeAdd(cursor, own.start))
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw Failure.noExport }
        try await session.export(to: out, as: out.pathExtension.lowercased() == "mov" ? .mov : .mp4)
    }
}
