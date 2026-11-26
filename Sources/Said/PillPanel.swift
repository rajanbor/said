import AppKit
import SwiftUI

/// Borderless, non-activating floating panel. It appears either at the bottom centre of the
/// screen (the recording pill, which you can then drag anywhere) or just under the menu bar
/// on the right (the card shown when a recording ends).
/// It never steals focus from the app you're working in.
@MainActor
final class FloatingPanel {
    enum Anchor {
        /// Bottom centre of the main screen, just above the Dock.
        case bottomCenter
        /// Top right, right under the menu bar — next to Said's own icon.
        case topTrailing
    }

    private let panel: NSPanel
    private let anchor: Anchor
    /// Builds the content view. It is thrown away whenever the panel hides: an animation in a
    /// hidden SwiftUI view keeps redrawing (and keeps the CPU awake) as if it were on screen.
    private let build: () -> NSView
    private var installed = false
    /// True while fading out, so a `show()` in that moment cancels the hide.
    private var hiding = false

    init<Content: View>(size: NSSize, anchor: Anchor = .bottomCenter,
                        @ViewBuilder content: @escaping () -> Content) {
        self.anchor = anchor
        self.build = {
            let host = NSHostingView(rootView: content())
            host.frame = NSRect(origin: .zero, size: size)
            return host
        }
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        hiding = false
        // Already up (and perhaps dragged somewhere): leave it where it is.
        if panel.isVisible {
            panel.alphaValue = 1
            return panel.orderFrontRegardless()
        }
        if !installed {
            panel.contentView = build()
            installed = true
        }
        panel.setFrameOrigin(origin())
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.hiding else { return }   // shown again while fading out
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.contentView = nil
                self.installed = false
            }
        }
    }

    private func origin() -> NSPoint {
        guard let f = NSScreen.main?.visibleFrame else { return .zero }
        let size = panel.frame.size
        switch anchor {
        case .bottomCenter:
            return NSPoint(x: f.midX - size.width / 2, y: f.minY + 40)
        case .topTrailing:
            return NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 8)
        }
    }
}

/// Drag the pill anywhere by grabbing it outside its buttons.
///
/// AppKit's "movable by window background" doesn't work here: SwiftUI's hosting view
/// handles the mouse itself. So the drag is a SwiftUI gesture that moves the window,
/// and buttons still win because the drag only starts after the mouse moves a little.
private struct WindowDrag: ViewModifier {
    @State private var start: (mouse: NSPoint, origin: NSPoint)?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    guard let window = NSApp.currentEvent?.window else { return }
                    let mouse = NSEvent.mouseLocation   // screen coordinates, unaffected by the move
                    if start == nil { start = (mouse, window.frame.origin) }
                    guard let start else { return }
                    window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                                  y: start.origin.y + mouse.y - start.mouse.y))
                }
                .onEnded { _ in start = nil }
        )
    }
}

/// Black capsule shared by both pills.
private struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .contentShape(Capsule())
            .modifier(WindowDrag())
            .environment(\.colorScheme, .dark)
    }
}

struct PillView: View {
    @EnvironmentObject var recorder: Recorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2, height: 3 + CGFloat(level) * 16)
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.08), value: recorder.levels)

            Text(recorder.elapsed.clock)
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)

            Button(action: recorder.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 20, height: 20)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L("Stop recording"))
        }
        .modifier(PillBackground())
    }
}

/// "Zoom · Record and transcribe?" shown when a meeting starts.
struct MeetingPromptView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recorder.promptIsExternal ? "link" : "person.2.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 0) {
                Text(recorder.promptIsExternal ? L("Start recording?") : (recorder.promptMeeting?.name ?? L("Meeting")))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(recorder.promptIsExternal ? L("Requested by another app") : L("Record and transcribe?"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .foregroundStyle(Color.white)

            Spacer(minLength: 4)

            Button(action: recorder.acceptMeetingPrompt) {
                Text(L("Record"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: recorder.dismissMeetingPrompt) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(L("Not now"))
        }
        .modifier(PillBackground())
    }
}


/// Black rounded card, for the panel shown after a recording.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

/// Appears under the menu bar when a recording ends: what was saved, and what Said is still
/// doing with it (saving, transcribing, writing the summary). Goes away by itself.
struct ResultCardView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var transcriber: Transcriber
    @EnvironmentObject var summarizer: Summarizer

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.white)

            Spacer(minLength: 4)

            if recorder.finished?.stage == .done, recorder.finished?.hasTranscript == true {
                Button {
                    recorder.openTranscript()
                    recorder.hideResult()
                } label: {
                    Text(L("Open"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: recorder.hideResult) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(L("Close"))
        }
        .modifier(CardBackground())
        // Stays as long as you are looking at it.
        .onHover { recorder.holdResult($0) }
    }

    @ViewBuilder
    private var icon: some View {
        switch recorder.finished?.stage {
        case .done:
            Image(systemName: recorder.finished?.hasTranscript == true ? "doc.text.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.8))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        if recorder.finished?.stage == .done, recorder.finished?.hasTranscript == true {
            return L("Transcript ready")
        }
        return L("Recording saved")
    }

    private var status: String {
        guard let card = recorder.finished else { return "" }
        switch card.stage {
        case .saving:
            return L("Saving…")
        case .transcribing:
            return transcriber.statusText
        case .summarizing:
            if case .summarizing(let part) = summarizer.state {
                return [L("Writing summary…"), part].compactMap { $0 }.joined(separator: " ")
            }
            return L("Writing summary…")
        case .done:
            return [card.duration.clock, card.source].compactMap { $0 }.joined(separator: " · ")
        case .failed(let message):
            return message
        }
    }
}
