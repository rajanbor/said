import AVFoundation
import AppKit

/// A finished recording, shown as the summary in the menu bar.
struct Recording: Codable, Equatable {
    let path: String
    let duration: TimeInterval
    let date: Date
    var transcriptPath: String?
    /// Meeting app the recording was started for (e.g. "Zoom"), if any.
    var source: String? = nil

    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Records the microphone to ~/Music/Said/*.m4a. Everything stays on this Mac.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0...1), newest last — drives the pill animation.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Recorder.barCount)
    @Published private(set) var last: Recording?
    @Published var error: String?
    /// Warning shown in the menu while recording (long silence, low disk space).
    @Published private(set) var notice: String?
    /// True while the mic and system audio are being mixed into the final file.
    @Published private(set) var isSaving = false

    /// Also record what the Mac plays (for manual recordings; meetings always include the meeting app).
    @Published var recordSystemAudio: Bool {
        didSet { UserDefaults.standard.set(recordSystemAudio, forKey: Self.systemAudioKey) }
    }

    /// Meeting that is currently offered for recording (drives the prompt pill).
    @Published private(set) var promptMeeting: MeetingDetector.Meeting?

    let transcriber = Transcriber()
    let meetings = MeetingDetector()

    static let barCount = 18
    private static let lastKey = "lastRecording"
    private static let systemAudioKey = "recordSystemAudio"

    /// Files of the recording in progress.
    private struct Session {
        let final: URL      // <stamp>/said_<stamp>.m4a
        let mic: URL        // <stamp>/.mic.m4a
        let system: URL?    // <stamp>/.system.caf
    }
    private var session: Session?

    // Silence & disk watch
    private var silenceSince: Date?
    private var silenceNotified = false
    private var diskWarned = false
    private var lastDiskCheck = Date.distantPast
    /// Below this meter level (≈ -35 dB) counts as silence; room noise sits around -40…-50.
    private static let silenceLevel: Float = 0.3
    /// Consecutive loud ticks (20/s) needed to count as sound again, so noise spikes don't reset it.
    private var loudTicks = 0
    /// Minutes of silence before suggesting to stop (defaults key "silenceMinutes", default 2).
    private var silenceLimit: TimeInterval {
        let m = UserDefaults.standard.double(forKey: "silenceMinutes")
        return (m > 0 ? m : 2) * 60
    }
    private static let lowDisk: Int64 = 2_000_000_000       // warn
    private static let criticalDisk: Int64 = 500_000_000    // stop (leave room to mix & transcribe)
    private var tap: AnyObject?   // SystemAudioTap (macOS 14.2+)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    /// Set when recording was started from the meeting prompt: the call ending stops it.
    private var recordingMeeting: MeetingDetector.Meeting?
    private var promptTimeout: Task<Void, Never>?

    private lazy var pill = FloatingPanel(size: NSSize(width: 196, height: 38)) {
        PillView().environmentObject(self)
    }
    private lazy var prompt = FloatingPanel(size: NSSize(width: 268, height: 42)) {
        MeetingPromptView().environmentObject(self)
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Said", isDirectory: true)
    }

    init() {
        recordSystemAudio = UserDefaults.standard.bool(forKey: Self.systemAudioKey)
        if let data = UserDefaults.standard.data(forKey: Self.lastKey),
           let rec = try? JSONDecoder().decode(Recording.self, from: data),
           FileManager.default.fileExists(atPath: rec.path) {
            last = rec
        }
        meetings.onStart = { [weak self] in self?.meetingStarted($0) }
        meetings.onEnd = { [weak self] in self?.meetingEnded($0) }
    }

    // MARK: - Meetings

    private func meetingStarted(_ meeting: MeetingDetector.Meeting) {
        guard !isRecording else { return }
        promptMeeting = meeting
        prompt.show()
        // Don't nag: the offer disappears on its own after 30 s.
        promptTimeout?.cancel()
        promptTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.dismissMeetingPrompt()
        }
    }

    private func meetingEnded(_ meeting: MeetingDetector.Meeting) {
        dismissMeetingPrompt()
        if isRecording, recordingMeeting == meeting { stop() }
    }

    func acceptMeetingPrompt() {
        let meeting = promptMeeting
        dismissMeetingPrompt()
        recordingMeeting = meeting
        start()
    }

    func dismissMeetingPrompt() {
        promptTimeout?.cancel()
        promptTimeout = nil
        promptMeeting = nil
        prompt.hide()
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        error = nil
        dismissMeetingPrompt()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.beginRecording() } else { self.denied() }
                }
            }
        default:
            denied()
        }
    }

    func stop() {
        guard let recorder, let session, isRecording else { return }
        let duration = recorder.currentTime
        recorder.stop()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        self.session = nil
        isRecording = false
        notice = nil
        Notifier.shared.clear(id: "silence")
        pill.hide()

        let source = recordingMeeting?.name
        recordingMeeting = nil
        isSaving = true
        Task {
            let url = await Self.finish(session)
            isSaving = false
            save(Recording(path: url.path, duration: duration, date: Date(), source: source))
            if transcriber.isInstalled { transcribeLast() }
        }
    }

    /// Mixes mic + system audio into the final .m4a (or just keeps the mic) and removes temp files.
    private static func finish(_ s: Session) async -> URL {
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: s.mic)
            if let system = s.system { try? fm.removeItem(at: system) }
        }
        if let system = s.system,
           let size = try? fm.attributesOfItem(atPath: system.path)[.size] as? Int, size > 16 * 1024,
           await AudioMixer.mix([s.mic, system], into: s.final) {
            return s.final
        }
        try? fm.moveItem(at: s.mic, to: s.final)
        return s.final
    }

    /// Runs local transcription for the last recording (automatic when the model is installed).
    func transcribeLast() {
        guard let rec = last else { return }
        Task {
            guard let url = await transcriber.transcribe(rec) else { return }
            var updated = rec
            updated.transcriptPath = url.path
            if last?.path == rec.path { save(updated) }
        }
    }

    private func save(_ rec: Recording) {
        last = rec
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: Self.lastKey)
        }
    }

    private func beginRecording() {
        if let free = Self.freeSpace(), free < Self.criticalDisk {
            error = "Za mało miejsca na dysku (\(Self.bytes(free))). Zwolnij miejsce, żeby nagrywać."
            recordingMeeting = nil
            return
        }
        Notifier.shared.requestPermission()
        silenceSince = nil
        silenceNotified = false
        diskWarned = false
        notice = nil
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // One folder per recording: <stamp>/said_<stamp>.m4a (+ .md transcript later).
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let stamp = fmt.string(from: Date())
            let dir = Self.folder.appendingPathComponent(stamp, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let final = dir.appendingPathComponent("said_\(stamp).m4a")
            let url = dir.appendingPathComponent(".mic.m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw NSError(domain: "Said", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nie udało się rozpocząć nagrywania."]) }

            recorder = r
            session = Session(final: final, mic: url,
                              system: startSystemAudio(writingTo: dir.appendingPathComponent(".system.m4a")))
            elapsed = 0
            levels = Array(repeating: 0, count: Self.barCount)
            isRecording = true
            pill.show()

            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            self.error = error.localizedDescription
            recordingMeeting = nil
        }
    }

    /// Starts tapping the meeting app (or the whole Mac) if wanted. Returns the file it writes, if any.
    private func startSystemAudio(writingTo url: URL) -> URL? {
        guard #available(macOS 14.2, *) else { return nil }
        let scope: SystemAudioTap.Scope
        if let meeting = recordingMeeting {
            let ids = MeetingDetector.processObjects(bundlePrefix: meeting.bundleID)
            scope = ids.isEmpty ? .everything : .processes(ids)
        } else if recordSystemAudio {
            scope = .everything
        } else {
            return nil
        }
        let t = SystemAudioTap()
        do {
            try t.start(scope: scope, writingTo: url)
            tap = t
            return url
        } catch {
            t.stop()
            self.error = "Nagrywam tylko mikrofon: \(error.localizedDescription)"
            return nil
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // dB (-160...0) -> 0...1, with a usable range of roughly -50 dB to 0 dB.
        let db = recorder.averagePower(forChannel: 0)
        var level = max(0, min(1, (db + 50) / 50))
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { level = max(level, tap.level) }
        levels.removeFirst()
        levels.append(level)
        watchSilence(level)
        if Date().timeIntervalSince(lastDiskCheck) > 10 { watchDisk() }
    }

    /// After a long stretch of silence, suggest stopping (once per silent stretch).
    private func watchSilence(_ level: Float) {
        let now = Date()
        if level >= Self.silenceLevel { loudTicks += 1 } else { loudTicks = 0 }
        guard loudTicks < 10 else {
            silenceSince = nil
            if silenceNotified {
                silenceNotified = false
                notice = nil
                Notifier.shared.clear(id: "silence")
            }
            return
        }
        let since = silenceSince ?? now
        silenceSince = since
        if !silenceNotified, now.timeIntervalSince(since) >= silenceLimit {
            silenceNotified = true
            let minutes = Int(silenceLimit / 60)
            notice = "Cisza od \(minutes) min"
            Notifier.shared.post(id: "silence", title: "Said nadal nagrywa",
                                 body: "Od \(minutes) min nic nie słychać. Zatrzymać nagrywanie?")
        }
    }

    /// Warn when the disk is getting full; stop before it is.
    private func watchDisk() {
        lastDiskCheck = Date()
        guard let free = Self.freeSpace() else { return }
        if free < Self.criticalDisk {
            stop()
            notice = nil
            Notifier.shared.post(id: "disk", title: "Nagranie zatrzymane",
                                 body: "Kończy się miejsce na dysku (zostało \(Self.bytes(free))). Nagranie zostało zapisane.",
                                 offerStop: false)
        } else if free < Self.lowDisk, !diskWarned {
            diskWarned = true
            notice = "Mało miejsca: \(Self.bytes(free))"
            Notifier.shared.post(id: "disk", title: "Mało miejsca na dysku",
                                 body: "Zostało \(Self.bytes(free)). Said zatrzyma nagrywanie przy \(Self.bytes(Self.criticalDisk)).")
        }
    }

    private static func freeSpace() -> Int64? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func denied() {
        recordingMeeting = nil
        error = "Brak dostępu do mikrofonu. Włącz go w Ustawieniach systemowych → Prywatność i ochrona → Mikrofon."
    }

    // MARK: - URL scheme (said://start, said://stop, said://toggle) — Shortcuts, Raycast…

    func handle(_ url: URL) {
        guard url.scheme == "said" else { return }
        switch url.host {
        case "start": start()
        case "stop": stop()
        case "toggle": toggle()
        default: break
        }
    }

    // MARK: - Summary actions

    func revealLast() {
        guard let last else { return }
        NSWorkspace.shared.activateFileViewerSelecting([last.url])
    }

    /// Opens ~/Music/Said (all recordings and transcripts) in Finder.
    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    func openTranscript() {
        guard let path = last?.transcriptPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func copyLastPath() {
        guard let last else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.path, forType: .string)
    }
}
