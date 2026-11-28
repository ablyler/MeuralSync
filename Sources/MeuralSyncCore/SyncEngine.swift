import CoreGraphics
import CryptoKit
import Foundation
import OSLog

public struct SyncProgress: Sendable, Equatable {
    public let instanceName: String
    public let phase: String
    public let completed: Int
    public let total: Int

    public init(instanceName: String, phase: String, completed: Int = 0, total: Int = 0) {
        self.instanceName = instanceName
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(completed) / Double(total)))
    }
}

public enum SyncError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case missingCredentials([String])
    case noPhotosUploaded(String)
    case tooManyUploadFailures(Int)
    case multipleInstanceFailures([(instanceName: String, message: String)])

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A sync is already in progress."
        case .missingCredentials(let names):
            return "Missing Meural credentials for: \(names.joined(separator: ", "))"
        case .noPhotosUploaded(let instanceName):
            return "No photos were uploaded for '\(instanceName)'. Existing galleries and frames were left unchanged."
        case .tooManyUploadFailures(let count):
            return "Aborted sync after \(count) consecutive Meural upload failures."
        case .multipleInstanceFailures(let failures):
            let details = failures.map { "\($0.instanceName): \($0.message)" }.joined(separator: "; ")
            return "Sync failed for \(failures.count) instance(s): \(details)"
        }
    }
}

/// Core photo selection, "On This Day" matching, and gallery sync orchestration.
public actor SyncEngine {
    public typealias ClientFactory = @Sendable (String, any CredentialStoring, @escaping @Sendable (String) -> Void) -> MeuralClient

    private let logger = Logger(subsystem: "com.ablyler.MeuralSync", category: "SyncEngine")
    private var isRunning = false

    public init() {}

    public var syncing: Bool { isRunning }

    // MARK: - Pure Selection Helpers (Testable)

    /// Returns true if `photoDate` falls within +/- `windowDays` of `referenceDate` in a previous year.
    public static func isOnThisDay(
        photoDate: Date,
        referenceDate: Date = Date(),
        windowDays: Int = 3,
        calendar: Calendar = .current
    ) -> Bool {
        let clampedWindow = max(0, windowDays)
        let refYear = calendar.component(.year, from: referenceDate)
        let photoYear = calendar.component(.year, from: photoDate)
        guard photoYear < refYear else { return false }

        let photoMonth = calendar.component(.month, from: photoDate)
        let photoDay = calendar.component(.day, from: photoDate)

        for delta in -clampedWindow...clampedWindow {
            guard let target = calendar.date(byAdding: .day, value: delta, to: referenceDate) else { continue }
            if calendar.component(.month, from: target) == photoMonth
                && calendar.component(.day, from: target) == photoDay
            {
                return true
            }
        }
        return false
    }

    /// Selects unique photos, reserving up to `onThisDayCount` slots for anniversary photos.
    /// Reuses photos only when unique candidates are exhausted.
    public static func selectPhotos(
        from photos: [PhotoMetadata],
        onThisDayPhotos: [PhotoMetadata],
        photoCount: Int,
        onThisDayCount: Int
    ) -> [PhotoMetadata] {
        let safePhotoCount = max(0, photoCount)
        let safeOTDCount = max(0, onThisDayCount)
        var selected: [PhotoMetadata] = []
        if safeOTDCount > 0 && !onThisDayPhotos.isEmpty {
            let otdSampleCount = min(safeOTDCount, safePhotoCount, onThisDayPhotos.count)
            selected = Array(onThisDayPhotos.shuffled().prefix(otdSampleCount))
        }

        let selectedUUIDs = Set(selected.map(\.uuid))
        let regularPhotos = photos.filter { !selectedUUIDs.contains($0.uuid) }
        let regularNeeded = max(0, safePhotoCount - selected.count)

        if regularNeeded <= regularPhotos.count {
            selected.append(contentsOf: regularPhotos.shuffled().prefix(regularNeeded))
        } else {
            selected.append(contentsOf: regularPhotos)
            if !regularPhotos.isEmpty {
                let extraNeeded = regularNeeded - regularPhotos.count
                for _ in 0..<extraNeeded {
                    if let pick = regularPhotos.randomElement() {
                        selected.append(pick)
                    }
                }
            }
        }

        return selected
    }

    public static func buildGalleryName(
        template: String,
        randomize: Bool,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var name = template.replacingOccurrences(of: ":date:", with: formatter.string(from: date))
        if randomize {
            let stamp = String(date.timeIntervalSince1970)
            let digest = Insecure.SHA1.hash(data: Data(stamp.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(7)
            name += " - \(hex)"
        }
        return name
    }

    // MARK: - Full Sync Execution

    public func runSync(
        config: AppConfig,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        photoLibrary: any PhotoLibraryProviding = PhotoKitLibrary(),
        exporter: any PhotoExporting = PhotoKitExporter(),
        stateStore: any SyncStateStoring = FileSyncStateStore(),
        clientFactory: ClientFactory? = nil,
        onProgress: @escaping @Sendable (SyncProgress) -> Void = { _ in },
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard !isRunning else { throw SyncError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "MeuralSync photo sync"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let enabledInstances = config.instances.filter(\.enabled)
        let missing = enabledInstances
            .filter { resolveCredentialKey(for: $0, in: credentialStore) == nil }
            .map(\.name)
        if !missing.isEmpty {
            throw SyncError.missingCredentials(missing)
        }

        let makeClient: ClientFactory = clientFactory ?? { key, store, logHandler in
            MeuralClient(instanceName: key, credentialStore: store, logHandler: logHandler)
        }

        var failures: [(instanceName: String, error: Error)] = []
        for instance in enabledInstances {
            try Task.checkCancellation()
            let credentialKey = resolveCredentialKey(for: instance, in: credentialStore) ?? instance.storageKey
            do {
                try await processInstance(
                    instance,
                    credentialKey: credentialKey,
                    credentialStore: credentialStore,
                    photoLibrary: photoLibrary,
                    exporter: exporter,
                    stateStore: stateStore,
                    clientFactory: makeClient,
                    onProgress: onProgress,
                    onLog: onLog
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                let message = "[\(instance.name)] Sync failed: \(error.localizedDescription)"
                logger.error("\(message, privacy: .private)")
                onLog(message)
                failures.append((instance.name, error))
            }
        }

        if failures.count == 1 {
            throw failures[0].error
        } else if failures.count > 1 {
            throw SyncError.multipleInstanceFailures(
                failures.map { ($0.instanceName, $0.error.localizedDescription) }
            )
        }
    }

    private func resolveCredentialKey(
        for instance: InstanceConfig,
        in credentialStore: any CredentialStoring
    ) -> String? {
        if credentialStore.hasCredentials(for: instance.storageKey) {
            return instance.storageKey
        }
        if credentialStore.hasCredentials(for: instance.name) {
            return instance.name
        }
        return nil
    }

    private func processInstance(
        _ instance: InstanceConfig,
        credentialKey: String,
        credentialStore: any CredentialStoring,
        photoLibrary: any PhotoLibraryProviding,
        exporter: any PhotoExporting,
        stateStore: any SyncStateStoring,
        clientFactory: ClientFactory,
        onProgress: @escaping @Sendable (SyncProgress) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws {
        let instanceName = instance.name
        let stateKey = instance.storageKey
        let log: @Sendable (String) -> Void = { [logger] msg in
            logger.info("\(msg, privacy: .private)")
            onLog("[\(instanceName)] \(msg)")
        }

        log("Starting sync...")
        onProgress(SyncProgress(instanceName: instance.name, phase: "Querying Photos library..."))

        let queryOptions = PhotosQueryOptions(
            includePeople: instance.people.include,
            excludePeople: instance.people.exclude,
            curationScoreMin: instance.photoScoreCurationMin,
            excludeScreenshots: true,
            excludeMovies: true,
            excludeHidden: true
        )
        let allMatching = try await photoLibrary.queryPhotos(options: queryOptions)
        log("Found \(allMatching.count) matching photos")

        let otdCount = instance.resolvedOnThisDayCount
        let otdPhotos: [PhotoMetadata]
        if otdCount > 0 {
            otdPhotos = allMatching.filter {
                Self.isOnThisDay(photoDate: $0.date, windowDays: instance.onThisDayWindowDays)
            }
            log("Found \(otdPhotos.count) 'on this day' photos from previous years")
        } else {
            otdPhotos = []
        }

        let rawSelected = Self.selectPhotos(
            from: allMatching,
            onThisDayPhotos: otdPhotos,
            photoCount: instance.photoCount,
            onThisDayCount: otdCount
        )
        guard !rawSelected.isEmpty else {
            log("No matching photos found; aborting before modifying Meural galleries.")
            throw SyncError.noPhotosUploaded(instance.name)
        }
        log("Selected \(rawSelected.count) photos")

        onProgress(SyncProgress(instanceName: instance.name, phase: "Resolving photo locations..."))
        let selectedPhotos = await photoLibrary.enrichLocations(for: rawSelected)

        let client = clientFactory(credentialKey, credentialStore, { log($0) })

        onProgress(SyncProgress(instanceName: instance.name, phase: "Connecting to Meural..."))
        try await client.ensureAuthenticated()

        let resolvedOrientation: CanvasOrientation
        switch instance.frameOrientation {
        case .portrait:
            resolvedOrientation = .portrait
        case .landscape:
            resolvedOrientation = .landscape
        case .auto:
            let allDevices = try await client.getDevices()
            let targetDevices = instance.deviceId.map { id in allDevices.filter { $0.id == id } } ?? allDevices
            let detectedOrientations = targetDevices.compactMap(\.parsedOrientation)
            if let detected = detectedOrientations.first {
                resolvedOrientation = detected
                if Set(detectedOrientations).count > 1 {
                    log("Warning: multiple frames with mixed orientations detected; using \(detected.displayName) (\(detected.canvasWidth)×\(detected.canvasHeight)). Select a specific Target Frame or override Frame Orientation in Settings.")
                } else {
                    log("Detected Meural frame orientation: \(detected.displayName) (\(detected.canvasWidth)×\(detected.canvasHeight))")
                }
            } else {
                resolvedOrientation = .portrait
                log("Frame orientation not reported by Meural; defaulting to Portrait (1080×1920)")
            }
        }

        let galleryName = Self.buildGalleryName(
            template: instance.destinationAlbumName,
            randomize: instance.randomizeGalleryName
        )
        let gallery = try await client.getOrCreateGallery(
            name: galleryName,
            orientation: resolvedOrientation.meuralAPIOrientation
        )
        stateStore.recordGalleryID(gallery.id, for: stateKey)
        let existingItemIDs = gallery.itemIds
        log("Using gallery '\(gallery.name)' (id: \(gallery.id), orientation: \(resolvedOrientation.meuralAPIOrientation))")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeuralSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var pendingPaired: [(image: CGImage, uuid: String)] = []
        var consecutiveFailures = 0
        var uploadedItemIDs = Set<Int>()

        for (index, photo) in selectedPhotos.enumerated() {
            try Task.checkCancellation()
            onProgress(
                SyncProgress(
                    instanceName: instance.name,
                    phase: "Processing & uploading \(index + 1)/\(selectedPhotos.count)...",
                    completed: index,
                    total: selectedPhotos.count
                )
            )

            do {
                let exportedURL = try await exporter.exportPhoto(photo, toDirectory: tempDir)
                defer { try? FileManager.default.removeItem(at: exportedURL) }

                enum PreparedUpload {
                    case fullsizeFile(URL, String)
                    case pairedImage(CGImage, String, String)
                }

                let prepared: PreparedUpload = try autoreleasepool {
                    let loaded = try ImageProcessor.loadOrientedImage(from: exportedURL)
                    // Match photo orientation to frame orientation; squares always use fullsize.
                    let isFullsize = resolvedOrientation == .portrait
                        ? (loaded.height >= loaded.width)
                        : (loaded.width >= loaded.height)
                    if isFullsize {
                        let outURL = tempDir.appendingPathComponent("\(photo.uuid)-fullsize.jpg")
                        let layout = try ImageProcessor.processFullsizeImage(
                            loaded,
                            photo: photo,
                            includeList: instance.people.include,
                            locationAliases: instance.captionLocationAliases,
                            personAliases: instance.captionPersonAliases,
                            dateFormat: instance.captionDateFormat,
                            orientation: resolvedOrientation,
                            outputURL: outURL
                        )
                        return .fullsizeFile(outURL, layout.rows.map(\.text).joined(separator: " | "))
                    } else {
                        let (captioned, layout) = try ImageProcessor.processPairedImage(
                            loaded,
                            photo: photo,
                            includeList: instance.people.include,
                            locationAliases: instance.captionLocationAliases,
                            personAliases: instance.captionPersonAliases,
                            dateFormat: instance.captionDateFormat,
                            orientation: resolvedOrientation
                        )
                        return .pairedImage(captioned, photo.uuid, layout.rows.map(\.text).joined(separator: " | "))
                    }
                }

                switch prepared {
                case .fullsizeFile(let outURL, let captionSummary):
                    defer { try? FileManager.default.removeItem(at: outURL) }
                    log("Uploading \(resolvedOrientation.rawValue) \(photo.uuid): \(captionSummary)")
                    let itemID = try await client.createItem(fileURL: outURL)
                    stateStore.recordItemID(itemID, for: stateKey)
                    try await client.attachItem(galleryID: gallery.id, itemID: itemID)
                    uploadedItemIDs.insert(itemID)
                    consecutiveFailures = 0

                    if instance.uploadIntervalSeconds > 0 && index < selectedPhotos.count - 1 {
                        try await Task.sleep(nanoseconds: UInt64(instance.uploadIntervalSeconds * 1_000_000_000))
                    }

                case .pairedImage(let captioned, let uuid, let captionSummary):
                    let pairKind = resolvedOrientation == .portrait ? "landscape" : "portrait"
                    log("Prepared \(pairKind) \(uuid): \(captionSummary)")
                    pendingPaired.append((captioned, uuid))

                    if pendingPaired.count >= 2 {
                        let first = pendingPaired.removeLast()
                        let second = pendingPaired.removeLast()
                        let outURL = tempDir.appendingPathComponent("combined-\(first.uuid)-\(second.uuid).jpg")
                        defer { try? FileManager.default.removeItem(at: outURL) }

                        try autoreleasepool {
                            let combined = try ImageProcessor.combine(first.image, second.image, orientation: resolvedOrientation)
                            try ImageProcessor.saveJPEG(combined, to: outURL)
                        }
                        log("Uploading combined \(pairKind)s \(first.uuid) + \(second.uuid)")
                        let itemID = try await client.createItem(fileURL: outURL)
                        stateStore.recordItemID(itemID, for: stateKey)
                        try await client.attachItem(galleryID: gallery.id, itemID: itemID)
                        uploadedItemIDs.insert(itemID)
                        consecutiveFailures = 0

                        if instance.uploadIntervalSeconds > 0 && index < selectedPhotos.count - 1 {
                            try await Task.sleep(nanoseconds: UInt64(instance.uploadIntervalSeconds * 1_000_000_000))
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as MeuralAPIError {
                consecutiveFailures += 1
                log("Upload failed (\(consecutiveFailures)/\(instance.maxConsecutiveUploadFailures)): \(error.localizedDescription)")
                if consecutiveFailures >= instance.maxConsecutiveUploadFailures {
                    throw SyncError.tooManyUploadFailures(consecutiveFailures)
                }
            } catch let error as URLError {
                consecutiveFailures += 1
                log("Network upload failure (\(consecutiveFailures)/\(instance.maxConsecutiveUploadFailures)): \(error.localizedDescription)")
                if consecutiveFailures >= instance.maxConsecutiveUploadFailures {
                    throw SyncError.tooManyUploadFailures(consecutiveFailures)
                }
            } catch {
                log("Skipping photo \(photo.uuid): \(error.localizedDescription)")
            }
        }

        // Flush any single remaining odd paired photo centered on the frame canvas.
        if let leftover = pendingPaired.popLast() {
            try Task.checkCancellation()
            let outURL = tempDir.appendingPathComponent("\(leftover.uuid)-single.jpg")
            defer { try? FileManager.default.removeItem(at: outURL) }
            do {
                try autoreleasepool {
                    let filled = try ImageProcessor.fillFullsize(leftover.image, orientation: resolvedOrientation)
                    try ImageProcessor.saveJPEG(filled, to: outURL)
                }
                log("Uploading remaining photo \(leftover.uuid)")
                let itemID = try await client.createItem(fileURL: outURL)
                stateStore.recordItemID(itemID, for: stateKey)
                try await client.attachItem(galleryID: gallery.id, itemID: itemID)
                uploadedItemIDs.insert(itemID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                log("Skipping remaining photo \(leftover.uuid): \(error.localizedDescription)")
            }
        }

        // Guard against destructive cleanup / blanking frames when nothing uploaded.
        guard !uploadedItemIDs.isEmpty else {
            log("Zero photos uploaded; aborting before modifying existing galleries or frames.")
            throw SyncError.noPhotosUploaded(instance.name)
        }

        // Remove old photos from this gallery if it was reused
        if !existingItemIDs.isEmpty {
            onProgress(SyncProgress(instanceName: instance.name, phase: "Removing previous gallery items..."))
            for itemID in existingItemIDs {
                try Task.checkCancellation()
                do {
                    try await client.deleteGalleryItem(galleryID: gallery.id, itemID: itemID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as URLError where err.code == .cancelled {
                    throw CancellationError()
                } catch {
                    log("Warning: failed detaching previous item \(itemID) from gallery \(gallery.id): \(error.localizedDescription)")
                }
            }
        }

        // Push to devices if enabled
        var devicePushIncomplete = false
        if instance.sendToDevices {
            onProgress(SyncProgress(instanceName: instance.name, phase: "Sending gallery to Meural frames..."))
            var pushFailures: [String] = []
            do {
                let allDevices = try await client.getDevices()
                let devices = instance.deviceId.map { id in allDevices.filter { $0.id == id } } ?? allDevices
                if devices.isEmpty {
                    if let targetID = instance.deviceId {
                        pushFailures.append("Selected Meural frame (id: \(targetID)) not found on account")
                        log("Warning: selected Meural frame (id: \(targetID)) not found on account to push gallery \(gallery.id).")
                    } else {
                        pushFailures.append("No Meural frames found on account")
                        log("Warning: no Meural frames found on account to push gallery \(gallery.id).")
                    }
                }
                for device in devices {
                    try Task.checkCancellation()
                    let deviceLabel = device.alias?.isEmpty == false ? device.alias! : "Device \(device.id)"
                    let alreadyOnDevice = device.galleryIds?.contains(gallery.id) ?? false
                    var sendFailed = false
                    if !alreadyOnDevice {
                        log("Sending gallery \(gallery.id) to device \(device.id)")
                        do {
                            try await client.sendGalleryToDevice(deviceID: device.id, galleryID: gallery.id)
                            try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let err as URLError where err.code == .cancelled {
                            throw CancellationError()
                        } catch {
                            sendFailed = true
                            let detail = "\(deviceLabel): \(error.localizedDescription)"
                            pushFailures.append(detail)
                            log("Warning: failed sending gallery \(gallery.id) to \(deviceLabel): \(error.localizedDescription)")
                        }
                    }
                    if !sendFailed {
                        log("Switching device \(device.id) to gallery \(gallery.id)")
                        do {
                            try await client.switchDeviceToGallery(deviceID: device.id, galleryID: gallery.id)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let err as URLError where err.code == .cancelled {
                            throw CancellationError()
                        } catch {
                            let detail = "\(deviceLabel): \(error.localizedDescription)"
                            pushFailures.append(detail)
                            log("Warning: failed switching \(deviceLabel) to gallery \(gallery.id): \(error.localizedDescription)")
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as URLError where err.code == .cancelled {
                throw CancellationError()
            } catch {
                pushFailures.append(error.localizedDescription)
                log("Warning: failed loading devices to push gallery \(gallery.id): \(error.localizedDescription)")
            }

            if pushFailures.isEmpty {
                stateStore.setPendingDevicePush(nil, for: stateKey)
            } else {
                devicePushIncomplete = true
                stateStore.setPendingDevicePush(
                    PendingDevicePush(
                        galleryID: gallery.id,
                        galleryName: gallery.name,
                        errorMessage: pushFailures.joined(separator: "; ")
                    ),
                    for: stateKey
                )
            }
        } else {
            stateStore.setPendingDevicePush(nil, for: stateKey)
        }

        // Clean up old galleries created by this instance — skip if pushing to frames failed
        // so an offline or full frame never loses the fallback album it is still displaying.
        try Task.checkCancellation()
        if devicePushIncomplete {
            log("Skipping old-gallery cleanup because pushing to frame(s) did not complete; previous albums preserved until next successful handoff.")
        } else {
            onProgress(SyncProgress(instanceName: instance.name, phase: "Cleaning up old galleries..."))
            let trackedGalleries = stateStore.trackedGalleryIDs(for: stateKey)
            let oldGalleryIDs = try await client.deletePhotosInOldGalleries(
                currentGalleryID: gallery.id,
                destinationAlbumName: instance.destinationAlbumName,
                trackedGalleryIDs: trackedGalleries
            )
            for oldID in oldGalleryIDs {
                try Task.checkCancellation()
                log("Deleting old gallery \(oldID)")
                do {
                    try await client.deleteGallery(id: oldID)
                    stateStore.removeGalleryID(oldID, for: stateKey)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as URLError where err.code == .cancelled {
                    throw CancellationError()
                } catch let err as MeuralAPIError where err.statusCode == 404 {
                    stateStore.removeGalleryID(oldID, for: stateKey)
                } catch {
                    log("Warning: failed deleting old gallery \(oldID); keeping tracked for retry: \(error.localizedDescription)")
                }
            }
        }

        // Clean up orphan items that MeuralSync uploaded (never deletes user-owned items, items still in other galleries, or this run's uploads)
        try Task.checkCancellation()
        onProgress(SyncProgress(instanceName: instance.name, phase: "Cleaning up orphan photos..."))
        let trackedItems = stateStore.trackedItemIDs(for: stateKey)
        let orphanCleanup = try await client.deleteOrphanPhotos(
            trackedItemIDs: trackedItems,
            protectedItemIDs: uploadedItemIDs
        )
        stateStore.removeItemIDs(orphanCleanup.prunedItemIDs, for: stateKey)
        try Task.checkCancellation()
        log("Deleted \(orphanCleanup.deletedCount) orphan items. Sync complete!")

        onProgress(
            SyncProgress(
                instanceName: instance.name,
                phase: "Completed",
                completed: selectedPhotos.count,
                total: selectedPhotos.count
            )
        )
    }
}
