import AppKit
import SwiftUI

/// Borderless, non-activating floating panel. Shows near the bottom of the screen,
/// can be dragged anywhere, and remembers where you left it.
/// It never steals focus from the app you're working in.
@MainActor
final class PillPanel {
    private let panel: NSPanel
    private static let originKey = "pillOrigin"

    init(recorder: Recorder) {
        let size = NSSize(width: 196, height: 38)
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

        let host = DraggableHostingView(rootView: PillView().environmentObject(recorder))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show() {
        panel.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide() {
        let o = panel.frame.origin
        UserDefaults.standard.set([o.x, o.y], forKey: Self.originKey)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        }
    }

    /// Bottom centre of the main screen, just above the Dock.
    private func defaultOrigin() -> NSPoint {
        guard let f = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 40)
    }

    /// Last dragged position, if it is still on a connected screen.
    private func savedOrigin() -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], xy.count == 2
        else { return nil }
        let p = NSPoint(x: xy[0], y: xy[1])
        let rect = NSRect(origin: p, size: panel.frame.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? p : nil
    }
}

/// Lets a click-and-drag anywhere on the pill (except the button) move the window.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
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
            .help("Zakończ nagrywanie")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }
}
