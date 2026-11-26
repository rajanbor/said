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
    /// The transcript has a summary at the top.
    var summarized: Bool? = nil

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

    /// What the card under the menu bar is showing, if it is showing anything.
    @Published private(set) var finished: Finished?

    /// The recording that just ended, and how far Said has got with it.
    struct Finished: Equatable {
        var duration: TimeInterval
        var source: String?
        /// The transcript is written (so it can be opened).
        var hasTranscript: Bool
        var stage: Stage

        enum Stage: Equatable {
            case saving
            case transcribing
            case summarizing
            case done
            case failed(String)
        }
    }

    /// Also record what the Mac plays (for manual recordings; meetings always include the meeting app).
    @Published var recordSystemAudio: Bool {
        didSet { UserDefaults.standard.set(recordSystemAudio, forKey: Self.systemAudioKey) }
    }

    /// Meeting that is currently offered for recording (drives the prompt pill).
    @Published private(set) var promptMeeting: MeetingDetector.Meeting?
    /// The prompt pill is asking to confirm a said://start request from another app.
    @Published private(set) var promptIsExternal = false

    let transcriber = Transcriber()
    let summarizer = Summarizer()
    let meetings = MeetingDetector()

    static let barCount = 18
    private static let lastKey = "lastRecording"
    private static let systemAudioKey = "recordSystemAudio"

    /// Files of the recording in progress.
    private struct Session {
        let final: URL      // <stamp>/said_<stamp>.m4a
        let mic: URL        // <stamp>/.mic.m4a
        let system: URL?    // <stamp>/.system.m4a
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
    /// Clicks on the prompt are ignored for a moment after it appears (no click-through).
    private var promptShownAt = Date.distantPast

    private lazy var pill = FloatingPanel(size: NSSize(width: 196, height: 38)) {
        PillView().environmentObject(self)
    }
    private lazy var prompt = FloatingPanel(size: NSSize(width: 268, height: 42)) {
        MeetingPromptView().environmentObject(self)
    }
    private lazy var card = FloatingPanel(size: NSSize(width: 304, height: 54), anchor: .topTrailing) {
        ResultCardView()
            .environmentObject(self)
            .environmentObject(self.transcriber)
            .environmentObject(self.summarizer)
    }
    private var cardHide: Task<Void, Never>?
    private var cardHideAfter: TimeInterval?
    /// How long the card stays while Said is still working, and once it's finished.
    private static let cardWorking: TimeInterval = 8
    private static let cardDone: TimeInterval = 12

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
        // Lock down the recordings folder (also for recordings made by older versions).
        if FileManager.default.fileExists(atPath: Self.folder.path) { try? Self.secureDirectory(Self.folder) }
        meetings.onStart = { [weak self] in self?.meetingStarted($0) }
        meetings.onEnd = { [weak self] in self?.meetingEnded($0) }
    }

    // MARK: - Meetings

    private func meetingStarted(_ meeting: MeetingDetector.Meeting) {
        guard !isRecording else { return }
        promptIsExternal = false
        promptMeeting = meeting
        showPrompt()
    }

    /// said://start from another app or a web page: never record silently, ask first.
    private func requestExternalStart() {
        guard !isRecording else { return }
        promptMeeting = nil
        promptIsExternal = true
        showPrompt()
    }

    private func showPrompt() {
        promptShownAt = Date()
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
        guard Date().timeIntervalSince(promptShownAt) > 0.7 else { return }
        let meeting = promptMeeting
        dismissMeetingPrompt()
        recordingMeeting = meeting
        start()
    }

    func dismissMeetingPrompt() {
        promptTimeout?.cancel()
        promptTimeout = nil
        promptMeeting = nil
        promptIsExternal = false
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
        finished = Finished(duration: duration, source: source, hasTranscript: false, stage: .saving)
        show(.saving, hideAfter: nil)
        Task {
            let url = await Self.finish(session)
            isSaving = false
            save(Recording(path: url.path, duration: duration, date: Date(), source: source))
            if transcriber.isInstalled {
                transcribeLast()
            } else {
                show(.done, hideAfter: Self.cardDone)
            }
        }
    }

    /// Mixes mic + system audio into the final .m4a (or keeps just the mic).
    /// Temporary tracks are deleted only after the final file is confirmed playable;
    /// if anything fails, the tracks are kept as visible files instead of being lost.
    private static func finish(_ s: Session) async -> URL {
        let fm = FileManager.default
        if let system = s.system {
            let size = (try? fm.attributesOfItem(atPath: system.path)[.size] as? Int) ?? 0
            if size > 16 * 1024 {
                if await AudioMixer.mix([s.mic, system], into: s.final), await isPlayable(s.final) {
                    try? fm.removeItem(at: s.mic)
                    try? fm.removeItem(at: system)
                    return secured(s.final)
                }
                // Mixing failed: keep the call audio next to the recording.
                try? fm.removeItem(at: s.final)
                let systemCopy = s.final.deletingPathExtension().appendingPathExtension("system.m4a")
                if (try? fm.moveItem(at: system, to: systemCopy)) != nil { _ = secured(systemCopy) }
            } else {
                try? fm.removeItem(at: system)   // practically empty: nothing was played
            }
        }
        do {
            try fm.moveItem(at: s.mic, to: s.final)
            return secured(s.final)
        } catch {
            return secured(s.mic)   // keep the temporary file rather than lose the recording
        }
    }

    private static func isPlayable(_ url: URL) async -> Bool {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return false }
        return duration.seconds > 0
    }

    /// Recordings are readable by this user only (0600).
    @discardableResult
    static func secured(_ url: URL) -> URL {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Creates `url` (and ~/Music/Said) as directories only this user can open (0700).
    static func secureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        for dir in [folder, url] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Runs local transcription for the last recording (automatic when the model is installed).
    func transcribeLast() {
        guard let rec = last else { return }
        show(.transcribing, hideAfter: Self.cardWorking)
        Task(priority: .userInitiated) {
            guard let url = await transcriber.transcribe(rec) else {
                if case .failed(let message) = transcriber.state {
                    show(.failed(message), hideAfter: Self.cardDone)
                }
                transcriber.releaseSoon()
                return
            }
            var updated = rec
            updated.transcriptPath = url.path
            if last?.path == rec.path { save(updated) }
            transcriber.releaseSoon()
            if summarizer.isReady {
                show(.summarizing, hideAfter: Self.cardWorking)
                await summarize(updated)
            }
            show(.done, hideAfter: Self.cardDone)
        }
    }

    /// Writes the summary into the last recording's transcript (automatic when a summary model is installed).
    func summarizeLast() {
        guard let rec = last else { return }
        Task(priority: .userInitiated) {
            show(.summarizing, hideAfter: Self.cardWorking)
            await summarize(rec)
            show(.done, hideAfter: Self.cardDone)
        }
    }

    // MARK: - The card under the menu bar

    /// Shows (or updates) the card that says what happened to the recording that just ended.
    /// `hideAfter` is how long it stays; `nil` keeps it until the next stage.
    private func show(_ stage: Finished.Stage, hideAfter: TimeInterval?) {
        guard !isRecording else { return hideResult() }
        var current = finished ?? Finished(duration: last?.duration ?? 0, source: last?.source,
                                           hasTranscript: false, stage: stage)
        current.stage = stage
        current.hasTranscript = last?.transcriptPath != nil
        finished = current
        card.show()
        scheduleHide(hideAfter)
    }

    private func scheduleHide(_ after: TimeInterval?) {
        cardHide?.cancel()
        cardHide = nil
        cardHideAfter = after
        guard let after else { return }
        cardHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            self?.hideResult()
        }
    }

    func hideResult() {
        cardHide?.cancel()
        cardHide = nil
        card.hide()
    }

    /// The card waits while the pointer is on it.
    func holdResult(_ hovering: Bool) {
        if hovering {
            cardHide?.cancel()
            cardHide = nil
        } else {
            scheduleHide(cardHideAfter)
        }
    }

    private func summarize(_ rec: Recording) async {
        guard let path = rec.transcriptPath,
              await summarizer.summarize(transcriptAt: URL(fileURLWithPath: path)) else { return }
        var updated = rec
        updated.summarized = true
        if last?.path == rec.path { save(updated) }
    }

    private func save(_ rec: Recording) {
        last = rec
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: Self.lastKey)
        }
    }

    private func beginRecording() {
        if let free = Self.freeSpace(), free < Self.criticalDisk {
            error = L("Not enough disk space (%@). Free up some space to record.", Self.bytes(free))
            recordingMeeting = nil
            return
        }
        Notifier.shared.requestPermission()
        hideResult()
        finished = nil
        // Load the transcription model now, in the background: by the time this recording
        // stops it is ready, so transcribing can start straight away.
        transcriber.prepare()
        silenceSince = nil
        silenceNotified = false
        diskWarned = false
        notice = nil
        do {
            // One folder per recording: <stamp>/said_<stamp>.m4a (+ .md transcript later).
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let stamp = fmt.string(from: Date())
            let dir = Self.folder.appendingPathComponent(stamp, isDirectory: true)
            try Self.secureDirectory(dir)
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
                userInfo: [NSLocalizedDescriptionKey: L("Couldn't start recording.")]) }

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
            transcriber.releaseSoon()   // nothing to transcribe after all
        }
    }

    /// Starts tapping the meeting app (or the whole Mac) if wanted. Returns the file it writes, if any.
    private func startSystemAudio(writingTo url: URL) -> URL? {
        guard #available(macOS 14.2, *) else { return nil }
        let scope: SystemAudioTap.Scope
        if let meeting = recordingMeeting {
            let ids = MeetingDetector.processObjects(bundlePrefix: meeting.bundleID)
            // Fail closed: never widen a meeting recording to everything the Mac plays.
            guard !ids.isEmpty else {
                notice = L("Couldn't find %@ audio. Recording the microphone only.", meeting.name)
                return nil
            }
            scope = .processes(ids)
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
            self.error = L("Recording the microphone only: %@", error.localizedDescription)
            return nil
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        // The clock only shows seconds: publishing it 20 times a second would redraw the
        // menu bar and the pill for nothing.
        let time = recorder.currentTime
        if Int(time) != Int(elapsed) { elapsed = time }
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
            notice = L("Silent for %d min", minutes)
            Notifier.shared.post(id: "silence", title: L("Said is still recording"),
                                 body: L("Nothing has been heard for %d min. Stop recording?", minutes))
        }
    }

    /// Warn when the disk is getting full; stop before it is.
    private func watchDisk() {
        lastDiskCheck = Date()
        guard let free = Self.freeSpace() else { return }
        if free < Self.criticalDisk {
            stop()
            notice = nil
            Notifier.shared.post(id: "disk", title: L("Recording stopped"),
                                 body: L("Your disk is almost full (%@ left). The recording has been saved.", Self.bytes(free)),
                                 offerStop: false)
        } else if free < Self.lowDisk, !diskWarned {
            diskWarned = true
            notice = L("Low disk space: %@", Self.bytes(free))
            Notifier.shared.post(id: "disk", title: L("Low disk space"),
                                 body: L("%@ left. Said will stop recording at %@.", Self.bytes(free), Self.bytes(Self.criticalDisk)))
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
        error = L("No microphone access. Turn it on in System Settings → Privacy & Security → Microphone.")
    }

    // MARK: - URL scheme (said://start, said://stop, said://toggle) — Shortcuts, Raycast…
    // Any app or web page can open these URLs, so starting always asks for confirmation
    // in the prompt pill. Stopping needs none: it can only end a recording, never start one.

    func handle(_ url: URL) {
        guard url.scheme == "said" else { return }
        switch url.host {
        case "start": requestExternalStart()
        case "stop": stop()
        case "toggle": isRecording ? stop() : requestExternalStart()
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
        try? Self.secureDirectory(Self.folder)
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
