import AppKit
import MeuralSyncCore
import Photos
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MeuralSync")
                        .font(.headline)
                    statusSubtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !appState.isPhotoAccessGranted {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(
                        appState.photoAuthStatus == .notDetermined
                            ? "Photos Library access is required to sync."
                            : "Photos Library access is denied in System Settings."
                    )
                    .font(.caption)
                    Spacer()
                    if appState.photoAuthStatus == .notDetermined {
                        Button("Grant") {
                            appState.requestPhotoAccess()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Open Settings") {
                            appState.openPhotosPrivacySettings()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else if appState.photoAuthStatus == .limited {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.checkmark")
                        .foregroundStyle(.yellow)
                    Text("Limited Photos access; only selected photos can sync.")
                        .font(.caption)
                    Spacer()
                    Button("Settings") {
                        appState.openPhotosPrivacySettings()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if appState.needsFullDiskAccessForPeople {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .foregroundStyle(.orange)
                    Text("Full Disk Access needed for People filtering.")
                        .font(.caption)
                    Spacer()
                    Button("Grant") {
                        appState.openFullDiskAccessSettings()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            let missingCreds = appState.missingCredentialsInstanceNames
            if !missingCreds.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("Missing Meural credentials for \(missingCreds.joined(separator: ", ")).")
                        .font(.caption)
                    Spacer()
                    Button("Configure") {
                        DockVisibilityManager.shared.showInDockAndActivate()
                        openSettings()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            ForEach(appState.pendingDevicePushes) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Failed to send '\(item.push.galleryName)' to \(item.instance.name).")
                            .font(.caption.bold())
                        Text(item.push.errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if appState.retryingPushInstanceIDs.contains(item.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Retry") {
                            appState.retryDevicePush(for: item.instance)
                        }
                        .controlSize(.small)
                        .disabled(appState.isSyncing)
                    }
                    Button {
                        appState.clearPendingDevicePush(for: item.instance)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let progress = appState.currentProgress {
                VStack(alignment: .leading, spacing: 4) {
                    if !progress.instanceName.isEmpty {
                        Text(progress.instanceName)
                            .font(.caption.bold())
                    }
                    Text(progress.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if progress.total > 0 {
                        ProgressView(value: progress.fractionCompleted)
                    }
                }
            }

            if let err = appState.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button {
                        appState.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss error")
                }
            }

            Divider()

            HStack {
                if appState.isSyncing {
                    Button("Cancel Sync") {
                        appState.cancelSync()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Sync Now") {
                        appState.startSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        appState.config.instances.filter(\.enabled).isEmpty
                            || !appState.isPhotoAccessGranted
                            || !missingCreds.isEmpty
                            || appState.isMutatingGalleries
                            || appState.isRetryingDevicePush
                    )
                }

                Spacer()

                Button("Albums") {
                    DockVisibilityManager.shared.showInDockAndActivate()
                    openWindow(id: "galleries")
                }

                Button("Logs") {
                    DockVisibilityManager.shared.showInDockAndActivate()
                    openWindow(id: "logs")
                }

                Button("Settings…") {
                    DockVisibilityManager.shared.showInDockAndActivate()
                    openSettings()
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(appState.config.instances.filter(\.enabled).count) enabled instance(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let next = appState.nextScheduledSyncDate {
                        Text("Next sync: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.updater.isConfigured {
                    Button("Updates…") {
                        appState.updater.checkForUpdates()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!appState.updater.canCheckForUpdates)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        if appState.isSyncing {
            Text("Syncing…")
        } else if let last = appState.lastSyncDate {
            Text("Last synced \(last.formatted(date: .abbreviated, time: .shortened))")
        } else {
            Text("Ready")
        }
    }
}
