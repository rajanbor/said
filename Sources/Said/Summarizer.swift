import CryptoKit
import Foundation

/// The local language model that writes the summary at the top of each transcript.
/// Chosen with one setting, `summaryModel` (menu: Settings → Summaries).
enum SummaryModel: String, CaseIterable, Identifiable {
    /// Polish-first model by SpeakLeash. Best when you mostly speak Polish.
    case bielik = "bielik"
    /// Strong multilingual model. Best for mixed Polish and English, or mostly English.
    case qwen4b = "qwen3-4b"
    /// Small and quick, for older Macs or to save disk space.
    case qwen1_7b = "qwen3-1.7b"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bielik: return "Bielik 4.5B"
        case .qwen4b: return "Qwen3 4B"
        case .qwen1_7b: return "Qwen3 1.7B"
        }
    }

    var hint: String {
        switch self {
        case .bielik: return L("Mostly Polish")
        case .qwen4b: return L("Mixed or mostly English")
        case .qwen1_7b: return L("Light and quick")
        }
    }

    /// Hugging Face repository and GGUF file (Q4_K_M quantization).
    private var source: (repo: String, file: String) {
        switch self {
        case .bielik: return ("second-state/Bielik-4.5B-v3.0-Instruct-GGUF", "Bielik-4.5B-v3.0-Instruct-Q4_K_M.gguf")
        case .qwen4b: return ("unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
        case .qwen1_7b: return ("unsloth/Qwen3-1.7B-GGUF", "Qwen3-1.7B-Q4_K_M.gguf")
        }
    }

    var url: URL { URL(string: "https://huggingface.co/\(source.repo)/resolve/main/\(source.file)")! }
    var file: URL { Transcriber.modelsDir.appendingPathComponent(source.file) }

    /// The download is checked against this, so a changed file on the server is never used.
    var sha256: String {
        switch self {
        case .bielik: return "39fb78db7c5e1582d3ef5bded109cd98606aabd5acbb5c98601155174b6763e1"
        case .qwen4b: return "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
        case .qwen1_7b: return "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897"
        }
    }

    var bytes: Int64 {
        switch self {
        case .bielik: return 2_878_886_912
        case .qwen4b: return 2_497_281_120
        case .qwen1_7b: return 1_107_409_472
        }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }
}

/// Writes a short summary (key points, decisions, action items) into a transcript, locally.
///
/// Network is used **only** inside `installModel()`, when the user clicks the download button.
@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case summarizing(String?)
        case failed(String)
    }

    static let modelKey = "summaryModel"
    /// Transcripts shorter than this (about 10 seconds of speech) get no summary.
    static let minimumWords = 25

    /// The one setting: which model writes summaries (nil = summaries off).
    @Published var model: SummaryModel? {
        didSet {
            UserDefaults.standard.set(model?.rawValue ?? "off", forKey: Self.modelKey)
            if case .failed = state { state = .idle }
        }
    }
    @Published private(set) var state: State = .idle

    private var download: Task<Void, Never>?

    /// Ready to summarize: a model is chosen and on disk.
    var isReady: Bool { model?.isInstalled ?? false }

    init() {
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(SummaryModel.init(rawValue:))
    }

    // MARK: - Download

    func installModel() {
        guard let model, download == nil else { return }
        download = Task {
            defer { download = nil }
            do {
                state = .downloading(0)
                let temp = try await Downloader.fetch(model.url) { p in
                    Task { @MainActor in if case .downloading = self.state { self.state = .downloading(p) } }
                }
                state = .verifying
                defer { try? FileManager.default.removeItem(at: temp) }
                let hash = try await Task.detached { try Self.sha256(of: temp) }.value
                guard hash == model.sha256 else {
                    state = .failed(L("The downloaded model is damaged or changed. Try again."))
                    return
                }
                try Recorder.secureDirectory(Transcriber.modelsDir)
                try? FileManager.default.removeItem(at: model.file)
                try FileManager.default.moveItem(at: temp, to: model.file)
                state = .idle
                objectWillChange.send()
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(L("Couldn't download the model: %@", error.localizedDescription))
            }
        }
    }

    func cancelDownload() { download?.cancel() }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Summaries

    /// Adds (or replaces) the summary section in the transcript at `url`. Returns true on success.
    @discardableResult
    func summarize(transcriptAt url: URL) async -> Bool {
        guard let model, model.isInstalled else { return false }
        if case .summarizing = state { return false }
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let parsed = TranscriptFile(markdown)
        // A few words (or Whisper's "Thank you" on silence) leave nothing to summarize, and small
        // models then make things up. Treat it as done, without a summary.
        guard parsed.wordCount >= Self.minimumWords else { return true }

        state = .summarizing(nil)
        // Said is a menu bar app and so always in the background, where macOS would otherwise
        // slow this work down (App Nap). Idle sleep is still allowed.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Writing a summary")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let path = model.file.path
        let language = parsed.languageName
        let report: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in self.state = .summarizing(L("part %d of %d", done, total)) }
        }
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                let runner = try LlamaRunner(path: path, contextSize: 8192)
                return try SummaryWriter(runner: runner, language: language, progress: report).summarize(parsed.lines)
            }.value
            try parsed.inserting(summary.markdown).write(to: url, atomically: true, encoding: .utf8)
            Recorder.secured(url)
            state = .idle
            return true
        } catch {
            state = .failed(L("Couldn't write the summary: %@", error.localizedDescription))
            return false
        }
    }
}

// MARK: - Prompting

struct Summary: Decodable {
    var summary: String
    var key_points: [String]
    var decisions: [String]
    var action_items: [String]

    var markdown: String {
        var out = ["## " + L("Summary"), "", summary.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        func list(_ title: String, _ items: [String]) {
            let items = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return }
            out += ["### " + title, ""] + items.map { "- " + $0 } + [""]
        }
        list(L("Key points"), key_points)
        list(L("Decisions"), decisions)
        list(L("Action items"), action_items)
        return out.joined(separator: "\n")
    }
}

/// Map-reduce over long transcripts: notes per part, then one summary from the notes.
struct SummaryWriter {
    let runner: LlamaRunner
    let language: String?
    let progress: @Sendable (Int, Int) -> Void

    private static let summaryTokens = 1200
    private static let notesTokens = 600
    private static let overhead = 700   // system prompt + instructions + chat template

    private var languageRule: String {
        language.map { "Write in \($0)." } ?? "Write in the same language as the transcript."
    }

    func summarize(_ lines: [String]) throws -> Summary {
        var text = lines.joined(separator: "\n")
        var isNotes = false
        let budget = runner.contextSize - Self.overhead - Self.summaryTokens
        // Too long for one pass: condense part by part until it fits (a few rounds at most).
        var rounds = 0
        while runner.tokenCount(text) > budget {
            rounds += 1
            guard rounds <= 3 else { throw LlamaRunner.Failure.tooLong }
            let parts = split(text.components(separatedBy: "\n"),
                              maxTokens: runner.contextSize - Self.overhead - Self.notesTokens)
            var notes: [String] = []
            for (i, part) in parts.enumerated() {
                try Task.checkCancellation()
                progress(i + 1, parts.count + 1)
                notes.append(try self.notes(for: part, index: i + 1, of: parts.count))
            }
            text = notes.joined(separator: "\n\n")
            isNotes = true
            progress(parts.count + 1, parts.count + 1)
        }

        let system = """
        You summarize transcripts of recordings: meetings, calls and voice notes. \
        Use only what is said in the text; never invent names, numbers or facts. \(languageRule)
        """
        let user = """
        \(isNotes ? "Below are notes made from a long recording, in order." : "Below is the transcript of a recording.")

        Reply with JSON only:
        - "summary": 2-4 sentences on what the recording is about and how it ended.
        - "key_points": 3-8 most important points, one short sentence each.
        - "decisions": decisions that were made (empty list if none).
        - "action_items": tasks to do, with who does it and when if said (empty list if none).
        \(languageRule)

        ---
        \(text)
        ---
        """
        let raw = try runner.generate(runner.chatPrompt(system: system, user: user + Self.noThink),
                                      maxTokens: Self.summaryTokens, grammar: Self.grammar)
        guard let data = Self.stripThinking(raw).data(using: .utf8),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw LlamaRunner.Failure.unfinished
        }
        return summary
    }

    private func notes(for part: String, index: Int, of total: Int) throws -> String {
        let system = "You take concise notes from transcripts. Use only what is said. \(languageRule)"
        let user = """
        This is part \(index) of \(total) of a transcript. Write short bullet-point notes: \
        topics, facts and numbers, decisions, and tasks (who, what, when). No introduction. \(languageRule)

        ---
        \(part)
        ---
        """
        let raw = try runner.generate(runner.chatPrompt(system: system, user: user + Self.noThink),
                                      maxTokens: Self.notesTokens)
        return Self.stripThinking(raw)
    }

    /// Splits lines into parts that each fit in `maxTokens`.
    private func split(_ lines: [String], maxTokens: Int) -> [String] {
        var parts: [String] = [], current: [String] = [], size = 0
        for line in lines {
            let n = runner.tokenCount(line) + 1
            if size + n > maxTokens, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []; size = 0
            }
            current.append(line); size += n
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// Qwen3 hybrid models skip their reasoning step with this; other models ignore it.
    private static let noThink = "\n/no_think"

    private static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GBNF: forces a JSON object with exactly the fields of `Summary`.
    private static let grammar = #"""
    root  ::= "{" ws "\"summary\":" ws str "," ws "\"key_points\":" ws list "," ws "\"decisions\":" ws list "," ws "\"action_items\":" ws list ws "}"
    list  ::= "[" ws ( str ( "," ws str ){0,7} )? ws "]"
    str   ::= "\"" char{0,400} "\""
    char  ::= [^"\\\x00-\x1F] | "\\" ["\\/nt]
    ws    ::= [ \n]{0,3} [ \t]{0,8}
    """#
}

// MARK: - Transcript file

/// Reads the parts of a Said transcript (Markdown) that the summary needs, and puts the summary in.
struct TranscriptFile {
    let markdown: String
    /// Spoken text, one segment per line, without timestamps.
    let lines: [String]
    /// Language Whisper detected, as an English name ("Polish"), if known.
    let languageName: String?

    var wordCount: Int { lines.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count } }

    init(_ markdown: String) {
        self.markdown = markdown
        let all = markdown.components(separatedBy: "\n")
        lines = all.compactMap { line in
            guard line.hasPrefix("**["), let end = line.range(of: "]** ") else { return nil }
            return String(line[end.upperBound...])
        }
        // The header has a line like "- Language: pl" (label in the UI language).
        let code = all.prefix { !$0.hasPrefix("## ") }
            .first { $0.range(of: #"^- [^:]+: [a-z]{2,3}$"#, options: .regularExpression) != nil }
            .flatMap { $0.split(separator: " ").last.map(String.init) }
        languageName = code.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
    }

    /// The Markdown with `section` placed before the transcript (replacing an older summary).
    func inserting(_ section: String) -> String {
        var all = markdown.components(separatedBy: "\n")
        let heading = "## " + L("Summary")
        if let start = all.firstIndex(of: heading) {
            let end = all[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? all.endIndex
            all.removeSubrange(start..<end)
        }
        let at = all.firstIndex { $0.hasPrefix("## ") } ?? all.endIndex
        all.insert(contentsOf: section.components(separatedBy: "\n"), at: at)
        return all.joined(separator: "\n")
    }
}

// MARK: - Download with progress

private enum Downloader {
    /// Downloads `url` to a private temporary file and returns it.
    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private var lastReport = 0.0

        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
            guard total > 0 else { return }
            let p = Double(written) / Double(total)
            if p - lastReport >= 0.005 { lastReport = p; progress(p) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                finish(.failure(URLError(.badServerResponse)))
                return
            }
            // The system deletes `location` when this returns: move it somewhere private first.
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("said-model-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                finish(.success(dest))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)) }
        }

        private func finish(_ result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
