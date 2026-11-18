import Foundation
import WhisperKit

/// Local speech-to-text with Whisper (Core ML, Apple Neural Engine).
///
/// Network is used **only** inside `installModel()`, which runs when the user
/// clicks "Download transcription model". After that, models load from disk with downloads disabled.
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

    /// Multilingual (incl. Polish), quantized large-v3 turbo, ~630 MB.
    static let variant = "large-v3-v20240930_turbo_632MB"
    private static let folderKey = "whisperModelFolder"

    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Said/Models", isDirectory: true)
    }

    private var kit: WhisperKit?
    private var loading: Task<Void, Never>?
    private var modelFolder: String? {
        get { UserDefaults.standard.string(forKey: Self.folderKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.folderKey) }
    }

    var isInstalled: Bool {
        guard let modelFolder else { return false }
        return FileManager.default.fileExists(atPath: modelFolder)
    }

    init() {
        if isInstalled {
            state = .preparing
            Task { await load() }
        }
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
        } catch {
            state = .failed(L("Couldn't download the model: %@", error.localizedDescription))
        }
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

    /// Transcribes `rec` and writes a Markdown file next to the audio. Returns its URL.
    func transcribe(_ rec: Recording) async -> URL? {
        if kit == nil { await load() }
        guard let kit else { return nil }
        state = .transcribing
        defer { if state == .transcribing { state = .ready } }

        var options = DecodingOptions()
        options.detectLanguage = true
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad

        do {
            let results = try await kit.transcribe(audioPath: rec.path, decodeOptions: options)
            let segments = results.flatMap(\.segments)
            let language = results.first?.language ?? "?"
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
