import Foundation
import WhisperKit

/// Local speech-to-text with Whisper (Core ML, Apple Neural Engine).
///
/// Network is used **only** inside `installModel()`, which runs when the user
/// clicks "Download transcription model". After that, models load from disk with downloads disabled.
///
/// The model is kept in memory only while it is needed: it is loaded when a recording starts
/// (`prepare()`), used when the recording stops, and dropped again (`releaseSoon()`). An idle
/// Said holds no model at all.
@MainActor
final class Transcriber: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case preparing          // loading / compiling the Core ML model
        case ready
        case transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled
    /// How much of the recording is transcribed (0…1), while `state` is `.transcribing`.
    @Published private(set) var progress: Double?

    /// Multilingual (incl. Polish), quantized large-v3 turbo, ~630 MB.
    static let variant = "large-v3-v20240930_turbo_632MB"
    private static let folderKey = "whisperModelFolder"
    /// The model leaves memory this long after the last transcription.
    private static let idleRelease: TimeInterval = 90
    nonisolated private static let sampleRate = 16_000

    nonisolated static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Said/Models", isDirectory: true)
    }

    private var kit: WhisperKit?
    private var loading: Task<Void, Never>?
    private var release: Task<Void, Never>?
    private var modelFolder: String? {
        get { UserDefaults.standard.string(forKey: Self.folderKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.folderKey) }
    }

    var isInstalled: Bool {
        guard let modelFolder else { return false }
        return FileManager.default.fileExists(atPath: modelFolder)
    }

    /// True while the model sits in memory (ready to transcribe without waiting).
    var isLoaded: Bool { kit != nil }

    /// "Transcribing… 40%" once there is something to count.
    var statusText: String {
        guard let progress, progress >= 0.01 else { return L("Transcribing…") }
        return L("Transcribing… %d%%", Int(progress * 100))
    }

    init() {
        // Nothing is loaded here on purpose: a Said that isn't recording uses no memory for models.
        if isInstalled { state = .ready }
    }

    /// One-time, user-initiated download of the model and tokenizer.
    func installModel() async {
        state = .downloading(0)
        do {
            let folder = try await WhisperKit.download(
                variant: Self.variant,
                downloadBase: Self.modelsDir,
                progressCallback: { progress in
                    let value = progress.fractionCompleted
                    Task { @MainActor in self.state = .downloading(value) }
                }
            )
            modelFolder = folder.path
            // First load may also fetch the tokenizer into modelsDir (still part of setup).
            await load(allowDownload: true)
            releaseSoon()
        } catch {
            state = .failed(L("Couldn't download the model: %@", error.localizedDescription))
        }
    }

    // MARK: - Memory

    /// Starts loading the model in the background, so a recording that stops in a minute's
    /// time doesn't have to wait for it. Called when recording starts.
    func prepare() {
        release?.cancel()
        release = nil
        guard isInstalled, kit == nil, loading == nil else { return }
        Task { await load() }
    }

    /// Drops the model from memory after a while, unless it is needed again before then.
    func releaseSoon() {
        release?.cancel()
        release = nil
        guard kit != nil else { return }
        release = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleRelease))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() async {
        release = nil
        guard state != .transcribing, let kit else { return }
        self.kit = nil
        await kit.unloadModels()
    }

    /// Loads the model once; concurrent callers wait for the same load.
    private func load(allowDownload: Bool = false) async {
        if let loading { return await loading.value }
        let task = Task { await performLoad(allowDownload: allowDownload) }
        loading = task
        await task.value
        loading = nil
    }

    private func performLoad(allowDownload: Bool) async {
        guard kit == nil, let modelFolder else { return }
        state = .preparing
        do {
            let config = WhisperKitConfig(
                modelFolder: modelFolder,
                tokenizerFolder: Self.modelsDir,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: allowDownload
            )
            kit = try await WhisperKit(config)
            state = .ready
        } catch {
            state = .failed(L("Couldn't load the model: %@", error.localizedDescription))
        }
    }

    // MARK: - Transcribing

    /// Transcribes `rec` and writes a Markdown file next to the audio. Returns its URL.
    func transcribe(_ rec: Recording) async -> URL? {
        release?.cancel()
        release = nil
        if kit == nil { await load() }
        guard let kit else { return nil }
        state = .transcribing
        progress = nil
        // Said is a menu bar app and so always in the background, where macOS would otherwise
        // slow this work down (App Nap). Idle sleep is still allowed.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Transcribing a recording")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            progress = nil
            if state == .transcribing { state = .ready }
        }

        do {
            let path = rec.path
            let audio = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }.value

            var options = DecodingOptions()
            options.detectLanguage = true
            options.skipSpecialTokens = true
            // Split long audio on silence; the pieces are then decoded several at a time.
            options.chunkingStrategy = .vad

            let seconds = max(1, Double(audio.count) / Double(Self.sampleRate))
            let onSegments: SegmentDiscoveryCallback = { [weak self] segments in
                guard let furthest = segments.map({ Double($0.end) }).max() else { return }
                Task { @MainActor in
                    let done = min(1, furthest / seconds)
                    if done > (self?.progress ?? 0) { self?.progress = done }
                }
            }

            let results = try await kit.transcribe(audioArray: audio, decodeOptions: options,
                                                   segmentCallback: onSegments)
            // Whisper invents text for silence ("Thank you", "Спасибо"), so keep only segments with speech.
            var segments: [TranscriptionSegment] = []
            var speechPerLanguage: [String: Int] = [:]
            for result in results {
                let speech = result.segments.filter { SilenceFilter.hasSpeech($0, in: audio) }
                segments += speech
                speechPerLanguage[result.language, default: 0] += speech.reduce(0) { $0 + $1.text.count }
            }
            // Language of the parts with the most speech (a silent start can be "detected" as anything).
            let language = speechPerLanguage.filter { $0.value > 0 }.max { $0.value < $1.value }?.key ?? "?"
            let md = Self.markdown(for: rec, segments: segments, language: language)
            let url = rec.url.deletingPathExtension().appendingPathExtension("md")
            try md.write(to: url, atomically: true, encoding: .utf8)
            Recorder.secured(url)
            return url
        } catch {
            state = .failed(L("Transcription failed: %@", error.localizedDescription))
            return nil
        }
    }

    private static func markdown(for rec: Recording, segments: [TranscriptionSegment], language: String) -> String {
        let date = rec.date.formatted(date: .long, time: .shortened)
        var lines = [
            "# " + L("Recording %@", date),
            "",
            "- \(L("File")): `\(rec.url.lastPathComponent)`",
            "- \(L("Duration")): \(rec.duration.clock)",
        ] + (rec.source.map { ["- \(L("Meeting")): \($0)"] } ?? []) + [
            "- \(L("Language")): \(language)",
            "",
            "## " + L("Transcript"),
            "",
        ]
        let body = segments
            .map { ($0.start, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "**[\(TimeInterval($0.0).clock)]** \($0.1)" }
        lines += body.isEmpty ? ["_" + L("(no speech detected)") + "_"] : body.flatMap { [$0, ""] }
        return lines.joined(separator: "\n")
    }
}

/// Tells real speech from Whisper's inventions on silence, by loudness.
///
/// Whisper writes typical phrases for silent audio ("Thank you for watching", "Спасибо", "ご視聴ありがとう
/// ございました") and its no-speech score doesn't catch them. Silence is easy to measure instead.
enum SilenceFilter {
    private static let sampleRate = 16_000           // WhisperKit's audio
    private static let frame = sampleRate / 10       // 100 ms
    /// A 100 ms frame louder than this counts as sound (quiet speech ≈ -35 dB, a silent room ≈ -50 dB).
    private static let speechLevel: Float = -45
    /// Typical phrases get a stricter level, so a real "thank you" in a call is kept.
    private static let phraseLevel: Float = -35
    /// At least this many loud frames (300 ms) make a segment speech.
    private static let minimumFrames = 3

    static func hasSpeech(_ segment: TranscriptionSegment, in audio: [Float]) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let start = max(0, Int(segment.start * Float(sampleRate)))
        let end = min(audio.count, Int(segment.end * Float(sampleRate)))
        guard end > start else { return true }   // no timing to check: keep it

        var levels: [Float] = []
        var i = start
        while i < end {
            let slice = audio[i..<min(i + frame, end)]
            let mean = slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)
            levels.append(10 * log10(max(mean, 1e-12)))
            i += frame
        }
        let level = isTypicalHallucination(text) ? phraseLevel : speechLevel
        return levels.filter { $0 > level }.count >= minimumFrames
    }

    private static let phrases: Set<String> = [
        "thank you", "thanks", "thanks for watching", "thank you for watching", "thank you so much for watching",
        "please subscribe", "bye", "you", "dziękuję", "dziękuję bardzo", "dziękuję za uwagę", "dzięki",
        "dziękuję za obejrzenie", "do zobaczenia", "спасибо", "спасибо за внимание", "продолжение следует",
        "gracias", "obrigado", "obrigada", "merci", "danke", "grazie", "e aí", "ご視聴ありがとうございました",
        "ありがとうございました", "谢谢观看", "谢谢",
    ]
    private static let prefixes = ["subtitles", "napisy", "субтитры", "sous-titres", "untertitel", "amara.org", "字幕"]

    private static func isTypicalHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
        if t.isEmpty || t.allSatisfy({ $0.isNumber || $0.isWhitespace || $0.isPunctuation }) { return true }
        return phrases.contains(t) || prefixes.contains { t.hasPrefix($0) }
    }
}
