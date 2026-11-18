import SwiftUI

/// Menu bar window, styled like a native macOS menu extra (Wi-Fi, Bluetooth):
/// plain rows with icons, hover highlight, small section headers.
struct MenuView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var transcriber: Transcriber

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Separator()
            recordRow
            if let notice = recorder.notice {
                Hint(text: notice, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let error = recorder.error {
                Hint(text: error, systemImage: "exclamationmark.circle.fill", tint: .red)
            }

            if let last = recorder.last, !recorder.isRecording {
                Separator()
                SectionTitle(L("Last recording"))
                lastRecording(last)
            }

            Separator()
            MenuRow(L("Open recordings folder"), systemImage: "folder", action: recorder.openFolder)

            Separator()
            SectionTitle(L("Settings"))
            MeetingToggle(detector: recorder.meetings)
            ToggleRow(L("Record system audio"), isOn: $recorder.recordSystemAudio)
            modelStatus

            Separator()
            MenuRow(L("Quit Said"), shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(5)
        .frame(width: 290)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Said").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(Self.version).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var recordRow: some View {
        if recorder.isRecording {
            MenuRow(L("Stop recording"), systemImage: "stop.circle.fill", tint: .red,
                    trailing: recorder.elapsed.clock, action: recorder.stop)
        } else {
            MenuRow(L("Record"), systemImage: "record.circle", tint: .red, action: recorder.start)
        }
    }

    @ViewBuilder
    private func lastRecording(_ last: Recording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(last.date.formatted(.dateTime.day().month(.wide).hour().minute()))
                .font(.system(size: 13))
            Text(details(last))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text((last.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 4)

        if recorder.isSaving {
            Hint(text: L("Saving…"), progress: true)
        } else if transcriber.state == .transcribing {
            Hint(text: L("Transcribing…"), progress: true)
        } else if last.transcriptPath != nil {
            MenuRow(L("Open transcript"), systemImage: "doc.text", action: recorder.openTranscript)
        } else if transcriber.state == .ready {
            MenuRow(L("Transcribe"), systemImage: "text.badge.plus", action: recorder.transcribeLast)
        }
        MenuRow(L("Show in Finder"), systemImage: "magnifyingglass", action: recorder.revealLast)
        MenuRow(L("Copy path"), systemImage: "doc.on.doc", action: recorder.copyLastPath)
    }

    private func details(_ r: Recording) -> String {
        [r.duration.clock, r.sizeText, r.source].compactMap { $0 }.joined(separator: " · ")
    }

    /// Only speaks up when something needs attention; silent once the model is ready.
    @ViewBuilder
    private var modelStatus: some View {
        switch transcriber.state {
        case .notInstalled:
            MenuRow(L("Download transcription model"), systemImage: "arrow.down.circle",
                    trailing: "630 MB") { Task { await transcriber.installModel() } }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Downloading model… %d%%", Int(p * 100))).font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressView(value: p).controlSize(.small)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
        case .preparing:
            Hint(text: L("Preparing transcription model…"), progress: true)
        case .failed(let message):
            Hint(text: message, systemImage: "exclamationmark.circle.fill", tint: .red)
            MenuRow(transcriber.isInstalled ? L("Try again") : L("Download transcription model"),
                    systemImage: "arrow.clockwise") { Task { await transcriber.installModel() } }
        case .ready, .transcribing:
            EmptyView()
        }
    }
}

// MARK: - Building blocks

/// A clickable, menu-like row with hover highlight.
private struct MenuRow: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    var trailing: String?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, tint: Color? = nil, trailing: String? = nil,
         shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(hovering ? .white : (tint ?? .secondary))
                        .frame(width: 16)
                }
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(hovering ? .white.opacity(0.85) : .secondary)
                }
                if let shortcut {
                    Text(shortcut).font(.system(size: 12))
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7))
                }
            }
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var subtitle: String?

    init(_ title: String, isOn: Binding<Bool>, subtitle: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }
}

private struct MeetingToggle: View {
    @ObservedObject var detector: MeetingDetector

    var body: some View {
        ToggleRow(L("Offer to record meetings"), isOn: $detector.isEnabled,
                  subtitle: detector.active.map { L("Now: %@", $0.name) })
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 2)
            .padding(.bottom, 3)
    }
}

private struct Hint: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var progress = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if progress {
                ProgressView().controlSize(.mini).frame(width: 16)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
            }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }
}

private struct Separator: View {
    var body: some View {
        Divider().padding(.horizontal, 9).padding(.vertical, 5)
    }
}
