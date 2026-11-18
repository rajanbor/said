import SwiftUI

struct MenuView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var transcriber: Transcriber

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: recorder.toggle) {
                Label(recorder.isRecording ? "Zatrzymaj  \(recorder.elapsed.clock)" : "Nagraj",
                      systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)

            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if let last = recorder.last, !recorder.isRecording {
                Divider()
                summary(last)
            }

            Divider()
            MeetingToggle(detector: recorder.meetings)
            Toggle("Nagrywaj też dźwięk z komputera", isOn: $recorder.recordSystemAudio)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help("Przy zwykłym nagraniu. Spotkania zawsze nagrywają też dźwięk aplikacji do spotkań.")

            Divider()
            modelSection

            Divider()
            HStack {
                Text("Said \(Self.version) · lokalnie").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Wyjdź") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func summary(_ last: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ostatnie nagranie").font(.caption).foregroundStyle(.secondary)
            Text(last.url.lastPathComponent).font(.headline)
            Text("\(last.duration.clock) · \(last.sizeText)")
                .font(.caption).foregroundStyle(.secondary)
            Text(last.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
            HStack {
                Button("Pokaż w Finderze", action: recorder.revealLast)
                Button("Kopiuj ścieżkę", action: recorder.copyLastPath)
            }
            .controlSize(.small)

            if recorder.isSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Zapisywanie…").font(.caption).foregroundStyle(.secondary)
                }
            } else if transcriber.state == .transcribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transkrypcja…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let path = last.transcriptPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Otwórz transkrypcję", action: recorder.openTranscript)
                    .controlSize(.small)
            } else if transcriber.state == .ready {
                Button("Transkrybuj", action: recorder.transcribeLast)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch transcriber.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text("Transkrypcja (Whisper)").font(.caption).foregroundStyle(.secondary)
                Text("Model ~630 MB pobierany jednorazowo. Potem wszystko działa offline.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("Pobierz model") { Task { await transcriber.installModel() } }
                    .controlSize(.small)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text("Pobieranie modelu… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: p)
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Przygotowywanie modelu (pierwszy raz może potrwać kilka minut)…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .ready, .transcribing:
            Label("Transkrypcja lokalna gotowa", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.caption).foregroundStyle(.red)
                Button(transcriber.isInstalled ? "Spróbuj ponownie" : "Pobierz model") {
                    Task { await transcriber.installModel() }
                }
                .controlSize(.small)
            }
        }
    }
}

/// "Proponuj nagrywanie spotkań" switch, plus which meeting is live right now.
private struct MeetingToggle: View {
    @ObservedObject var detector: MeetingDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Proponuj nagrywanie spotkań", isOn: $detector.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Text(detector.active.map { "Teraz: \($0.name)" } ?? "Zoom, Teams, Google Meet i inne")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
