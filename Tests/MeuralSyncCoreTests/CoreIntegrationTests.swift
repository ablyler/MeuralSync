import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import MeuralSyncCore

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    var creds: [String: MeuralCredentials] = [:]
    var tokens: [String: String] = [:]

    func getCredentials(for instanceName: String) throws -> MeuralCredentials {
        guard let c = creds[instanceName] else {
            throw CredentialError.missingCredentials(instanceName: instanceName)
        }
        return c
    }

    func setCredentials(_ credentials: MeuralCredentials, for instanceName: String) throws {
        creds[instanceName] = credentials
    }

    func hasCredentials(for instanceName: String) -> Bool {
        creds[instanceName] != nil
    }

    func deleteCredentials(for instanceName: String) throws {
        creds.removeValue(forKey: instanceName)
        tokens.removeValue(forKey: instanceName)
    }

    func getCachedToken(for instanceName: String) -> String? {
        tokens[instanceName]
    }

    func setCachedToken(_ token: String, for instanceName: String) throws {
        tokens[instanceName] = token
    }

    func clearCachedToken(for instanceName: String) {
        tokens.removeValue(forKey: instanceName)
    }
}

private final class MockTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) throws -> (Data, Int)
    var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) throws -> (Data, Int)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status) = try handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.meural.com/v1")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

@Suite("MeuralClient & SyncEngine & PhotosDatabase")
struct CoreIntegrationTests {
    @Test("MeuralClient authenticates via Cognito, handles 401 refresh, and retries transient upload errors")
    func meuralAuthAndRetries() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "secret"), for: "frame")
        try store.setCachedToken("stale-token", for: "frame")

        var authCount = 0
        var uploadAttempts = 0
        actor DelayRecorder {
            var delays: [TimeInterval] = []
            func record(_ delay: TimeInterval) { delays.append(delay) }
        }
        let recorder = DelayRecorder()

        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if url.contains("cognito-idp") {
                authCount += 1
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok-\#(authCount)"}}"#.utf8), 200)
            }
            // Validate stale token passes initially, then expires on /v1/items -> triggers real 401 refresh!
            if url.hasSuffix("/v1/user/devices") && auth == "Token stale-token" {
                return (Data(#"{"data":[]}"#.utf8), 200)
            }
            if url.hasSuffix("/v1/items") {
                if auth == "Token stale-token" {
                    return (Data("unauthorized".utf8), 401)
                }
                uploadAttempts += 1
                if uploadAttempts < 3 {
                    return (Data("server error".utf8), 503)
                }
                return (Data(#"{"data":{"id":999}}"#.utf8), 201)
            }
            if url.hasSuffix("/v1/galleries/42/items/999") {
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(
            instanceName: "frame",
            credentialStore: store,
            transport: transport,
            sleepHandler: { delay in
                await recorder.record(delay)
            },
            randomUnit: { 0.5 }
        )

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("meural-test-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let itemID = try await client.uploadItem(galleryID: 42, fileURL: tmp)
        #expect(itemID == 999)
        #expect(authCount == 1)
        #expect(uploadAttempts == 3)
        // Upload retry: baseDelay=5, maxJitter=10, randomUnit=0.5 -> attempt 1: 5+5=10, attempt 2: 10+5=15
        let sleepDelays = await recorder.delays
        #expect(sleepDelays == [10, 15])
        #expect(store.getCachedToken(for: "frame") == "tok-1")
    }

    @Test("Gallery cleanup refuses unsafe templates, uses tracked IDs, and protects user-owned items")
    func galleryAndOrphanCleanupSafety() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "secret"), for: "frame")
        try store.setCachedToken("valid-tok", for: "frame")

        var deletedItemIDs: [Int] = []
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "DELETE", url.contains("/v1/items/"),
               let idStr = url.split(separator: "/").last, let id = Int(idStr)
            {
                deletedItemIDs.append(id)
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if url.contains("/v1/user/galleries") {
                let json = """
                {"data":[
                    {"id":1,"name":"Family Photos - 2026-11-26 - a1b2c3d","itemIds":[10]},
                    {"id":2,"name":"Family Photos - 2026-11-27 - f00ba12","itemIds":[20]},
                    {"id":3,"name":"Family Vacation 2019","itemIds":[30]},
                    {"id":4,"name":"Custom Tracked Gallery","itemIds":[40]},
                    {"id":5,"name":"2026-11-25 - Family","itemIds":[50]}
                ]}
                """
                return (Data(json.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(
            instanceName: "frame",
            credentialStore: store,
            transport: transport,
            sleepHandler: { _ in }
        )

        // Empty or :date:-only template must NOT match unrelated galleries
        let emptyMatches = try await client.listOldGalleries(currentGalleryID: 2, destinationAlbumName: "")
        #expect(emptyMatches.isEmpty)
        let dateOnlyMatches = try await client.listOldGalleries(currentGalleryID: 2, destinationAlbumName: ":date:")
        #expect(dateOnlyMatches.isEmpty)

        // Valid template + tracked IDs matches only old template galleries & tracked IDs, never "Family Vacation 2019"
        let matched = try await client.listOldGalleries(
            currentGalleryID: 2,
            destinationAlbumName: "Family Photos - :date:",
            trackedGalleryIDs: [2, 4]
        )
        #expect(Set(matched) == Set([1, 4]))

        // Leading :date: template works too
        let leadingDateMatched = try await client.listOldGalleries(
            currentGalleryID: 2,
            destinationAlbumName: ":date: - Family"
        )
        #expect(leadingDateMatched == [5])

        // Orphan cleanup with trackedItemIDs only deletes tracked orphans (99), never user-owned items,
        // active items (20), or protected freshly-uploaded items (101)
        let orphanResult = try await client.deleteOrphanPhotos(
            trackedItemIDs: [20, 99, 101],
            protectedItemIDs: [101]
        )
        #expect(orphanResult.deletedCount == 1)
        #expect(orphanResult.prunedItemIDs == [99])
        #expect(deletedItemIDs == [99])
    }

    @Test("SyncEngine end-to-end runSync uploads, flushes odd landscape, protects new uploads, and prunes tracked state")
    func syncEngineEndToEndAndStatePruning() async throws {
        struct SyntheticLibrary: PhotoLibraryProviding {
            let photos: [PhotoMetadata]
            func fetchAllPersonNames() async throws -> [String] { ["Alice"] }
            func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] { photos }
            func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] {
                photos.map { $0.withLocation(placeName: "Orlando, FL", areasOfInterest: []) }
            }
        }
        struct SyntheticExporter: PhotoExporting {
            func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(
                    data: nil,
                    width: photo.width,
                    height: photo.height,
                    bitsPerComponent: 8,
                    bytesPerRow: photo.width * 4,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
                let image = ctx.makeImage()!
                let outURL = directory.appendingPathComponent("\(photo.uuid).jpg")
                try ImageProcessor.saveJPEG(image, to: outURL)
                return outURL
            }
        }

        let store = InMemoryCredentialStore()
        let instance = InstanceConfig(
            name: "Living Room",
            enabled: true,
            sendToDevices: false,
            photoCount: 2,
            destinationAlbumName: "Family Photos - :date:",
            randomizeGalleryName: false,
            uploadIntervalSeconds: 0
        )
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: instance.storageKey)

        let stateStore = InMemorySyncStateStore()
        // Pre-seed an old gallery (id 10) with items 100 & 103 (where 103 is also in user gallery 30),
        // plus a stale orphan item 101 and a 404-already-gone item 102
        stateStore.recordGalleryID(10, for: instance.storageKey)
        stateStore.recordItemID(100, for: instance.storageKey)
        stateStore.recordItemID(101, for: instance.storageKey)
        stateStore.recordItemID(102, for: instance.storageKey)
        stateStore.recordItemID(103, for: instance.storageKey)

        var nextItemID = 200
        var deletedItems: [Int] = []
        var deletedGalleries: [Int] = []
        var gallery10Deleted = false
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/v1/user/galleries") {
                // Intentionally return stale itemIds for gallery 20 (missing 200/201) to prove protectedItemIDs protects them,
                // and include user gallery 30 referencing shared item 103 to prove shared items are never deleted account-wide!
                var galleriesJSON: [String] = []
                if !gallery10Deleted {
                    galleriesJSON.append(#"{"id":10,"name":"Family Photos - 2026-11-01","itemIds":[100,103]}"#)
                }
                galleriesJSON.append(#"{"id":20,"name":"Family Photos - 2026-11-27","itemIds":[]}"#)
                galleriesJSON.append(#"{"id":30,"name":"My Favorites","itemIds":[103]}"#)
                let json = "{\"data\":[\(galleriesJSON.joined(separator: ","))]}"
                return (Data(json.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/v1/galleries") {
                return (Data(#"{"data":{"id":20,"name":"Family Photos - 2026-11-27","itemIds":[]}}"#.utf8), 201)
            }
            if method == "GET" && url.hasSuffix("/v1/galleries/10") {
                return (Data(#"{"data":{"id":10,"name":"Family Photos - 2026-11-01","itemIds":[100,103]}}"#.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/v1/items") {
                let assigned = nextItemID
                nextItemID += 1
                return (Data(#"{"data":{"id":\#(assigned)}}"#.utf8), 201)
            }
            if method == "POST" && url.contains("/items/") {
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/v1/galleries/10/items/") {
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "DELETE" && url.hasSuffix("/v1/galleries/10") {
                gallery10Deleted = true
                deletedGalleries.append(10)
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/v1/items/"),
               let idStr = url.split(separator: "/").last, let id = Int(idStr)
            {
                if id == 102 {
                    return (Data("not found".utf8), 404)
                }
                deletedItems.append(id)
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let photos = [
            PhotoMetadata(uuid: "portrait-1", date: Date(), width: 300, height: 400, persons: ["Alice"]),
            PhotoMetadata(uuid: "landscape-1", date: Date(), width: 400, height: 300, persons: ["Alice"]),
        ]

        let engine = SyncEngine()
        try await engine.runSync(
            config: AppConfig(instances: [instance]),
            credentialStore: store,
            photoLibrary: SyntheticLibrary(photos: photos),
            exporter: SyntheticExporter(),
            stateStore: stateStore,
            clientFactory: { key, credStore, logHandler in
                MeuralClient(instanceName: key, credentialStore: credStore, transport: transport, sleepHandler: { _ in }, logHandler: logHandler)
            }
        )

        // Both portrait-1 (200) and odd landscape-1 (201) were uploaded
        #expect(nextItemID == 202)
        // Old gallery 10 deleted and pruned from stateStore
        #expect(deletedGalleries == [10])
        #expect(stateStore.trackedGalleryIDs(for: instance.storageKey) == [20])
        // Old gallery item 100 and orphan 101 deleted; 404 item 102 pruned; shared item 103 & fresh uploads 200/201 preserved!
        #expect(Set(deletedItems) == Set([100, 101]))
        #expect(stateStore.trackedItemIDs(for: instance.storageKey) == Set([103, 200, 201]))
    }

    @Test("Manual gallery and item browsing & deletion protect shared items and guard empty itemIds")
    func manualGalleryAndItemManagement() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "frame")
        try store.setCachedToken("tok", for: "frame")

        var deletedItemIDs: [Int] = []
        var detachedPairs: [(Int, Int)] = []
        var deletedGalleryIDs: [Int] = []
        var omitItemIDsInGalleryList = false

        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if method == "GET" && url.contains("/v1/galleries/10/items") {
                if url.contains("page=1") {
                    let json = """
                    {"data":[
                        {"id":500,"name":"","title":"Sunset","image":"","originalImage":"https://example.com/500.jpg","thumbnail":"https://example.com/500-thumb.jpg"}
                    ]}
                    """
                    return (Data(json.utf8), 200)
                } else if url.contains("page=2") {
                    let json = """
                    {"data":[
                        {"id":501,"name":"Shared Photo","image":"https://example.com/501.jpg"}
                    ]}
                    """
                    return (Data(json.utf8), 200)
                }
                return (Data(#"{"data":[]}"#.utf8), 200)
            }
            if method == "GET" && url.hasSuffix("/v1/galleries/10") {
                return (Data(#"{"data":{"id":10,"name":"Album A","itemIds":[500,501]}}"#.utf8), 200)
            }
            if method == "GET" && url.hasSuffix("/v1/galleries/99") {
                return (Data("not found".utf8), 404)
            }
            if method == "GET" && url.contains("/v1/user/galleries") {
                let json = omitItemIDsInGalleryList
                    ? #"{"data":[{"id":20,"name":"Favorites"}]}"#
                    : #"{"data":[{"id":20,"name":"Favorites","itemIds":[501]}]}"#
                return (Data(json.utf8), 200)
            }
            if method == "DELETE" && url.contains("/v1/galleries/10/items/"),
               let idStr = url.split(separator: "/").last, let id = Int(idStr)
            {
                detachedPairs.append((10, id))
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "DELETE" && url.hasSuffix("/v1/galleries/10") {
                deletedGalleryIDs.append(10)
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/v1/items/"),
               let idStr = url.split(separator: "/").last, let id = Int(idStr)
            {
                deletedItemIDs.append(id)
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(instanceName: "frame", credentialStore: store, transport: transport, sleepHandler: { _ in })

        // Multi-page getGalleryItems + empty-string fallback decoding
        let items = try await client.getGalleryItems(galleryID: 10)
        #expect(items.count == 2)
        #expect(items[0].name == "Sunset")
        #expect(items[0].imageURL?.absoluteString == "https://example.com/500.jpg")
        #expect(items[0].thumbnailURL?.absoluteString == "https://example.com/500-thumb.jpg")
        #expect(items[1].thumbnailURL?.absoluteString == "https://example.com/501.jpg")

        // Single-item remove: shared item 501 is detached but NOT deleted account-wide
        let sharedRes = try await client.removeItemFromGalleryAndDeleteIfOrphan(galleryID: 10, itemID: 501)
        #expect(sharedRes == ManualItemDeleteResult(detached: true, deletedAccountItem: false))
        #expect(deletedItemIDs.isEmpty)

        // Single-item remove: unshared item 500 IS deleted account-wide
        let orphanRes = try await client.removeItemFromGalleryAndDeleteIfOrphan(galleryID: 10, itemID: 500)
        #expect(orphanRes == ManualItemDeleteResult(detached: true, deletedAccountItem: true))
        #expect(deletedItemIDs == [500])

        // Empty-itemIds safety guard prevents account-wide deletion when /user/galleries omits itemIds
        deletedItemIDs.removeAll()
        omitItemIDsInGalleryList = true
        let guardedRes = try await client.removeItemFromGalleryAndDeleteIfOrphan(galleryID: 10, itemID: 500)
        #expect(guardedRes == ManualItemDeleteResult(detached: true, deletedAccountItem: false, skippedOrphanCheck: true))
        #expect(deletedItemIDs.isEmpty)

        // Deleting gallery 10 with empty-itemIds safety guard deletes gallery but skips orphan item deletion
        let guardedGalleryRes = try await client.deleteGalleryAndOrphanItems(galleryID: 10)
        #expect(guardedGalleryRes == ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [], skippedOrphanCleanup: true))
        #expect(deletedGalleryIDs == [10])
        #expect(deletedItemIDs.isEmpty)

        // Deleting already-gone gallery (404 on getGallery) succeeds cleanly
        let goneRes = try await client.deleteGalleryAndOrphanItems(galleryID: 99)
        #expect(goneRes == ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: []))

        // Deleting gallery 10 with normal itemIds deletes unshared 500 and preserves shared 501
        omitItemIDsInGalleryList = false
        let normalGalleryRes = try await client.deleteGalleryAndOrphanItems(galleryID: 10)
        #expect(normalGalleryRes == ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [500]))
        #expect(deletedItemIDs == [500])
        #expect(detachedPairs.contains(where: { $0.0 == 10 && $0.1 == 500 }))
    }

    @Test("pushGalleryToDevices sends missing gallery and switches all devices")
    func pushGalleryToDevices() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "frame")
        try store.setCachedToken("tok", for: "frame")

        var sentTo: [Int] = []
        var switched: [Int] = []
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if method == "GET" && url.hasSuffix("/v1/user/devices") {
                let json = """
                {"data":[
                    {"id":1,"alias":"Living Room","galleryIds":[10]},
                    {"id":2,"alias":"Office","galleryIds":[]}
                ]}
                """
                return (Data(json.utf8), 200)
            }
            if method == "POST" && url.contains("/galleries/10") {
                if url.contains("/devices/1/") { sentTo.append(1) }
                if url.contains("/devices/2/") { sentTo.append(2) }
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/control/") {
                if url.contains("/devices/1/") { switched.append(1) }
                if url.contains("/devices/2/") { switched.append(2) }
                return (Data(#"{"data":{}}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(instanceName: "frame", credentialStore: store, transport: transport, sleepHandler: { _ in })
        let count = try await client.pushGalleryToDevices(galleryID: 10)
        #expect(count == 2)
        #expect(sentTo == [2]) // Device 1 already had gallery 10
        #expect(switched == [1, 2])
    }

    @Test("SyncEngine aborts before destructive cleanup when zero photos match or upload")
    func syncEngineZeroUploadGuard() async throws {
        struct EmptyPhotoLibrary: PhotoLibraryProviding {
            func fetchAllPersonNames() async throws -> [String] { [] }
            func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] { [] }
        }
        struct UnusedExporter: PhotoExporting {
            func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
                throw PhotoExportError.assetNotFound(photo.uuid)
            }
        }

        let store = InMemoryCredentialStore()
        let instance = InstanceConfig(name: "Frame", enabled: true, sendToDevices: true)
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: instance.storageKey)

        let transport = MockTransport { _ in
            Issue.record("Network should not be called when zero photos match")
            return (Data("{}".utf8), 200)
        }

        let engine = SyncEngine()
        await #expect(throws: SyncError.self) {
            try await engine.runSync(
                config: AppConfig(instances: [instance]),
                credentialStore: store,
                photoLibrary: EmptyPhotoLibrary(),
                exporter: UnusedExporter(),
                stateStore: InMemorySyncStateStore(),
                clientFactory: { key, credStore, logHandler in
                    MeuralClient(instanceName: key, credentialStore: credStore, transport: transport, logHandler: logHandler)
                }
            )
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Config clamping and case-colliding aliases do not crash")
    func configClampingAndAliases() throws {
        let json = Data("""
        {
            "name": "Test",
            "photo_count": -10,
            "on_this_day_window_days": -5,
            "max_consecutive_upload_failures": 0,
            "upload_interval_seconds": 999999,
            "caption_location_aliases": {"Home": "My House", "home": "Our House"}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(InstanceConfig.self, from: json)
        #expect(decoded.photoCount == 1)
        #expect(decoded.onThisDayWindowDays == 0)
        #expect(decoded.maxConsecutiveUploadFailures == 1)
        #expect(decoded.uploadIntervalSeconds == 300)

        let loc = Captions.formatLocation("Home", aliases: decoded.captionLocationAliases)
        #expect(!loc.label.isEmpty)
    }

    @Test("On This Day window wraps across year boundary and excludes current year")
    func onThisDayFiltering() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let dec31Prev = cal.date(from: DateComponents(year: 2024, month: 12, day: 31))!
        let jan2Prev = cal.date(from: DateComponents(year: 2025, month: 1, day: 2))!
        let sameYear = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let farAway = cal.date(from: DateComponents(year: 2024, month: 6, day: 15))!

        #expect(SyncEngine.isOnThisDay(photoDate: dec31Prev, referenceDate: ref, windowDays: 1, calendar: cal))
        #expect(SyncEngine.isOnThisDay(photoDate: jan2Prev, referenceDate: ref, windowDays: 1, calendar: cal))
        #expect(!SyncEngine.isOnThisDay(photoDate: sameYear, referenceDate: ref, windowDays: 1, calendar: cal))
        #expect(!SyncEngine.isOnThisDay(photoDate: farAway, referenceDate: ref, windowDays: 1, calendar: cal))
    }

    @Test("Photo selection reserves On This Day slots and avoids duplicates")
    func photoSelection() {
        let now = Date()
        let photos = (0..<6).map { PhotoMetadata(uuid: "p-\($0)", date: now, width: 1000, height: 800) }
        let selected = SyncEngine.selectPhotos(
            from: photos,
            onThisDayPhotos: Array(photos.prefix(2)),
            photoCount: 5,
            onThisDayCount: 2
        )
        #expect(selected.count == 5)
        let uuids = Set(selected.map(\.uuid))
        #expect(uuids.count == 5)
        #expect(uuids.contains("p-0"))
        #expect(uuids.contains("p-1"))
    }

    @Test("PhotosDatabase queries synthetic Photos.sqlite with people and curation score")
    func syntheticPhotosDatabaseQuery() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-photos-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE ZASSET (
            Z_PK INTEGER PRIMARY KEY,
            ZUUID TEXT,
            ZDATECREATED REAL,
            ZWIDTH INTEGER,
            ZHEIGHT INTEGER,
            ZCURATIONSCORE REAL,
            ZKIND INTEGER,
            ZKINDSUBTYPE INTEGER,
            ZHIDDEN INTEGER,
            ZTRASHEDSTATE INTEGER,
            ZVISIBILITYSTATE INTEGER,
            ZDIRECTORY TEXT,
            ZFILENAME TEXT,
            ZADDITIONALATTRIBUTES INTEGER
        );
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (
            Z_PK INTEGER PRIMARY KEY,
            ZREVERSELOCATIONDATA BLOB
        );
        CREATE TABLE ZPERSON (
            Z_PK INTEGER PRIMARY KEY,
            ZFULLNAME TEXT,
            ZDISPLAYNAME TEXT
        );
        CREATE TABLE ZDETECTEDFACE (
            Z_PK INTEGER PRIMARY KEY,
            ZASSETFORFACE INTEGER,
            ZPERSONFORFACE INTEGER
        );
        INSERT INTO ZPERSON VALUES (1, 'Alice Smith', 'Alice'), (2, 'Excluded Person', 'Excluded');
        INSERT INTO ZASSET VALUES (1, 'UUID-GOOD', 700000000.0, 4000, 3000, 0.85, 0, 0, 0, 0, 0, '0', 'good.jpg', NULL);
        INSERT INTO ZASSET VALUES (2, 'UUID-LOWSCORE', 700000000.0, 4000, 3000, 0.20, 0, 0, 0, 0, 0, '0', 'low.jpg', NULL);
        INSERT INTO ZASSET VALUES (3, 'UUID-SCREENSHOT', 700000000.0, 1170, 2532, 0.90, 0, 10, 0, 0, 0, '0', 'ss.png', NULL);
        INSERT INTO ZASSET VALUES (4, 'UUID-EXCLUDED', 700000000.0, 4000, 3000, 0.90, 0, 0, 0, 0, 0, '0', 'ex.jpg', NULL);
        INSERT INTO ZDETECTEDFACE VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 4, 1), (5, 4, 2);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        let reader = PhotosDatabase(databaseURL: dbURL)
        let people = try reader.fetchAllPersonNames()
        #expect(people == ["Alice Smith", "Excluded Person"])

        let matches = try reader.queryPhotos(
            options: PhotosQueryOptions(
                includePeople: ["Alice Smith"],
                excludePeople: ["Excluded Person"],
                curationScoreMin: 0.5
            )
        )
        #expect(matches.count == 1)
        #expect(matches.first?.uuid == "UUID-GOOD")
        #expect(matches.first?.persons == ["Alice Smith"])
    }

    @Test("ScheduleConfig computes next runs and due status for hourly, daily, and weekly frequencies")
    func scheduleFrequencies() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-11-27 is a Friday (weekday 6)
        let friday10am = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 0))!
        let friday2pm = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 14, minute: 0))!

        // Daily at 12:00
        let daily = ScheduleConfig(enabled: true, frequency: .daily, hour: 12, minute: 0)
        let nextDailyBefore = daily.nextRunDate(after: friday10am, calendar: cal)
        #expect(nextDailyBefore == cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12, minute: 0)))
        let nextDailyAfter = daily.nextRunDate(after: friday2pm, calendar: cal)
        #expect(nextDailyAfter == cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 12, minute: 0)))
        #expect(!daily.isDue(at: friday10am, lastRun: nil, calendar: cal))
        #expect(daily.isDue(at: friday2pm, lastRun: nil, calendar: cal))
        #expect(!daily.isDue(at: friday2pm, lastRun: friday2pm, calendar: cal))

        // Weekly on Sundays (1) and Wednesdays (4) at 09:30
        let weekly = ScheduleConfig(enabled: true, frequency: .weekly, hour: 9, minute: 30, weekdays: [1, 4])
        let nextWeekly = weekly.nextRunDate(after: friday10am, calendar: cal)
        #expect(nextWeekly == cal.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 9, minute: 30)))
        #expect(!weekly.isDue(at: friday2pm, lastRun: nil, calendar: cal))

        // Hourly every 4 hours
        let hourly = ScheduleConfig(enabled: true, frequency: .hourly, intervalHours: 4)
        #expect(hourly.isDue(at: friday10am, lastRun: nil, calendar: cal))
        #expect(!hourly.isDue(at: friday2pm, lastRun: friday10am.addingTimeInterval(3600), calendar: cal))
        #expect(hourly.isDue(at: friday2pm, lastRun: friday10am, calendar: cal))

        // Multi-day wake catch-up: last ran Wednesday, now Friday 10am (before Friday's 12pm slot, missed Thursday 12pm)
        let wednesday2pm = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 14, minute: 0))!
        #expect(daily.isDue(at: friday10am, lastRun: wednesday2pm, calendar: cal))

        // Hourly nextRunDate never returns a date in the past
        let longAgo = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 0))!
        #expect(hourly.nextRunDate(after: friday10am, lastRun: longAgo, calendar: cal) == friday10am)

        // Backward-compatible decoding of legacy daily-only JSON
        let legacyJSON = Data(#"{"enabled":true,"hour":8,"minute":30}"#.utf8)
        let decoded = try JSONDecoder().decode(ScheduleConfig.self, from: legacyJSON)
        #expect(decoded.enabled == true)
        #expect(decoded.frequency == .daily)
        #expect(decoded.hour == 8)
        #expect(decoded.minute == 30)
    }

    @Test("SyncEngine records failed device pushes in SyncStateStore and clears them on success")
    func failedDevicePushTrackingAndClearing() async throws {
        // 1. Verify FileSyncStateStore backward-compatible decode + persistence of PendingDevicePush
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeuralSyncStateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stateURL = tempDir.appendingPathComponent("sync_state.json")
        let legacyStateJSON = Data(#"{"galleryIDsByInstance":{"inst-1":[42]},"itemIDsByInstance":{"inst-1":[100]}}"#.utf8)
        try legacyStateJSON.write(to: stateURL)

        let fileStore = FileSyncStateStore(fileURL: stateURL)
        #expect(fileStore.trackedGalleryIDs(for: "inst-1") == [42])
        #expect(fileStore.pendingDevicePush(for: "inst-1") == nil)

        let samplePush = PendingDevicePush(galleryID: 99, galleryName: "Test Album", errorMessage: "Canvas is offline")
        fileStore.setPendingDevicePush(samplePush, for: "inst-1")

        let reloaded = FileSyncStateStore(fileURL: stateURL)
        #expect(reloaded.pendingDevicePush(for: "inst-1")?.galleryID == 99)
        #expect(reloaded.pendingDevicePush(for: "inst-1")?.errorMessage == "Canvas is offline")

        reloaded.setPendingDevicePush(nil, for: "inst-1")
        #expect(FileSyncStateStore(fileURL: stateURL).pendingDevicePush(for: "inst-1") == nil)

        // 2. Verify SyncEngine records failure when device push fails, then clears when subsequent push succeeds
        struct SinglePhotoLibrary: PhotoLibraryProviding {
            let photos: [PhotoMetadata]
            func fetchAllPersonNames() async throws -> [String] { [] }
            func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] { photos }
            func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] { photos }
        }
        struct SinglePhotoExporter: PhotoExporting {
            func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(
                    data: nil,
                    width: photo.width,
                    height: photo.height,
                    bitsPerComponent: 8,
                    bytesPerRow: photo.width * 4,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
                let outURL = directory.appendingPathComponent("\(photo.uuid).jpg")
                try ImageProcessor.saveJPEG(ctx.makeImage()!, to: outURL)
                return outURL
            }
        }

        let credStore = InMemoryCredentialStore()
        let instance = InstanceConfig(
            name: "Grandparents Frame",
            enabled: true,
            sendToDevices: true,
            photoCount: 1,
            destinationAlbumName: "Family Sync",
            randomizeGalleryName: false,
            uploadIntervalSeconds: 0
        )
        try credStore.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: instance.storageKey)

        let stateStore = InMemorySyncStateStore()
        // Pre-seed an old tracked gallery (id: 44) that must survive when frame push fails!
        stateStore.recordGalleryID(44, for: instance.storageKey)
        var failDeviceControl = true
        var deletedGalleryIDs: [Int] = []
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/galleries") {
                return (Data(#"{"data":[{"id":44,"name":"Family Sync Old","items":[]},{"id":55,"name":"Family Sync","items":[]}]}"#.utf8), 200)
            }
            if method == "GET" && url.hasSuffix("/galleries/44") {
                return (Data(#"{"data":{"id":44,"name":"Family Sync Old","items":[]}}"#.utf8), 200)
            }
            if method == "DELETE" && url.hasSuffix("/galleries/44") {
                deletedGalleryIDs.append(44)
                return (Data(#"{}"#.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/items") {
                return (Data(#"{"data":{"id":701}}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/galleries/55/items/701") {
                return (Data(#"{}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/devices") {
                // Already on device so sendGalleryToDevice sleep is skipped; switchDeviceToGallery is exercised directly.
                return (Data(#"{"data":[{"id":38086,"alias":"Nana Frame","galleries":[55]}]}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/devices/38086/control/") {
                if failDeviceControl {
                    return (Data(#"{"errors":"Canvas is offline"}"#.utf8), 400)
                }
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let engine = SyncEngine()
        let library = SinglePhotoLibrary(photos: [
            PhotoMetadata(uuid: "P1", date: Date(), width: 1080, height: 1920, curationScore: 0.9),
        ])
        let exporter = SinglePhotoExporter()
        let clientFactory: @Sendable (String, any CredentialStoring, @escaping @Sendable (String) -> Void) -> MeuralClient = { key, store, logHandler in
            MeuralClient(
                instanceName: key,
                credentialStore: store,
                transport: transport,
                sleepHandler: { _ in },
                logHandler: logHandler
            )
        }

        // Run 1: device offline -> sync still succeeds, pending push is recorded, AND old gallery 44 is preserved!
        try await engine.runSync(
            config: AppConfig(instances: [instance]),
            credentialStore: credStore,
            photoLibrary: library,
            exporter: exporter,
            stateStore: stateStore,
            clientFactory: clientFactory
        )
        let recorded = stateStore.pendingDevicePush(for: instance.storageKey)
        #expect(recorded?.galleryID == 55)
        #expect(recorded?.galleryName == "Family Sync")
        #expect(recorded?.errorMessage.contains("Nana Frame") == true)
        #expect(recorded?.errorMessage.contains("Canvas is offline") == true)
        #expect(deletedGalleryIDs.isEmpty)
        #expect(stateStore.trackedGalleryIDs(for: instance.storageKey).contains(44))

        // Run 2: device back online -> pending push is cleared AND old gallery 44 is now cleaned up!
        failDeviceControl = false
        try await engine.runSync(
            config: AppConfig(instances: [instance]),
            credentialStore: credStore,
            photoLibrary: library,
            exporter: exporter,
            stateStore: stateStore,
            clientFactory: clientFactory
        )
        #expect(stateStore.pendingDevicePush(for: instance.storageKey) == nil)
        #expect(deletedGalleryIDs == [44])
        #expect(!stateStore.trackedGalleryIDs(for: instance.storageKey).contains(44))
    }

    @Test("MeuralDevice decodes orientation and gallery variants; SyncEngine auto-detects landscape frame")
    func deviceOrientationAndLandscapeSync() async throws {
        let json = Data(#"""
        {
            "id": 42,
            "name": "Living Room Horizontal",
            "orientation": "Horizontal",
            "galleries": [{"id": 101}, {"id": 102}],
            "active_gallery": {"id": 103}
        }
        """#.utf8)
        let device = try JSONDecoder().decode(MeuralDevice.self, from: json)
        #expect(device.alias == "Living Room Horizontal")
        #expect(device.parsedOrientation == .landscape)
        #expect(device.activeGalleryId == 103)
        #expect(Set(device.galleryIds ?? []) == Set([101, 102, 103]))

        let frameStatusJSON = Data(#"{"id":44,"frame_status":{"current_gallery":305}}"#.utf8)
        let frameStatusDevice = try JSONDecoder().decode(MeuralDevice.self, from: frameStatusJSON)
        #expect(frameStatusDevice.activeGalleryId == 305)
        #expect(frameStatusDevice.galleryIds == [305])

        let activeGalleryJSON = Data(#"{"id":305,"name":"Now Showing","active":true,"itemIds":[1,2]}"#.utf8)
        let activeGallery = try JSONDecoder().decode(MeuralGallery.self, from: activeGalleryJSON)
        #expect(activeGallery.isActiveOnDevice == true)

        let verticalJSON = Data(#"{"id":43,"alias":"Hallway","orientation":"vertical","galleryIds":[201]}"#.utf8)
        let verticalDevice = try JSONDecoder().decode(MeuralDevice.self, from: verticalJSON)
        #expect(verticalDevice.parsedOrientation == .portrait)
        #expect(verticalDevice.galleryIds == [201])

        // Verify SyncEngine auto-detects horizontal orientation and creates gallery with orientation=horizontal
        struct LandscapeLib: PhotoLibraryProviding {
            let photos: [PhotoMetadata]
            func fetchAllPersonNames() async throws -> [String] { [] }
            func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] { photos }
            func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] { photos }
        }
        struct LandscapeExp: PhotoExporting {
            func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(
                    data: nil,
                    width: photo.width,
                    height: photo.height,
                    bitsPerComponent: 8,
                    bytesPerRow: photo.width * 4,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
                let outURL = directory.appendingPathComponent("\(photo.uuid).jpg")
                try ImageProcessor.saveJPEG(ctx.makeImage()!, to: outURL)
                return outURL
            }
        }

        let credStore = InMemoryCredentialStore()
        let instance = InstanceConfig(
            name: "Horizontal Frame",
            enabled: true,
            sendToDevices: false,
            frameOrientation: .auto,
            photoCount: 3,
            destinationAlbumName: "Landscape Sync",
            randomizeGalleryName: false,
            uploadIntervalSeconds: 0
        )
        try credStore.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: instance.storageKey)

        var createdGalleryBody: String?
        var uploadCount = 0
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/devices") {
                return (Data(#"{"data":[{"id":42,"alias":"Horizontal","orientation":"horizontal","galleryIds":[]}]}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/galleries") {
                return (Data(#"{"data":[]}"#.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/galleries") {
                createdGalleryBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                return (Data(#"{"data":{"id":88,"name":"Landscape Sync","items":[]}}"#.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/items") {
                uploadCount += 1
                return (Data("{\"data\":{\"id\":\(800 + uploadCount)}}".utf8), 200)
            }
            if method == "POST" && url.contains("/galleries/88/items/") {
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        // 1 landscape (fullsize) + 2 portraits (paired side-by-side into 1 upload) => 2 uploads total!
        let photos = [
            PhotoMetadata(uuid: "L1", date: Date(), width: 1600, height: 1000, curationScore: 0.9),
            PhotoMetadata(uuid: "P1", date: Date(), width: 800, height: 1200, curationScore: 0.9),
            PhotoMetadata(uuid: "P2", date: Date(), width: 800, height: 1200, curationScore: 0.9),
        ]

        let engine = SyncEngine()
        try await engine.runSync(
            config: AppConfig(instances: [instance]),
            credentialStore: credStore,
            photoLibrary: LandscapeLib(photos: photos),
            exporter: LandscapeExp(),
            stateStore: InMemorySyncStateStore(),
            clientFactory: { key, store, logHandler in
                MeuralClient(instanceName: key, credentialStore: store, transport: transport, sleepHandler: { _ in }, logHandler: logHandler)
            }
        )

        #expect(createdGalleryBody?.contains("orientation=horizontal") == true)
        #expect(uploadCount == 2)
    }

    @Test("Orphan cleanup skips deletion when any gallery omits itemIds; multi-instance sync continues after first failure")
    func partialItemIdsSafetyAndMultiInstanceIsolation() async throws {
        // 1. Partial itemIds guard: gallery 1 has explicit itemIds, gallery 2 omits itemIds -> must skip orphan delete
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "inst-partial")
        var deletedItemIDs: [Int] = []
        let partialTransport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/galleries") {
                return (Data(#"{"data":[{"id":1,"name":"Explicit","itemIds":[10]},{"id":2,"name":"Omitted"}]}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/items/") {
                if let id = Int(url.split(separator: "/").last ?? "") {
                    deletedItemIDs.append(id)
                }
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }
        let client = MeuralClient(instanceName: "inst-partial", credentialStore: store, transport: partialTransport, sleepHandler: { _ in })
        let cleanup = try await client.deleteOrphanPhotos(trackedItemIDs: [99], protectedItemIDs: [])
        #expect(cleanup.deletedCount == 0)
        #expect(deletedItemIDs.isEmpty)

        // 2. Multi-instance sync: Instance 1 fails (no matching photos), Instance 2 still runs and uploads!
        struct MultiLib: PhotoLibraryProviding {
            func fetchAllPersonNames() async throws -> [String] { ["Bob"] }
            func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] {
                if options.includePeople.contains("Nobody") { return [] }
                return [PhotoMetadata(uuid: "OK-1", date: Date(), width: 1080, height: 1920, curationScore: 0.9)]
            }
            func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] { photos }
        }
        struct SimpleExp: PhotoExporting {
            func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(
                    data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: photo.width * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
                let outURL = directory.appendingPathComponent("\(photo.uuid).jpg")
                try ImageProcessor.saveJPEG(ctx.makeImage()!, to: outURL)
                return outURL
            }
        }

        let inst1 = InstanceConfig(
            name: "Failing Frame",
            enabled: true,
            sendToDevices: false,
            frameOrientation: .portrait,
            photoCount: 1,
            people: PeopleFilter(include: ["Nobody"]),
            destinationAlbumName: "Fail Sync",
            randomizeGalleryName: false,
            uploadIntervalSeconds: 0
        )
        let inst2 = InstanceConfig(
            name: "Healthy Frame",
            enabled: true,
            sendToDevices: false,
            frameOrientation: .portrait,
            photoCount: 1,
            people: PeopleFilter(include: ["Bob"]),
            destinationAlbumName: "Healthy Sync",
            randomizeGalleryName: false,
            uploadIntervalSeconds: 0
        )
        try store.setCredentials(MeuralCredentials(email: "u1@example.com", password: "pw"), for: inst1.storageKey)
        try store.setCredentials(MeuralCredentials(email: "u2@example.com", password: "pw"), for: inst2.storageKey)

        var inst2Uploaded = 0
        let multiTransport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/galleries") {
                return (Data(#"{"data":[{"id":77,"name":"Healthy Sync","itemIds":[]}]}"#.utf8), 200)
            }
            if method == "POST" && url.hasSuffix("/items") {
                inst2Uploaded += 1
                return (Data(#"{"data":{"id":901}}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/galleries/77/items/901") {
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let engine = SyncEngine()
        await #expect(throws: SyncError.self) {
            try await engine.runSync(
                config: AppConfig(instances: [inst1, inst2]),
                credentialStore: store,
                photoLibrary: MultiLib(),
                exporter: SimpleExp(),
                stateStore: InMemorySyncStateStore(),
                clientFactory: { key, credStore, logHandler in
                    MeuralClient(instanceName: key, credentialStore: credStore, transport: multiTransport, sleepHandler: { _ in }, logHandler: logHandler)
                }
            )
        }
        // Instance 2 still completed its upload even though Instance 1 failed!
        #expect(inst2Uploaded == 1)
    }

    @Test("deleteGalleryAndOrphanItems with deleteAllItems deletes album and all its photos including fallback lookup")
    func deleteAlbumAndAllItems() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "inst-delall")

        var detached: [Int] = []
        var deletedItems: [Int] = []
        var galleryDeleted = false
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.hasSuffix("/galleries/50") {
                // Simulate /galleries/{id} omitting itemIds so fallback /galleries/{id}/items is exercised
                return (Data(#"{"data":{"id":50,"name":"Old Album"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/galleries/50/items") {
                return (Data(#"{"data":[{"id":501},{"id":502}]}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/galleries/50/items/") {
                if let id = Int(url.split(separator: "/").last ?? "") { detached.append(id) }
                return (Data(#"{}"#.utf8), 200)
            }
            if method == "DELETE" && url.hasSuffix("/galleries/50") {
                galleryDeleted = true
                return (Data(#"{}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/items/") {
                if let id = Int(url.split(separator: "/").last ?? "") { deletedItems.append(id) }
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(instanceName: "inst-delall", credentialStore: store, transport: transport, sleepHandler: { _ in })
        let result = try await client.deleteGalleryAndOrphanItems(galleryID: 50, deleteAllItems: true)
        #expect(result.galleryDeleted == true)
        #expect(galleryDeleted == true)
        #expect(Set(detached) == Set([501, 502]))
        #expect(result.deletedItemIDs == Set([501, 502]))
        #expect(Set(deletedItems) == Set([501, 502]))
        #expect(result.skippedOrphanCleanup == false)
    }

    @Test("Manual unassigned-photo cleanup resolves omitted gallery itemIds and deletes only unassigned account photos")
    func manualUnassignedPhotoCleanup() async throws {
        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "inst-unassigned")

        var deletedItems: [Int] = []
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/galleries") {
                // Gallery 10 has explicit itemIds [100]; Gallery 20 omits itemIds (resolved via /galleries/20/items -> [200])
                return (Data(#"{"data":[{"id":10,"name":"Album A","itemIds":[100]},{"id":20,"name":"Album B"}]}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/galleries/20/items") {
                return (Data(#"{"data":[{"id":200}]}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/items") {
                return (Data(#"{"data":[{"id":100,"fileSize":1000000},{"id":200,"fileSize":2000000},{"id":300,"fileSize":1500000},{"id":400,"fileSize":2500000}]}"#.utf8), 200)
            }
            if method == "DELETE" && url.contains("/items/") {
                if let id = Int(url.split(separator: "/").last ?? "") { deletedItems.append(id) }
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(instanceName: "inst-unassigned", credentialStore: store, transport: transport, sleepHandler: { _ in })
        let summary = try await client.getUnassignedItemsSummary()
        #expect(summary.count == 2)
        #expect(summary.totalBytes == 4_000_000)
        #expect(summary.isEstimated == false)
        #expect(summary.formattedSize != nil)

        let result = try await client.deleteOrphanPhotos(trackedItemIDs: nil, protectedItemIDs: [], allowEmptyGalleries: true)
        #expect(result.deletedCount == 2)
        #expect(Set(deletedItems) == Set([300, 400]))
        #expect(result.prunedItemIDs == Set([300, 400]))
    }

    @Test("pushGalleryToDevices respects targetDeviceID and InstanceConfig persists device_id")
    func targetDeviceSelection() async throws {
        let cfg = InstanceConfig(name: "Hallway", sendToDevices: true, deviceId: 202)
        let encoded = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(InstanceConfig.self, from: encoded)
        #expect(decoded.deviceId == 202)

        let legacy = try JSONDecoder().decode(InstanceConfig.self, from: Data(#"{"name":"Legacy"}"#.utf8))
        #expect(legacy.deviceId == nil)

        let store = InMemoryCredentialStore()
        try store.setCredentials(MeuralCredentials(email: "u@example.com", password: "pw"), for: "inst-target")

        var sentToDevices: [Int] = []
        var switchedDevices: [Int] = []
        let transport = MockTransport { request in
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.contains("cognito-idp") {
                return (Data(#"{"AuthenticationResult":{"AccessToken":"tok"}}"#.utf8), 200)
            }
            if method == "GET" && url.contains("/user/devices") {
                return (Data(#"{"data":[{"id":101,"alias":"Portrait Frame","galleryIds":[]},{"id":202,"alias":"Landscape Frame","galleryIds":[]}]}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/galleries/99") {
                if let devPart = url.components(separatedBy: "/devices/").last?.components(separatedBy: "/").first,
                   let id = Int(devPart) {
                    sentToDevices.append(id)
                }
                return (Data(#"{}"#.utf8), 200)
            }
            if method == "POST" && url.contains("/control/") {
                if let devPart = url.components(separatedBy: "/devices/").last?.components(separatedBy: "/").first,
                   let id = Int(devPart) {
                    switchedDevices.append(id)
                }
                return (Data(#"{}"#.utf8), 200)
            }
            return (Data(#"{"data":[]}"#.utf8), 200)
        }

        let client = MeuralClient(instanceName: "inst-target", credentialStore: store, transport: transport, sleepHandler: { _ in })
        let updated = try await client.pushGalleryToDevices(galleryID: 99, targetDeviceID: 202)
        #expect(updated == 1)
        #expect(sentToDevices == [202])
        #expect(switchedDevices == [202])

        await #expect(throws: MeuralAPIError.self) {
            try await client.pushGalleryToDevices(galleryID: 99, targetDeviceID: 999)
        }
    }
}
