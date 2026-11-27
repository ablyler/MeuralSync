import AppKit
import Foundation
import Observation
import Sparkle

/// Wraps Sparkle 2 (`SPUStandardUpdaterController`) for in-app auto-updates.
/// Gracefully disables itself in local dev builds that do not bundle a `SUPublicEDKey`.
@MainActor
@Observable
final class UpdaterController {
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false {
        didSet {
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    init() {
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isBundledApp = Bundle.main.bundleURL.pathExtension == "app"

        guard isBundledApp, !publicKey.isEmpty, !feedURL.isEmpty else {
            self.isConfigured = false
            self.controller = nil
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.isConfigured = true
        self.controller = updaterController
        self.automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        self.canCheckForUpdates = updaterController.updater.canCheckForUpdates

        self.canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheck
            }
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
