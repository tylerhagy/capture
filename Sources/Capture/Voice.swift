import AppKit
import AVFoundation
import Speech
import CaptureCore

/// A voice thought: the microphone, turned into words on this Mac as you speak.
/// When it stops, the words go on the clipboard and into the library; the audio is kept beside them unless that is turned off.
@MainActor
final class VoiceNote {
    private let library: Library
    var onFinished: (URL) -> Void = { _ in }
    var onChange: () -> Void = {}
    let bar = VoiceBar()
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var assembler = TranscriptAssembler()
    private var task: SFSpeechRecognitionTask?
    private let tap = TapBox()
    private var fileURL: URL?
    private var started = Date(), ticker: Timer?, roller: Timer?
    private(set) var recording = false
    private var settling = false

    var keepAudio: Bool { (UserDefaults.standard.object(forKey: "voice.keepAudio") as? Bool) ?? true }
    var seconds: Int { recording ? Int(Date().timeIntervalSince(started)) : 0 }

    init(library: Library) {
        self.library = library
        bar.onStop = { [weak self] in self?.stop() }
        bar.onCancel = { [weak self] in self?.cancel() }
    }

    /// The shortcut: start, or stop when it is already listening.
    func toggle() { if recording { stop() } else { Task { await begin() } } }

    func begin() async {
        guard !recording, !settling else { return }
        guard let rec = recognizer, rec.isAvailable else { Toast.show("Speech to text isn’t available on this Mac"); return }
        guard await Recorder.micAllowed() else { fail("Capture can’t use the microphone. Allow it in System Settings.", pane: "Privacy_Microphone"); return }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined { status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } } }
        guard status == .authorized else { fail("Capture can’t use speech recognition. Allow it in System Settings.", pane: "Privacy_SpeechRecognition"); return }
        start()
    }

    private func start() {
        assembler = TranscriptAssembler()
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { Toast.show("No microphone was found"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-voice-\(UUID().uuidString).m4a")
        tap.file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: Int(format.channelCount), AVEncoderBitRateKey: 64_000])
        fileURL = tap.file == nil ? nil : url
        newRequest()
        input.removeTap(onBus: 0)
        let box = tap
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in box.handle(buffer) }
        do { try engine.start() } catch { discardFile(); Toast.show("Couldn’t start the microphone"); return }
        recording = true; started = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        roller = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.roll() } }       // Apple cuts a single request near a minute
        bar.show(); tick(); onChange()
    }
    private func newRequest() {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true; r.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }      // nothing leaves this Mac
        assembler.beginRequest(); tap.request = r
        task = recognizer?.recognitionTask(with: r) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false, off = (error as NSError?)?.localizedDescription.lowercased().contains("dictation") ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(text, final: final, dictationOff: off) } }
        }
    }
    private func roll() { guard recording else { return }; tap.request?.endAudio(); newRequest() }
    private func heard(_ text: String?, final: Bool, dictationOff: Bool) {
        if let t = text, !t.isEmpty { assembler.update(t, isFinal: final) }
        if dictationOff, recording || settling { abandon(); fail("Turn on Dictation in System Settings (Keyboard ▸ Dictation), then try again.", pane: "Keyboard"); return }
        if settling && final { finish() } else if recording { tick() }
    }
    private func tick() { bar.render(seconds: Int(Date().timeIntervalSince(started)), tail: String(assembler.tail.suffix(90)), level: tap.level); onChange() }

    func stop() {
        guard recording else { return }
        recording = false; ticker?.invalidate(); roller?.invalidate()
        engine.stop(); engine.inputNode.removeTap(onBus: 0); tap.request?.endAudio(); tap.request = nil
        settling = true; bar.render(seconds: Int(Date().timeIntervalSince(started)), tail: "Writing it down…", level: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { if self.settling { self.finish() } } }
    }
    func cancel() { abandon(); bar.hide(); onChange() }
    private func abandon() {
        recording = false; settling = false; ticker?.invalidate(); roller?.invalidate()
        if engine.isRunning { engine.stop() }; engine.inputNode.removeTap(onBus: 0); tap.request?.endAudio(); tap.request = nil; task?.cancel(); discardFile()
    }
    private func discardFile() { tap.file = nil; if let u = fileURL { try? FileManager.default.removeItem(at: u) }; fileURL = nil }

    private func finish() {
        settling = false; task?.cancel(); tap.file = nil
        defer { discardFile(); bar.hide(); onChange() }
        let text = assembler.text
        guard !text.isEmpty else { Toast.show("Didn’t catch anything"); return }
        save(text: text, audio: keepAudio ? fileURL : nil, at: started)
    }
    /// Words (and the audio, if kept) into the library. Separate so the self-test can check it without a microphone.
    func save(text: String, audio: URL?, at: Date) {
        do {
            var item: URL
            if let audio, (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 {
                item = try library.adopt(audio, prefix: "Voice thought", move: true, at: at)
                try text.write(to: item.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                if audio == fileURL { fileURL = nil }
            } else {
                item = try library.save(Data(text.utf8), prefix: "Voice thought", ext: "txt", at: at)
            }
            onFinished(item)
        } catch { NSLog("Capture: could not keep the voice thought: \(error)"); Toast.show("Couldn’t save the voice thought") }
    }
    private func fail(_ message: String, pane: String) {
        Toast.show(message)
        let url = pane == "Keyboard" ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension" : "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// What the microphone's audio thread reads and writes. Guarded by a lock.
private final class TapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?, _file: AVAudioFile?, _level: Double = 0
    var request: SFSpeechAudioBufferRecognitionRequest? { get { lock.lock(); defer { lock.unlock() }; return _request } set { lock.lock(); _request = newValue; lock.unlock() } }
    var file: AVAudioFile? { get { lock.lock(); defer { lock.unlock() }; return _file } set { lock.lock(); _file = newValue; lock.unlock() } }
    var level: Double { lock.lock(); defer { lock.unlock() }; return _level }
    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = _request, f = _file; lock.unlock()
        r?.append(buffer)
        if let f { try? f.write(from: buffer) }
        if let ch = buffer.floatChannelData?[0] {
            var sum: Float = 0; let n = Int(buffer.frameLength); for i in 0..<n { sum += ch[i] * ch[i] }
            lock.lock(); _level = min(1, Double(n > 0 ? sqrt(sum / Float(n)) : 0) * 6); lock.unlock()
        }
    }
}

/// The small bar while a voice thought is being heard: time, the last words, Stop and Cancel.
@MainActor
final class VoiceBar {
    var onStop: () -> Void = {}, onCancel: () -> Void = {}
    private let panel: NSPanel
    private let box = Themed(frame: .zero), dot = NSView(), time = NSTextField(labelWithString: "0:00"), words = NSTextField(labelWithString: "")
    private var stopButton: PillButton!, cancelButton: PillButton!
    private final class Target: NSObject { var stop: () -> Void = {}, cancel: () -> Void = {}; @objc func s() { stop() }; @objc func c() { cancel() } }
    private let target = Target()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; panel.sharingType = .none
        box.fill = Intent.background; box.stroke = Intent.hairline; box.radius = 20
        box.frame = NSRect(x: 0, y: 0, width: 460, height: 56); panel.contentView = box
        dot.wantsLayer = true; dot.layer?.backgroundColor = Intent.red.cgColor; dot.layer?.cornerRadius = 5; dot.frame = NSRect(x: 18, y: 23, width: 10, height: 10)
        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold); time.textColor = Intent.ink; time.frame = NSRect(x: 36, y: 17, width: 48, height: 22)
        words.font = Intent.font(Intent.caption); words.textColor = Intent.muted; words.lineBreakMode = .byTruncatingHead; words.frame = NSRect(x: 86, y: 19, width: 216, height: 18)
        target.stop = { [weak self] in self?.onStop() }; target.cancel = { [weak self] in self?.onCancel() }
        stopButton = PillButton("Stop", symbol: "stop.fill", style: .danger, target: target, action: #selector(Target.s))
        cancelButton = PillButton("Cancel", style: .text, target: target, action: #selector(Target.c))
        cancelButton.frame.origin = NSPoint(x: 460 - 14 - cancelButton.frame.width, y: 12)
        stopButton.frame.origin = NSPoint(x: cancelButton.frame.minX - 6 - stopButton.frame.width, y: 12)
        [dot, time, words, stopButton, cancelButton].forEach { box.addSubview($0) }
    }
    var isVisible: Bool { panel.isVisible }
    var contentViewForTesting: NSView { box }
    var tailForTesting: String { words.stringValue }
    func render(seconds: Int, tail: String, level: Double) {
        time.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
        words.stringValue = tail.isEmpty ? "Listening…" : tail
        dot.alphaValue = 0.45 + 0.55 * CGFloat(min(1, level * 1.5))
    }
    func show() {
        let s = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrameOrigin(NSPoint(x: s.frame.midX - 230, y: s.frame.minY + 92)); panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    /// For tests: draw the bar without showing it.
    func snapshot() -> NSBitmapImageRep? { let r = box.bitmapImageRepForCachingDisplay(in: box.bounds); if let r { box.cacheDisplay(in: box.bounds, to: r) }; return r }
}
