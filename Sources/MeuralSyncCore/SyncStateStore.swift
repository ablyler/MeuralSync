import Foundation

/// Records a failed attempt to push/switch a gallery onto one or more Meural frames
/// so the menu bar can surface a one-click Retry action until it succeeds.
public struct PendingDevicePush: Codable, Sendable, Equatable {
    public let galleryID: Int
    public let galleryName: String
    public let errorMessage: String
    public let failedAt: Date

    public init(galleryID: Int, galleryName: String, errorMessage: String, failedAt: Date = Date()) {
        self.galleryID = galleryID
        self.galleryName = galleryName
        self.errorMessage = errorMessage
        self.failedAt = failedAt
    }
}

/// Persists Meural gallery and item IDs created by MeuralSync so cleanup never deletes
/// user-owned galleries or items that MeuralSync did not create.
public protocol SyncStateStoring: Sendable {
    func trackedGalleryIDs(for instanceKey: String) -> Set<Int>
    func recordGalleryID(_ id: Int, for instanceKey: String)
    func removeGalleryID(_ id: Int, for instanceKey: String)

    func trackedItemIDs(for instanceKey: String) -> Set<Int>
    func recordItemID(_ id: Int, for instanceKey: String)
    func removeItemIDs(_ ids: Set<Int>, for instanceKey: String)

    func pendingDevicePush(for instanceKey: String) -> PendingDevicePush?
    func setPendingDevicePush(_ push: PendingDevicePush?, for instanceKey: String)
}

private struct PersistedSyncState: Codable {
    var galleryIDsByInstance: [String: [Int]] = [:]
    var itemIDsByInstance: [String: [Int]] = [:]
    var pendingDevicePushByInstance: [String: PendingDevicePush] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.galleryIDsByInstance = try container.decodeIfPresent([String: [Int]].self, forKey: .galleryIDsByInstance) ?? [:]
        self.itemIDsByInstance = try container.decodeIfPresent([String: [Int]].self, forKey: .itemIDsByInstance) ?? [:]
        self.pendingDevicePushByInstance = try container.decodeIfPresent([String: PendingDevicePush].self, forKey: .pendingDevicePushByInstance) ?? [:]
    }
}

public final class FileSyncStateStore: SyncStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var state: PersistedSyncState

    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MeuralSync", isDirectory: true)
            .appendingPathComponent("sync_state.json")
    }

    public init(fileURL: URL = FileSyncStateStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedSyncState.self, from: data)
        {
            self.state = decoded
        } else {
            self.state = PersistedSyncState()
        }
    }

    public func trackedGalleryIDs(for instanceKey: String) -> Set<Int> {
        lock.withLock {
            Set(state.galleryIDsByInstance[instanceKey] ?? [])
        }
    }

    public func recordGalleryID(_ id: Int, for instanceKey: String) {
        lock.withLock {
            var set = Set(state.galleryIDsByInstance[instanceKey] ?? [])
            if set.insert(id).inserted {
                state.galleryIDsByInstance[instanceKey] = set.sorted()
                persistLocked()
            }
        }
    }

    public func removeGalleryID(_ id: Int, for instanceKey: String) {
        lock.withLock {
            var set = Set(state.galleryIDsByInstance[instanceKey] ?? [])
            if set.remove(id) != nil {
                state.galleryIDsByInstance[instanceKey] = set.sorted()
                persistLocked()
            }
        }
    }

    public func trackedItemIDs(for instanceKey: String) -> Set<Int> {
        lock.withLock {
            Set(state.itemIDsByInstance[instanceKey] ?? [])
        }
    }

    public func recordItemID(_ id: Int, for instanceKey: String) {
        lock.withLock {
            var set = Set(state.itemIDsByInstance[instanceKey] ?? [])
            if set.insert(id).inserted {
                state.itemIDsByInstance[instanceKey] = set.sorted()
                persistLocked()
            }
        }
    }

    public func removeItemIDs(_ ids: Set<Int>, for instanceKey: String) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var set = Set(state.itemIDsByInstance[instanceKey] ?? [])
            let before = set.count
            set.subtract(ids)
            if set.count != before {
                state.itemIDsByInstance[instanceKey] = set.sorted()
                persistLocked()
            }
        }
    }

    public func pendingDevicePush(for instanceKey: String) -> PendingDevicePush? {
        lock.withLock {
            state.pendingDevicePushByInstance[instanceKey]
        }
    }

    public func setPendingDevicePush(_ push: PendingDevicePush?, for instanceKey: String) {
        lock.withLock {
            if state.pendingDevicePushByInstance[instanceKey] != push {
                state.pendingDevicePushByInstance[instanceKey] = push
                persistLocked()
            }
        }
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence; in-memory state remains accurate for the current session.
        }
    }
}

public final class InMemorySyncStateStore: SyncStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var galleryIDs: [String: Set<Int>] = [:]
    private var itemIDs: [String: Set<Int>] = [:]
    private var pendingPushes: [String: PendingDevicePush] = [:]

    public init() {}

    public func trackedGalleryIDs(for instanceKey: String) -> Set<Int> {
        lock.withLock { galleryIDs[instanceKey] ?? [] }
    }

    public func recordGalleryID(_ id: Int, for instanceKey: String) {
        lock.withLock { _ = galleryIDs[instanceKey, default: []].insert(id) }
    }

    public func removeGalleryID(_ id: Int, for instanceKey: String) {
        lock.withLock { _ = galleryIDs[instanceKey, default: []].remove(id) }
    }

    public func trackedItemIDs(for instanceKey: String) -> Set<Int> {
        lock.withLock { itemIDs[instanceKey] ?? [] }
    }

    public func recordItemID(_ id: Int, for instanceKey: String) {
        lock.withLock { _ = itemIDs[instanceKey, default: []].insert(id) }
    }

    public func removeItemIDs(_ ids: Set<Int>, for instanceKey: String) {
        lock.withLock { itemIDs[instanceKey, default: []].subtract(ids) }
    }

    public func pendingDevicePush(for instanceKey: String) -> PendingDevicePush? {
        lock.withLock { pendingPushes[instanceKey] }
    }

    public func setPendingDevicePush(_ push: PendingDevicePush?, for instanceKey: String) {
        lock.withLock { pendingPushes[instanceKey] = push }
    }
}
