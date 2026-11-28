import AppKit
import Foundation
import MeuralSyncCore
import Observation
import Photos
import ServiceManagement
import SwiftUI

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date = Date(), message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

@MainActor
@Observable
final class AppState {
    var config: AppConfig
    var isSyncing = false
    var isMutatingGalleries = false
    var currentProgress: SyncProgress?
    var lastSyncDate: Date?
    var lastError: String?
    var logs: [LogEntry] = []

    var photoAuthStatus: PHAuthorizationStatus = .notDetermined
    var isVerifyingPhotoAccess = false
    var hasFullDiskAccess = false
    var launchAtLoginEnabled = false
    var availablePeople: [String] = []
    private(set) var credentialsVersion = 0
    private(set) var pendingPushVersion = 0
    var retryingPushInstanceIDs: Set<String> = []
    let updater = UpdaterController()

    private let engine = SyncEngine()
    private let photoLibrary = PhotoKitLibrary()
    private let credentialStore = KeychainCredentialStore()
    private let syncStateStore = FileSyncStateStore()
    private var syncTask: Task<Void, Never>?
    private var wakeDelayTask: Task<Void, Never>?
    private var scheduleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var lastScheduledFailureDate: Date?
    private var consecutiveScheduledFailures = 0

    private static let lastScheduledRunKey = "MeuralSync.lastScheduledRunDate"
    private static let lastSyncDateKey = "MeuralSync.lastSyncDate"
    private static let hadPhotoAccessKey = "MeuralSync.hadPhotoAccess"
    private var hasAttemptedSilentPhotoReverify = false

    private var lastScheduledRunDate: Date? {
        didSet {
            UserDefaults.standard.set(lastScheduledRunDate, forKey: Self.lastScheduledRunKey)
        }
    }

    var isPhotoAccessGranted: Bool {
        photoAuthStatus == .authorized || photoAuthStatus == .limited
    }

    var needsFullDiskAccessForPeople: Bool {
        guard !hasFullDiskAccess else { return false }
        return config.instances
            .filter(\.enabled)
            .contains { !$0.people.include.isEmpty || !$0.people.exclude.isEmpty }
    }

    struct PendingPushItem: Identifiable {
        let instance: InstanceConfig
        let push: PendingDevicePush
        var id: String { instance.storageKey }
    }

    var isRetryingDevicePush: Bool {
        !retryingPushInstanceIDs.isEmpty
    }

    var pendingDevicePushes: [PendingPushItem] {
        _ = pendingPushVersion
        return config.instances.compactMap { instance in
            guard let push = syncStateStore.pendingDevicePush(for: instance.storageKey) else {
                return nil
            }
            return PendingPushItem(instance: instance, push: push)
        }
    }

    var missingCredentialsInstanceNames: [String] {
        _ = credentialsVersion
        return config.instances
            .filter(\.enabled)
            .filter { !hasCredentials(for: $0) }
            .map(\.name)
    }

    var nextScheduledSyncDate: Date? {
        guard let schedule = config.schedule, schedule.enabled else { return nil }
        return schedule.nextRunDate(after: Date(), lastRun: lastScheduledRunDate)
    }

    static var configFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MeuralSync", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    init() {
        let (loadedConfig, loadWarning, needsSave) = Self.loadConfig()
        self.config = loadedConfig
        self.lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncDateKey) as? Date
        self.lastScheduledRunDate = UserDefaults.standard.object(forKey: Self.lastScheduledRunKey) as? Date
        if let loadWarning {
            self.lastError = loadWarning
        }
        if needsSave {
            saveConfig()
        }
        refreshPermissions()
        refreshLaunchAtLogin()
        startSchedulerTimer()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCheckAfterWake()
            }
        }

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
            }
        }
    }

    // MARK: - Config Persistence

    private static func loadConfig() -> (AppConfig, String?, Bool) {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                AppConfig(
                    instances: [InstanceConfig(name: "Family Meural")],
                    schedule: ScheduleConfig(enabled: false, hour: 12, minute: 0)
                ),
                nil,
                true
            )
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            // Detect legacy configs where any instance lacked a persisted UUID "id" field.
            var missingInstanceID = false
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawInstances = raw["instances"] as? [[String: Any]]
            {
                missingInstanceID = rawInstances.contains { $0["id"] == nil }
            }
            return (decoded, nil, missingInstanceID)
        } catch {
            // Back up the unreadable config so subsequent edits do not destroy it.
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("config.backup-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backupURL)
            let warning = "Config file could not be decoded (backed up to \(backupURL.lastPathComponent)): \(error.localizedDescription)"
            return (
                AppConfig(
                    instances: [InstanceConfig(name: "Family Meural")],
                    schedule: ScheduleConfig(enabled: false, hour: 12, minute: 0)
                ),
                warning,
                false
            )
        }
    }

    func saveConfig() {
        let url = Self.configFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            appendLog("Failed to save config: \(error.localizedDescription)")
        }
    }

    func importConfigJSON(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(AppConfig.self, from: data)
            var merged = imported
            if merged.schedule == nil {
                merged.schedule = config.schedule ?? ScheduleConfig(enabled: false, hour: 12, minute: 0)
            }
            config = merged
            saveConfig()
            appendLog("Imported \(merged.instances.count) instance(s) from \(url.lastPathComponent)")
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
            appendLog("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Permissions & Login Item

    func refreshPermissions() {
        let status = PhotoKitLibrary.authorizationStatus()
        photoAuthStatus = status
        if isPhotoAccessGranted {
            UserDefaults.standard.set(true, forKey: Self.hadPhotoAccessKey)
            isVerifyingPhotoAccess = false
        } else if status == .notDetermined,
                  !hasAttemptedSilentPhotoReverify,
                  UserDefaults.standard.bool(forKey: Self.hadPhotoAccessKey) || lastSyncDate != nil
        {
            // After an app update, PhotoKit can transiently report `.notDetermined` until
            // `requestAuthorization` re-checks TCC (which resolves silently when already granted).
            hasAttemptedSilentPhotoReverify = true
            isVerifyingPhotoAccess = true
            Task { @MainActor [weak self] in
                let resolved = await PhotoKitLibrary.requestAuthorization()
                guard let self else { return }
                self.photoAuthStatus = resolved
                self.isVerifyingPhotoAccess = false
                if self.isPhotoAccessGranted {
                    UserDefaults.standard.set(true, forKey: Self.hadPhotoAccessKey)
                    self.refreshPermissions()
                }
            }
            return
        }

        let library = photoLibrary
        let photoOK = isPhotoAccessGranted
        Task.detached(priority: .utility) {
            let fda = PhotosDatabase.hasFullDiskAccess()
            let names: [String]
            if photoOK {
                names = (try? await library.fetchAllPersonNames()) ?? []
            } else if fda {
                names = (try? PhotosDatabase().fetchAllPersonNames()) ?? []
            } else {
                names = []
            }
            await MainActor.run {
                self.hasFullDiskAccess = fda
                self.availablePeople = names
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPhotoAccess() {
        Task {
            NSApp.activate()
            let status = await PhotoKitLibrary.requestAuthorization()
            photoAuthStatus = status
            if isPhotoAccessGranted {
                refreshPermissions()
            }
        }
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            appendLog("Launch at Login error: \(error.localizedDescription)")
            refreshLaunchAtLogin()
        }
    }

    // MARK: - Credentials (Keyed by Stable UUID with Legacy Name Fallback)

    private func resolvedCredentialKey(for instance: InstanceConfig) -> String {
        if credentialStore.hasCredentials(for: instance.storageKey) {
            return instance.storageKey
        }
        if credentialStore.hasCredentials(for: instance.name) {
            return instance.name
        }
        return instance.storageKey
    }

    func hasCredentials(for instance: InstanceConfig) -> Bool {
        _ = credentialsVersion
        return credentialStore.hasCredentials(for: instance.storageKey)
            || credentialStore.hasCredentials(for: instance.name)
    }

    func loadEmail(for instance: InstanceConfig) -> String {
        let key = resolvedCredentialKey(for: instance)
        return (try? credentialStore.getCredentials(for: key).email) ?? ""
    }

    func saveCredentials(for instance: InstanceConfig, email: String, password: String) throws {
        try credentialStore.setCredentials(
            MeuralCredentials(email: email, password: password),
            for: instance.storageKey
        )
        // Ensure the instance UUID is persisted on disk before removing any legacy name-keyed entry.
        saveConfig()
        if instance.name != instance.storageKey {
            try? credentialStore.deleteCredentials(for: instance.name)
        }
        credentialsVersion += 1
    }

    func deleteCredentials(for instance: InstanceConfig) {
        try? credentialStore.deleteCredentials(for: instance.storageKey)
        try? credentialStore.deleteCredentials(for: instance.name)
        syncStateStore.clearInstanceState(for: instance.storageKey)
        credentialsVersion += 1
        pendingPushVersion += 1
    }

    func testConnection(for instance: InstanceConfig) async -> Result<Int, Error> {
        do {
            let client = makeMeuralClient(for: instance)
            try await client.reauthenticate()
            let devices = try await client.getDevices()
            return .success(devices.count)
        } catch {
            return .failure(error)
        }
    }

    func makeMeuralClient(for instance: InstanceConfig) -> MeuralClient {
        let key = resolvedCredentialKey(for: instance)
        return MeuralClient(instanceName: key, credentialStore: credentialStore)
    }

    func trackedGalleryIDs(for instance: InstanceConfig) -> Set<Int> {
        syncStateStore.trackedGalleryIDs(for: instance.storageKey)
    }

    func recordManualGalleryDeletion(_ galleryID: Int, deletedItemIDs: Set<Int>, for instance: InstanceConfig) {
        syncStateStore.removeGalleryID(galleryID, for: instance.storageKey)
        syncStateStore.removeItemIDs(deletedItemIDs, for: instance.storageKey)
        if syncStateStore.pendingDevicePush(for: instance.storageKey)?.galleryID == galleryID {
            syncStateStore.setPendingDevicePush(nil, for: instance.storageKey)
            pendingPushVersion += 1
        }
    }

    func recordManualItemDeletion(_ itemID: Int, for instance: InstanceConfig) {
        syncStateStore.removeItemIDs([itemID], for: instance.storageKey)
    }

    func recordManualItemsDeletion(_ itemIDs: Set<Int>, for instance: InstanceConfig) {
        syncStateStore.removeItemIDs(itemIDs, for: instance.storageKey)
    }

    func recordFailedDevicePush(galleryID: Int, galleryName: String, errorMessage: String, for instance: InstanceConfig) {
        syncStateStore.setPendingDevicePush(
            PendingDevicePush(galleryID: galleryID, galleryName: galleryName, errorMessage: errorMessage),
            for: instance.storageKey
        )
        pendingPushVersion += 1
    }

    func clearPendingDevicePush(for instance: InstanceConfig) {
        syncStateStore.setPendingDevicePush(nil, for: instance.storageKey)
        pendingPushVersion += 1
    }

    func retryDevicePush(for instance: InstanceConfig) {
        let key = instance.storageKey
        guard !isSyncing, !isMutatingGalleries, !retryingPushInstanceIDs.contains(key) else { return }
        guard let pending = syncStateStore.pendingDevicePush(for: key) else { return }

        retryingPushInstanceIDs.insert(key)
        appendLog("Retrying send of '\(pending.galleryName)' (id: \(pending.galleryID)) to \(instance.name) frame(s)...")

        Task {
            defer {
                self.retryingPushInstanceIDs.remove(key)
            }
            do {
                let client = self.makeMeuralClient(for: instance)
                let count = try await client.pushGalleryToDevices(galleryID: pending.galleryID)
                guard count > 0 else {
                    throw MeuralAPIError.httpError(
                        statusCode: 0,
                        method: "PUSH",
                        url: "devices",
                        body: "No Meural frames found on account"
                    )
                }
                if self.syncStateStore.pendingDevicePush(for: key)?.galleryID == pending.galleryID {
                    self.syncStateStore.setPendingDevicePush(nil, for: key)
                    self.pendingPushVersion += 1
                }
                let label = count == 1 ? "1 Meural frame" : "\(count) Meural frames"
                self.appendLog("Successfully sent '\(pending.galleryName)' to \(label) for \(instance.name).")
            } catch {
                if self.syncStateStore.pendingDevicePush(for: key)?.galleryID == pending.galleryID {
                    self.syncStateStore.setPendingDevicePush(
                        PendingDevicePush(
                            galleryID: pending.galleryID,
                            galleryName: pending.galleryName,
                            errorMessage: error.localizedDescription
                        ),
                        for: key
                    )
                    self.pendingPushVersion += 1
                }
                self.appendLog("Retry send to frame failed for \(instance.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sync & Scheduling

    func startSync(isScheduled: Bool = false) {
        guard !isSyncing, !isMutatingGalleries, !isRetryingDevicePush else { return }
        isSyncing = true
        lastError = nil
        currentProgress = SyncProgress(instanceName: "", phase: "Starting sync...")
        let snapshot = config
        let library = photoLibrary

        enum SyncEvent: Sendable {
            case progress(SyncProgress)
            case log(String)
        }

        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        let eventConsumer = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case .progress(let progress):
                    if self.isSyncing {
                        self.currentProgress = progress
                    }
                case .log(let message):
                    self.appendLog(message)
                }
            }
        }

        syncTask = Task {
            do {
                try await engine.runSync(
                    config: snapshot,
                    credentialStore: credentialStore,
                    photoLibrary: library,
                    stateStore: syncStateStore,
                    onProgress: { progress in
                        continuation.yield(.progress(progress))
                    },
                    onLog: { message in
                        continuation.yield(.log(message))
                    }
                )
                continuation.finish()
                await eventConsumer.value

                let completedAt = Date()
                self.lastSyncDate = completedAt
                UserDefaults.standard.set(completedAt, forKey: Self.lastSyncDateKey)
                self.consecutiveScheduledFailures = 0
                self.lastScheduledFailureDate = nil
                if isScheduled {
                    self.lastScheduledRunDate = completedAt
                }
                self.appendLog("All enabled instances synced successfully.")
            } catch is CancellationError {
                continuation.finish()
                await eventConsumer.value
                self.handleCancellation(isScheduled: isScheduled)
            } catch let error as URLError where error.code == .cancelled {
                continuation.finish()
                await eventConsumer.value
                self.handleCancellation(isScheduled: isScheduled)
            } catch {
                continuation.finish()
                await eventConsumer.value
                if isScheduled {
                    self.handleScheduledFailure(error)
                }
                self.lastError = error.localizedDescription
                self.appendLog("Sync failed: \(error.localizedDescription)")
            }
            self.pendingPushVersion += 1
            self.isSyncing = false
            self.currentProgress = nil
            self.syncTask = nil
        }
    }

    func cancelSync() {
        syncTask?.cancel()
    }

    func appendLog(_ message: String) {
        logs.append(LogEntry(message: message))
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    /// Seeds `lastScheduledRunDate` when the user enables or edits the schedule so
    /// adjusting the time picker doesn't immediately ambush them with a sync 30s later.
    func seedScheduleAfterEdit() {
        lastScheduledRunDate = Date()
        lastScheduledFailureDate = nil
        consecutiveScheduledFailures = 0
    }

    private func handleCancellation(isScheduled: Bool) {
        if isScheduled {
            // Do not immediately re-trigger the cancelled scheduled slot on the next 30s timer tick.
            lastScheduledRunDate = Date()
            consecutiveScheduledFailures = 0
            lastScheduledFailureDate = nil
        }
        appendLog("Sync cancelled.")
    }

    private func handleScheduledFailure(_ error: Error) {
        let now = Date()
        if Self.isNonRetryableScheduledError(error) {
            // Do not auto-retry broken credentials, permissions, or empty-match configs until the next scheduled slot.
            lastScheduledRunDate = now
            consecutiveScheduledFailures = 0
            lastScheduledFailureDate = nil
            appendLog("Scheduled sync will wait until the next scheduled slot due to a non-transient error.")
            return
        }

        consecutiveScheduledFailures += 1
        lastScheduledFailureDate = now
        if consecutiveScheduledFailures >= 3 {
            // Cap transient retries at 3 per scheduled slot to avoid infinite retry storms.
            lastScheduledRunDate = now
            consecutiveScheduledFailures = 0
            lastScheduledFailureDate = nil
            appendLog("Scheduled sync reached maximum retry attempts; waiting until the next scheduled slot.")
        }
    }

    private static func isNonRetryableScheduledError(_ error: Error) -> Bool {
        if error is CredentialError || error is PhotoLibraryMetadataError {
            return true
        }
        if case PhotoExportError.photoLibraryUnauthorized = error {
            return true
        }
        if case SyncError.missingCredentials = error {
            return true
        }
        if case SyncError.noPhotosUploaded = error {
            return true
        }
        if case MeuralAPIError.authenticationFailed = error {
            return true
        }
        return false
    }

    private func startSchedulerTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSchedule()
            }
        }
    }

    private func scheduleCheckAfterWake() {
        wakeDelayTask?.cancel()
        wakeDelayTask = Task { @MainActor [weak self] in
            // Give Wi-Fi / DHCP a few seconds to reconnect after wake before triggering a sync.
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkSchedule()
        }
    }

    private func checkSchedule() {
        guard let schedule = config.schedule,
              schedule.enabled,
              !isSyncing,
              !isMutatingGalleries,
              !isRetryingDevicePush,
              !config.instances.filter(\.enabled).isEmpty
        else { return }
        guard isPhotoAccessGranted else { return }

        let now = Date()
        // Exponential backoff between transient scheduled retries: 5 min, 15 min (capped at 3 attempts per slot).
        if let lastFailure = lastScheduledFailureDate, consecutiveScheduledFailures > 0 {
            let backoffSeconds = 300.0 * pow(3.0, Double(consecutiveScheduledFailures - 1))
            if now.timeIntervalSince(lastFailure) < backoffSeconds {
                return
            }
        }

        guard schedule.isDue(at: now, lastRun: lastScheduledRunDate) else { return }
        appendLog("Starting scheduled sync (\(schedule.frequency.displayName)).")
        startSync(isScheduled: true)
    }
}
