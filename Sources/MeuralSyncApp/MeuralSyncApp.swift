import AppKit
import MeuralSyncCore
import SwiftUI

@main
struct MeuralSyncApp: App {
    @State private var appState = AppState()

    init() {
        MainActor.assumeIsolated {
            DockVisibilityManager.shared.startObserving()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarIconLabel(
                isSyncing: appState.isSyncing,
                hasError: appState.lastError != nil
            )
        }
        .menuBarExtraStyle(.window)

        Window("Meural Galleries", id: "galleries") {
            GalleriesView(appState: appState)
        }
        .defaultSize(width: 880, height: 600)

        Window("MeuralSync Logs", id: "logs") {
            LogsView(appState: appState)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

/// Shows the app in the Dock (`.regular`) whenever any standard app window
/// (Galleries, Logs, Settings) is open, and returns to menu-bar-only (`.accessory`)
/// once all app windows are closed.
@MainActor
final class DockVisibilityManager {
    static let shared = DockVisibilityManager()

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window, self.isStandardAppWindow(window) else { return }
                    self.setPolicy(.regular)
                }
            }
        )

        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                let closingWindow = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let closingWindow, self.isStandardAppWindow(closingWindow) else { return }
                    Task { @MainActor [weak self, weak closingWindow] in
                        self?.syncPolicy(excluding: closingWindow)
                    }
                }
            }
        )
    }

    func showInDockAndActivate() {
        setPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func isStandardAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.canBecomeMain
            && window.styleMask.contains(.titled)
    }

    private func syncPolicy(excluding closingWindow: NSWindow? = nil) {
        let hasOpenWindow = NSApp.windows.contains { window in
            window !== closingWindow
                && isStandardAppWindow(window)
                && (window.isVisible || window.isMiniaturized)
        }
        setPolicy(hasOpenWindow ? .regular : .accessory)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

/// Renders the menu bar status icon (matching the MeuralSync portrait-frame AppIcon)
/// and smoothly rotates a sync indicator while a sync is in progress.
private struct MenuBarIconLabel: View {
    let isSyncing: Bool
    let hasError: Bool

    @State private var frameIndex = 0

    /// Custom 18x18 template icon matching AppIcon.svg: portrait gallery frame with sunset mountains & sun.
    private static let idleFrameIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.labelColor.cgColor)
            ctx.setFillColor(NSColor.labelColor.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Outer portrait Meural frame (12x15 centered in 18x18)
            let frameRect = CGRect(x: 3.0, y: 1.5, width: 12.0, height: 15.0)
            let outerPath = CGPath(roundedRect: frameRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
            ctx.setLineWidth(1.5)
            ctx.addPath(outerPath)
            ctx.strokePath()

            // Sun dot in upper-right inside the frame
            ctx.fillEllipse(in: CGRect(x: 10.6, y: 11.4, width: 2.2, height: 2.2))

            // Mountain peaks silhouette inside the bottom of the frame (clipped inside inner frame)
            ctx.saveGState()
            let innerClip = CGPath(roundedRect: frameRect.insetBy(dx: 1.2, dy: 1.2), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)
            ctx.addPath(innerClip)
            ctx.clip()

            ctx.beginPath()
            ctx.move(to: CGPoint(x: 3.5, y: 2.0))
            ctx.addLine(to: CGPoint(x: 7.4, y: 8.6))
            ctx.addLine(to: CGPoint(x: 10.1, y: 5.5))
            ctx.addLine(to: CGPoint(x: 12.0, y: 7.6))
            ctx.addLine(to: CGPoint(x: 14.8, y: 2.0))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()

            return true
        }
        img.isTemplate = true
        return img
    }()

    private static let syncFrames: [NSImage] = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Syncing")?
            .withSymbolConfiguration(config)
        else {
            return []
        }

        let size = NSSize(width: 18, height: 18)
        let frameCount = 12
        return (0..<frameCount).map { idx in
            let angle = -CGFloat(idx) * (2.0 * .pi / CGFloat(frameCount))
            let img = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: angle)
                let drawSize = base.size
                let drawRect = CGRect(
                    x: -drawSize.width / 2,
                    y: -drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                base.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
                return true
            }
            img.isTemplate = true
            return img
        }
    }()

    var body: some View {
        Group {
            if isSyncing, !Self.syncFrames.isEmpty {
                Image(nsImage: Self.syncFrames[frameIndex % Self.syncFrames.count])
                    .accessibilityLabel("MeuralSync Syncing")
            } else if hasError {
                Label("MeuralSync Error", systemImage: "exclamationmark.triangle")
            } else {
                Image(nsImage: Self.idleFrameIcon)
                    .accessibilityLabel("MeuralSync")
            }
        }
        .task(id: isSyncing) {
            guard isSyncing else {
                frameIndex = 0
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 10 fps smooth spin
                guard !Task.isCancelled else { break }
                frameIndex = (frameIndex + 1) % max(1, Self.syncFrames.count)
            }
        }
    }
}
