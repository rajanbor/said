import SwiftUI

struct MenuView: View {
    @EnvironmentObject var recorder: Recorder

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
                }
            }

            Divider()
            HStack {
                Text("Lokalnie · bez internetu").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Wyjdź") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
