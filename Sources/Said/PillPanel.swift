import AppKit
import SwiftUI

/// Borderless, non-activating floating panel centred on screen.
/// It never steals focus from the app you're working in.
@MainActor
final class PillPanel {
    private let panel: NSPanel

    init(recorder: Recorder) {
        let size = NSSize(width: 260, height: 56)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: PillView().environmentObject(recorder))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        }
    }
}

struct PillView: View {
    @EnvironmentObject var recorder: Recorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: 3, height: 4 + CGFloat(level) * 24)
                }
            }
            .frame(height: 28)
            .animation(.easeOut(duration: 0.08), value: recorder.levels)

            Text(recorder.elapsed.clock)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)

            Button(action: recorder.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Zakończ nagrywanie")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}
