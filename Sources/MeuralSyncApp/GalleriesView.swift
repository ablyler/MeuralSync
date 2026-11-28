import AppKit
import MeuralSyncCore
import SwiftUI

private struct GalleriesLoadKey: Equatable {
    let instanceID: UUID?
    let refreshToken: Int
    let credentialsVersion: Int
}

private struct ItemsLoadKey: Equatable {
    let instanceID: UUID?
    let galleryID: Int?
    let refreshToken: Int
}

private struct PendingGalleryDelete: Identifiable {
    let instance: InstanceConfig
    let gallery: MeuralGallery
    var id: String { "\(instance.id.uuidString)-\(gallery.id)" }
}

private struct PendingItemDelete: Identifiable {
    let instance: InstanceConfig
    let galleryID: Int
    let item: MeuralItem
    var id: String { "\(instance.id.uuidString)-\(galleryID)-\(item.id)" }
}

private struct LightboxTarget: Identifiable {
    let instance: InstanceConfig
    let galleryID: Int
    let item: MeuralItem
    var id: String { "\(instance.id.uuidString)-\(galleryID)-\(item.id)" }
}

struct GalleriesView: View {
    @Bindable var appState: AppState

    @State private var selectedInstanceID: UUID?
    @State private var galleries: [MeuralGallery] = []
    @State private var accountGalleryIDs: Set<Int> = []
    @State private var deviceGalleryIDs: Set<Int> = []
    @State private var activeGalleryIDs: Set<Int> = []
    @State private var deviceLookupError: String?
    @State private var detectedOrientation: CanvasOrientation?
    @State private var showAllAccountAlbums = false
    @State private var trackedGalleryIDs: Set<Int> = []
    @State private var selectedGalleryID: Int?
    @State private var items: [MeuralItem] = []

    @State private var galleriesRefreshToken = 0
    @State private var itemsRefreshToken = 0
    @State private var galleriesLoadGeneration = 0
    @State private var itemsLoadGeneration = 0

    @State private var isLoadingGalleries = false
    @State private var isLoadingItems = false
    @State private var preserveErrorOnNextReload = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    @State private var galleryPendingDelete: PendingGalleryDelete?
    @State private var itemPendingDelete: PendingItemDelete?
    @State private var showingOrphanCleanupConfirmation = false
    @State private var previewTarget: LightboxTarget?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14),
    ]

    private var selectedInstance: InstanceConfig? {
        if let id = selectedInstanceID,
           let match = appState.config.instances.first(where: { $0.id == id })
        {
            return match
        }
        return appState.config.instances.first(where: { appState.hasCredentials(for: $0) })
            ?? appState.config.instances.first
    }

    private var displayedGalleries: [MeuralGallery] {
        if showAllAccountAlbums {
            return galleries
        }
        return galleries.filter { deviceGalleryIDs.contains($0.id) }
    }

    private var selectedGallery: MeuralGallery? {
        guard let selectedGalleryID else { return nil }
        return displayedGalleries.first(where: { $0.id == selectedGalleryID })
    }

    private var mutationsDisabled: Bool {
        appState.isMutatingGalleries || appState.isSyncing || appState.isRetryingDevicePush
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if appState.isSyncing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("A sync is currently in progress. Album and photo deletions are disabled until it finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.08))
                Divider()
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        self.errorMessage = nil
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.red.opacity(0.08))
                Divider()
            }

            if let statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        self.statusMessage = nil
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.green.opacity(0.08))
                Divider()
            }

            if selectedInstance == nil {
                ContentUnavailableView(
                    "No Accounts Configured",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Add a Meural instance in Settings to browse albums and photos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let instance = selectedInstance, !appState.hasCredentials(for: instance) {
                ContentUnavailableView(
                    "No Credentials Configured",
                    systemImage: "key.slash",
                    description: Text("Add Meural credentials for \"\(instance.name)\" in Settings to browse albums and photos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    galleriesSidebar
                        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

                    photosDetailPane
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(
            id: GalleriesLoadKey(
                instanceID: selectedInstance?.id,
                refreshToken: galleriesRefreshToken,
                credentialsVersion: appState.credentialsVersion
            )
        ) {
            await loadGalleries()
        }
        .task(id: ItemsLoadKey(instanceID: selectedInstance?.id, galleryID: selectedGalleryID, refreshToken: itemsRefreshToken)) {
            await loadItems()
        }
        .confirmationDialog(
            "Delete album \"\(galleryPendingDelete?.gallery.name ?? "")\"?",
            isPresented: Binding(
                get: { galleryPendingDelete != nil },
                set: { if !$0 { galleryPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Album & All Photos", role: .destructive) {
                if let pending = galleryPendingDelete {
                    galleryPendingDelete = nil
                    Task { await deleteGallery(pending, deleteAllItems: true) }
                }
            }
            .disabled(mutationsDisabled)
            Button("Delete Album (Keep Shared Photos)", role: .destructive) {
                if let pending = galleryPendingDelete {
                    galleryPendingDelete = nil
                    Task { await deleteGallery(pending, deleteAllItems: false) }
                }
            }
            .disabled(mutationsDisabled)
            Button("Cancel", role: .cancel) {
                galleryPendingDelete = nil
            }
        } message: {
            Text("\"Delete Album & All Photos\" permanently deletes this gallery and every photo in it from your Meural account. \"Keep Shared Photos\" only removes photos not used by other albums.")
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: Binding(
                get: { itemPendingDelete != nil },
                set: { if !$0 { itemPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Photo", role: .destructive) {
                if let pending = itemPendingDelete {
                    itemPendingDelete = nil
                    Task { await deleteItem(pending) }
                }
            }
            .disabled(mutationsDisabled)
            Button("Cancel", role: .cancel) {
                itemPendingDelete = nil
            }
        } message: {
            Text("This removes the photo from this album and deletes it from Meural if it is not in any other album.")
        }
        .confirmationDialog(
            "Delete unassigned photos on \"\(selectedInstance?.name ?? "")\"?",
            isPresented: $showingOrphanCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Unassigned Photos", role: .destructive) {
                if let instance = selectedInstance {
                    Task { await cleanupUnassignedPhotos(for: instance) }
                }
            }
            .disabled(mutationsDisabled)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all photos on this Meural account that do not belong to any album.")
        }
        .sheet(item: $previewTarget) { target in
            PhotoLightboxView(
                item: target.item,
                mutationsDisabled: mutationsDisabled
            ) {
                previewTarget = nil
                Task { await deleteItem(PendingItemDelete(instance: target.instance, galleryID: target.galleryID, item: target.item)) }
            }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack(spacing: 10) {
            if appState.config.instances.count > 1 {
                Picker(
                    "Account",
                    selection: Binding(
                        get: { selectedInstance?.id },
                        set: { selectedInstanceID = $0 }
                    )
                ) {
                    ForEach(appState.config.instances) { inst in
                        Text(inst.name).tag(Optional(inst.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .disabled(appState.isMutatingGalleries)
            } else if let inst = selectedInstance {
                Text(inst.name)
                    .font(.headline)
            }

            Picker("Filter", selection: $showAllAccountAlbums) {
                Text("On Frame").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 150)
            .help("Show only albums loaded on your Meural frame, or all albums on the account")
            .onChange(of: showAllAccountAlbums) { _, _ in
                if let current = selectedGalleryID,
                   !displayedGalleries.contains(where: { $0.id == current })
                {
                    selectedGalleryID = displayedGalleries.first?.id
                } else if selectedGalleryID == nil {
                    selectedGalleryID = displayedGalleries.first?.id
                }
            }

            if let orientation = detectedOrientation {
                Label(
                    orientation.displayName,
                    systemImage: orientation == .landscape ? "rectangle" : "rectangle.portrait"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
                .help("Detected Meural frame orientation")
            }

            Spacer()

            if isLoadingGalleries || isLoadingItems || appState.isMutatingGalleries {
                ProgressView()
                    .controlSize(.small)
            }

            if let instance = selectedInstance, let gallery = selectedGallery {
                Button {
                    Task { await sendGalleryToDevice(instance: instance, gallery: gallery) }
                } label: {
                    Label("Send to Frame", systemImage: "tv.and.mediabox")
                }
                .disabled(mutationsDisabled)
                .help("Push and switch Meural frame(s) to this album")

                Button(role: .destructive) {
                    galleryPendingDelete = PendingGalleryDelete(instance: instance, gallery: gallery)
                } label: {
                    Label("Delete Album", systemImage: "trash")
                }
                .disabled(mutationsDisabled || !accountGalleryIDs.contains(gallery.id))
                .help(accountGalleryIDs.contains(gallery.id) ? "Delete this album" : "Only account-owned albums can be deleted")
            }

            if let instance = selectedInstance, appState.hasCredentials(for: instance) {
                Button {
                    showingOrphanCleanupConfirmation = true
                } label: {
                    Label("Clean Up Unused", systemImage: "trash.slash")
                }
                .disabled(mutationsDisabled)
                .help("Delete all photos on this Meural account that do not belong to any album")
            }

            Button {
                galleriesRefreshToken += 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingGalleries || isLoadingItems || appState.isMutatingGalleries)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var galleriesSidebar: some View {
        let templateRegex = selectedInstance.flatMap { MeuralClient.galleryTemplateRegex(for: $0.destinationAlbumName) }
        return Group {
            if isLoadingGalleries && galleries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading albums…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedGalleries.isEmpty {
                if !showAllAccountAlbums, let deviceLookupError {
                    ContentUnavailableView {
                        Label("Could Not Check Frame", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(deviceLookupError)
                    } actions: {
                        Button("Show All Account Albums") {
                            showAllAccountAlbums = true
                        }
                    }
                } else if !showAllAccountAlbums && !galleries.isEmpty {
                    ContentUnavailableView {
                        Label("No Albums on Frame", systemImage: "tv")
                    } description: {
                        Text("None of this account's \(galleries.count) album(s) are currently loaded on the Meural frame.")
                    } actions: {
                        Button("Show All Account Albums") {
                            showAllAccountAlbums = true
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "photo.stack",
                        description: Text("No albums were found on this Meural account.")
                    )
                }
            } else {
                List(displayedGalleries, selection: $selectedGalleryID) { gallery in
                    let managed = trackedGalleryIDs.contains(gallery.id) || {
                        guard let regex = templateRegex else { return false }
                        let range = NSRange(gallery.name.startIndex..<gallery.name.endIndex, in: gallery.name)
                        return regex.firstMatch(in: gallery.name, range: range) != nil
                    }()
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gallery.name)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text("\(gallery.itemIds.count) \(gallery.itemIds.count == 1 ? "photo" : "photos")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if activeGalleryIDs.contains(gallery.id) {
                                    Text("Showing")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                                if managed {
                                    Text("MeuralSync")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        Spacer()
                    }
                    .tag(gallery.id)
                    .contextMenu {
                        if let instance = selectedInstance {
                            Button("Send to Frame") {
                                Task { await sendGalleryToDevice(instance: instance, gallery: gallery) }
                            }
                            .disabled(mutationsDisabled)
                            Divider()
                            Button("Delete Album…", role: .destructive) {
                                galleryPendingDelete = PendingGalleryDelete(instance: instance, gallery: gallery)
                            }
                            .disabled(mutationsDisabled || !accountGalleryIDs.contains(gallery.id))
                        }
                    }
                }
            }
        }
    }

    private var photosDetailPane: some View {
        Group {
            if selectedGallery == nil {
                ContentUnavailableView(
                    "Select an Album",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Choose an album from the sidebar to inspect or delete its photos.")
                )
            } else if isLoadingItems && items.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading photos…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty Album",
                    systemImage: "photo",
                    description: Text("This Meural album currently has no photos.")
                )
            } else if let instance = selectedInstance, let galleryID = selectedGalleryID {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        let canDeleteItems = accountGalleryIDs.contains(galleryID)
                        ForEach(items) { item in
                            PhotoGridCard(
                                item: item,
                                aspectRatio: detectedOrientation == .landscape ? (16.0 / 9.0) : (9.0 / 16.0),
                                mutationsDisabled: mutationsDisabled || !canDeleteItems,
                                onPreview: {
                                    previewTarget = LightboxTarget(instance: instance, galleryID: galleryID, item: item)
                                },
                                onDelete: {
                                    itemPendingDelete = PendingItemDelete(instance: instance, galleryID: galleryID, item: item)
                                }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadGalleries() async {
        galleriesLoadGeneration += 1
        let generation = galleriesLoadGeneration

        let previousGalleryID = selectedGalleryID
        galleries = []
        accountGalleryIDs = []
        deviceGalleryIDs = []
        activeGalleryIDs = []
        deviceLookupError = nil
        detectedOrientation = nil
        items = []
        trackedGalleryIDs = []
        selectedGalleryID = nil
        if preserveErrorOnNextReload {
            preserveErrorOnNextReload = false
        } else {
            errorMessage = nil
        }

        guard let instance = selectedInstance, appState.hasCredentials(for: instance) else {
            isLoadingGalleries = false
            return
        }

        isLoadingGalleries = true
        let instanceID = instance.id
        trackedGalleryIDs = appState.trackedGalleryIDs(for: instance)

        do {
            let client = appState.makeMeuralClient(for: instance)
            let fetched = try await client.getGalleries()
            let devices: [MeuralDevice]
            var lookupFailure: String?
            do {
                devices = try await client.getDevices()
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as URLError where err.code == .cancelled {
                throw CancellationError()
            } catch {
                devices = []
                lookupFailure = "Failed to load frame info: \(error.localizedDescription)"
            }

            var matchedIDs = Set<Int>()
            var activeIDs = Set<Int>()
            var extraGalleriesByID: [Int: MeuralGallery] = [:]
            for device in devices {
                if let ids = device.galleryIds {
                    matchedIDs.formUnion(ids)
                }
                if let activeID = device.activeGalleryId {
                    activeIDs.insert(activeID)
                    matchedIDs.insert(activeID)
                }
                do {
                    let deviceGalleries = try await client.getDeviceGalleries(deviceID: device.id)
                    for g in deviceGalleries {
                        matchedIDs.insert(g.id)
                        if g.isActiveOnDevice == true {
                            activeIDs.insert(g.id)
                        }
                        extraGalleriesByID[g.id] = g
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as URLError where err.code == .cancelled {
                    throw CancellationError()
                } catch {
                    if matchedIDs.isEmpty && lookupFailure == nil {
                        lookupFailure = "Failed to load frame albums: \(error.localizedDescription)"
                    }
                }
            }

            guard !Task.isCancelled, generation == galleriesLoadGeneration, selectedInstance?.id == instanceID else {
                return
            }

            var mergedByID: [Int: MeuralGallery] = extraGalleriesByID
            for g in fetched {
                mergedByID[g.id] = g
            }
            accountGalleryIDs = Set(fetched.map(\.id))
            galleries = mergedByID.values.sorted { lhs, rhs in
                let lhsActive = activeIDs.contains(lhs.id)
                let rhsActive = activeIDs.contains(rhs.id)
                if lhsActive != rhsActive { return lhsActive }
                return lhs.id > rhs.id
            }
            deviceGalleryIDs = matchedIDs
            activeGalleryIDs = activeIDs
            deviceLookupError = lookupFailure
            detectedOrientation = devices.compactMap(\.parsedOrientation).first
            if let prev = previousGalleryID, displayedGalleries.contains(where: { $0.id == prev }) {
                selectedGalleryID = prev
            } else {
                selectedGalleryID = displayedGalleries.first?.id
            }
        } catch is CancellationError {
            // Cancelled due to instance switch or refresh.
        } catch let err as URLError where err.code == .cancelled {
            // Cancelled due to instance switch or refresh.
        } catch {
            if generation == galleriesLoadGeneration {
                errorMessage = error.localizedDescription
            }
        }

        if generation == galleriesLoadGeneration {
            isLoadingGalleries = false
        }
    }

    private func loadItems() async {
        itemsLoadGeneration += 1
        let generation = itemsLoadGeneration
        items = []

        guard let instance = selectedInstance,
              appState.hasCredentials(for: instance),
              let galleryID = selectedGalleryID
        else {
            isLoadingItems = false
            return
        }

        isLoadingItems = true
        let instanceID = instance.id

        do {
            let client = appState.makeMeuralClient(for: instance)
            let fetched = try await client.getGalleryItems(galleryID: galleryID)
            guard !Task.isCancelled,
                  generation == itemsLoadGeneration,
                  selectedInstance?.id == instanceID,
                  selectedGalleryID == galleryID
            else {
                return
            }
            items = fetched
        } catch is CancellationError {
            // Cancelled due to gallery switch or refresh.
        } catch let err as URLError where err.code == .cancelled {
            // Cancelled due to gallery switch or refresh.
        } catch {
            if generation == itemsLoadGeneration {
                errorMessage = error.localizedDescription
            }
        }

        if generation == itemsLoadGeneration {
            isLoadingItems = false
        }
    }

    private func sendGalleryToDevice(instance: InstanceConfig, gallery: MeuralGallery) async {
        guard !mutationsDisabled else { return }
        appState.isMutatingGalleries = true
        errorMessage = nil
        statusMessage = nil
        defer { appState.isMutatingGalleries = false }

        do {
            let client = appState.makeMeuralClient(for: instance)
            let count = try await client.pushGalleryToDevices(galleryID: gallery.id)
            if count == 0 {
                errorMessage = "No Meural frames found on '\(instance.name)'."
            } else {
                let label = count == 1 ? "1 Meural frame" : "\(count) Meural frames"
                statusMessage = "Sent '\(gallery.name)' to \(label)."
                deviceGalleryIDs.insert(gallery.id)
                activeGalleryIDs = [gallery.id]
                appState.clearPendingDevicePush(for: instance)
                appState.appendLog("Manually sent album '\(gallery.name)' (id: \(gallery.id)) to \(label).")
            }
        } catch {
            errorMessage = "Failed to send album to frame: \(error.localizedDescription)"
            appState.recordFailedDevicePush(
                galleryID: gallery.id,
                galleryName: gallery.name,
                errorMessage: error.localizedDescription,
                for: instance
            )
        }
    }

    private func deleteGallery(_ pending: PendingGalleryDelete, deleteAllItems: Bool) async {
        guard !mutationsDisabled else { return }
        appState.isMutatingGalleries = true
        errorMessage = nil
        statusMessage = nil
        defer { appState.isMutatingGalleries = false }

        do {
            let client = appState.makeMeuralClient(for: pending.instance)
            let result = try await client.deleteGalleryAndOrphanItems(
                galleryID: pending.gallery.id,
                deleteAllItems: deleteAllItems
            )
            if result.galleryDeleted {
                appState.recordManualGalleryDeletion(
                    pending.gallery.id,
                    deletedItemIDs: result.deletedItemIDs,
                    for: pending.instance
                )
                let count = result.deletedItemIDs.count
                let photoLabel = count == 1 ? "1 photo" : "\(count) photos"
                appState.appendLog("Manually deleted album '\(pending.gallery.name)' (id: \(pending.gallery.id)) and \(photoLabel).")
                if selectedInstance?.id == pending.instance.id {
                    trackedGalleryIDs.remove(pending.gallery.id)
                    accountGalleryIDs.remove(pending.gallery.id)
                    deviceGalleryIDs.remove(pending.gallery.id)
                    activeGalleryIDs.remove(pending.gallery.id)
                    galleries.removeAll { $0.id == pending.gallery.id }
                    if selectedGalleryID == pending.gallery.id {
                        selectedGalleryID = displayedGalleries.first?.id
                    }
                }
                if result.skippedOrphanCleanup {
                    errorMessage = "Album deleted (\(photoLabel) removed), but some remaining photos could not be verified or deleted."
                } else {
                    statusMessage = "Deleted '\(pending.gallery.name)' and \(photoLabel)."
                }
            }
        } catch {
            errorMessage = "Failed to delete album: \(error.localizedDescription)"
            preserveErrorOnNextReload = true
            galleriesRefreshToken += 1
        }
    }

    private func cleanupUnassignedPhotos(for instance: InstanceConfig) async {
        guard !mutationsDisabled else { return }
        appState.isMutatingGalleries = true
        errorMessage = nil
        statusMessage = nil
        defer { appState.isMutatingGalleries = false }

        do {
            let client = appState.makeMeuralClient(for: instance)
            let result = try await client.deleteOrphanPhotos(
                trackedItemIDs: nil,
                protectedItemIDs: [],
                allowEmptyGalleries: true
            )
            if !result.prunedItemIDs.isEmpty {
                appState.recordManualItemsDeletion(result.prunedItemIDs, for: instance)
            }
            if result.deletedCount == 0 {
                statusMessage = "No unassigned photos found on '\(instance.name)'."
                appState.appendLog("Unassigned photo cleanup for \(instance.name): 0 photos found.")
            } else {
                let label = result.deletedCount == 1 ? "1 unassigned photo" : "\(result.deletedCount) unassigned photos"
                statusMessage = "Deleted \(label) from '\(instance.name)'."
                appState.appendLog("Manually deleted \(label) from \(instance.name).")
            }
        } catch {
            errorMessage = "Failed to clean up unassigned photos: \(error.localizedDescription)"
        }
    }

    private func deleteItem(_ pending: PendingItemDelete) async {
        guard !mutationsDisabled else { return }
        appState.isMutatingGalleries = true
        errorMessage = nil
        defer { appState.isMutatingGalleries = false }

        do {
            let client = appState.makeMeuralClient(for: pending.instance)
            let result = try await client.removeItemFromGalleryAndDeleteIfOrphan(
                galleryID: pending.galleryID,
                itemID: pending.item.id
            )
            if result.deletedAccountItem {
                appState.recordManualItemDeletion(pending.item.id, for: pending.instance)
                appState.appendLog("Manually deleted photo \(pending.item.id) from gallery \(pending.galleryID).")
            } else {
                appState.appendLog("Detached photo \(pending.item.id) from gallery \(pending.galleryID) (kept on account).")
                if result.skippedOrphanCheck {
                    errorMessage = "Photo removed from album, but account-level orphan deletion was skipped."
                }
            }
            if selectedInstance?.id == pending.instance.id {
                if selectedGalleryID == pending.galleryID {
                    items.removeAll { $0.id == pending.item.id }
                }
                if let idx = galleries.firstIndex(where: { $0.id == pending.galleryID }) {
                    let updatedIDs = galleries[idx].itemIds.filter { $0 != pending.item.id }
                    galleries[idx] = MeuralGallery(
                        id: galleries[idx].id,
                        name: galleries[idx].name,
                        itemIds: updatedIDs
                    )
                }
            }
        } catch {
            errorMessage = "Failed to delete photo: \(error.localizedDescription)"
            itemsRefreshToken += 1
        }
    }
}

private struct PhotoGridCard: View {
    let item: MeuralItem
    let aspectRatio: CGFloat
    let mutationsDisabled: Bool
    let onPreview: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay {
                        if let url = item.thumbnailURL ?? item.imageURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView().controlSize(.small)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                case .failure:
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPreview)

                if isHovering && !mutationsDisabled {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Delete photo")
                }
            }

            HStack {
                Text(item.name ?? "Item #\(item.id)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Inspect Photo", action: onPreview)
            Divider()
            Button("Delete Photo…", role: .destructive, action: onDelete)
                .disabled(mutationsDisabled)
        }
    }
}

private struct PhotoLightboxView: View {
    let item: MeuralItem
    let mutationsDisabled: Bool
    let onConfirmDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.name ?? "Photo #\(item.id)")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Photo", systemImage: "trash")
                }
                .disabled(mutationsDisabled)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)
                if let url = item.imageURL ?? item.thumbnailURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        case .failure:
                            ContentUnavailableView("Unable to Load Image", systemImage: "photo")
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .padding(8)
                } else {
                    ContentUnavailableView("No Image URL Available", systemImage: "photo")
                }
            }
            .frame(minWidth: 420, minHeight: 540)
        }
        .padding(16)
        .confirmationDialog(
            "Delete this photo?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Photo", role: .destructive) {
                onConfirmDelete()
            }
            .disabled(mutationsDisabled)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the photo from this album and deletes it from Meural if it is not in any other album.")
        }
    }
}
