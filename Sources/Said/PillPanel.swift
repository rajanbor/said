import AppKit
import SwiftUI

/// Borderless, non-activating floating panel. Shows near the bottom of the screen,
/// can be dragged anywhere, and remembers where you left it (shared by all pills).
/// It never steals focus from the app you're working in.
@MainActor
final class FloatingPanel {
    private let panel: NSPanel
    private static let centerKey = "pillCenter"

    init<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) {
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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = DraggableHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let c = savedCenter() ?? defaultCenter()
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: c.x - s.width / 2, y: c.y - s.height / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard panel.isVisible else { return }
        let f = panel.frame
        UserDefaults.standard.set([f.midX, f.midY], forKey: Self.centerKey)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        }
    }

    /// Bottom centre of the main screen, just above the Dock.
    private func defaultCenter() -> NSPoint {
        guard let f = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(x: f.midX, y: f.minY + 40 + panel.frame.height / 2)
    }

    /// Last dragged position, if it is still on a connected screen.
    private func savedCenter() -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: Self.centerKey) as? [Double], xy.count == 2
        else { return nil }
        let p = NSPoint(x: xy[0], y: xy[1])
        return NSScreen.screens.contains { $0.visibleFrame.contains(p) } ? p : nil
    }
}

/// Lets a click-and-drag anywhere on the pill (except buttons) move the window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Black capsule shared by both pills.
private struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
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
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 0) {
                Text(recorder.promptMeeting?.name ?? L("Meeting"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(L("Record and transcribe?"))
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
