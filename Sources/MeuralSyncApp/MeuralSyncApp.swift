import AppKit
import MeuralSyncCore
import SwiftUI

@main
struct MeuralSyncApp: App {
    @State private var appState = AppState()

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

/// Renders the menu bar status icon and smoothly rotates it while a sync is in progress.
private struct MenuBarIconLabel: View {
    let isSyncing: Bool
    let hasError: Bool

    @State private var frameIndex = 0

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
            } else {
                Label(
                    "MeuralSync",
                    systemImage: hasError ? "exclamationmark.triangle" : "photo.on.rectangle.angled"
                )
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
