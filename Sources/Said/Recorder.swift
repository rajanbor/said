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
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0...1), newest last — drives the pill animation.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: Recorder.barCount)
    @Published private(set) var last: Recording?
    @Published var error: String?

    /// Meeting that is currently offered for recording (drives the prompt pill).
    @Published private(set) var promptMeeting: MeetingDetector.Meeting?

    let transcriber = Transcriber()
    let meetings = MeetingDetector()

    static let barCount = 18
    private static let lastKey = "lastRecording"

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
        guard let recorder, isRecording else { return }
        let duration = recorder.currentTime
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        isRecording = false
        pill.hide()

        let rec = Recording(path: recorder.url.path, duration: duration, date: Date(),
                            source: recordingMeeting?.name)
        recordingMeeting = nil
        save(rec)
        if transcriber.isInstalled { transcribeLast() }
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
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // One folder per recording: <stamp>/said_<stamp>.m4a (+ .md transcript later).
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let stamp = fmt.string(from: Date())
            let dir = Self.folder.appendingPathComponent(stamp, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("said_\(stamp).m4a")

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

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // dB (-160...0) -> 0...1, with a usable range of roughly -50 dB to 0 dB.
        let db = recorder.averagePower(forChannel: 0)
        let level = max(0, min(1, (db + 50) / 50))
        levels.removeFirst()
        levels.append(level)
    }

    private func denied() {
        recordingMeeting = nil
        error = "Brak dostępu do mikrofonu. Włącz go w Ustawieniach systemowych → Prywatność i ochrona → Mikrofon."
    }

    // MARK: - Summary actions

    func revealLast() {
        guard let last else { return }
        NSWorkspace.shared.activateFileViewerSelecting([last.url])
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
