import Foundation
import OSLog

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeoutInterval: TimeInterval = 120) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = max(timeoutInterval * 2, 300)
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public enum MeuralAPIError: Error, LocalizedError, Sendable {
    case httpError(statusCode: Int, method: String, url: String, body: String)
    case authenticationFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let method, let url, let body):
            return "Meural API error: \(method) \(url) returned HTTP \(statusCode): \(body)"
        case .authenticationFailed(let message):
            return "Meural authentication failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode Meural response: \(message)"
        }
    }

    public var statusCode: Int? {
        if case .httpError(let code, _, _, _) = self { return code }
        return nil
    }

    public var isTransient: Bool {
        if case .httpError(let code, _, _, _) = self {
            return code == 408 || code == 429 || (500..<600).contains(code)
        }
        return false
    }
}

public struct MeuralDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let alias: String?
    public let orientation: String?
    public let galleryIds: [Int]?

    public init(id: Int, alias: String? = nil, orientation: String? = nil, galleryIds: [Int]? = nil) {
        self.id = id
        self.alias = alias
        self.orientation = orientation
        self.galleryIds = galleryIds
    }

    public var parsedOrientation: CanvasOrientation? {
        guard let raw = orientation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if raw == "horizontal" || raw == "landscape" {
            return .landscape
        }
        if raw == "vertical" || raw == "portrait" {
            return .portrait
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case alias
        case name
        case orientation
        case galleryIds
        case galleries
        case activeGallery
        case activeGallerySnake = "active_gallery"
    }

    private struct GalleryRef: Decodable {
        let id: Int
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        let decodedAlias = try container.decodeIfPresent(String.self, forKey: .alias)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        self.alias = (decodedAlias?.isEmpty == false ? decodedAlias : nil)
            ?? (decodedName?.isEmpty == false ? decodedName : nil)
        self.orientation = try container.decodeIfPresent(String.self, forKey: .orientation)

        var ids: [Int]? = try container.decodeIfPresent([Int].self, forKey: .galleryIds)
        if ids == nil {
            if let intGalleries = try? container.decodeIfPresent([Int].self, forKey: .galleries) {
                ids = intGalleries
            } else if let objGalleries = try? container.decodeIfPresent([GalleryRef].self, forKey: .galleries) {
                ids = objGalleries.map(\.id)
            }
        }
        if let activeObj = try? container.decodeIfPresent(GalleryRef.self, forKey: .activeGallery) {
            var merged = ids ?? []
            if !merged.contains(activeObj.id) { merged.append(activeObj.id) }
            ids = merged
        } else if let activeObj = try? container.decodeIfPresent(GalleryRef.self, forKey: .activeGallerySnake) {
            var merged = ids ?? []
            if !merged.contains(activeObj.id) { merged.append(activeObj.id) }
            ids = merged
        } else if let activeID = try? container.decodeIfPresent(Int.self, forKey: .activeGallery) {
            var merged = ids ?? []
            if !merged.contains(activeID) { merged.append(activeID) }
            ids = merged
        } else if let activeID = try? container.decodeIfPresent(Int.self, forKey: .activeGallerySnake) {
            var merged = ids ?? []
            if !merged.contains(activeID) { merged.append(activeID) }
            ids = merged
        }
        self.galleryIds = ids
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encodeIfPresent(orientation, forKey: .orientation)
        try container.encodeIfPresent(galleryIds, forKey: .galleryIds)
    }
}

public struct MeuralGallery: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let itemIds: [Int]

    public init(id: Int, name: String, itemIds: [Int] = []) {
        self.id = id
        self.name = name
        self.itemIds = itemIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.itemIds = try container.decodeIfPresent([Int].self, forKey: .itemIds) ?? []
    }
}

public struct MeuralItem: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String?
    public let imageURL: URL?
    public let thumbnailURL: URL?

    public init(id: Int, name: String? = nil, imageURL: URL? = nil, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case image
        case originalImage
        case imagePortrait = "image_portrait"
        case imageLandscape = "image_landscape"
        case thumbnail
        case smallImage
        case mediumImage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)

        func nonEmpty(_ key: CodingKeys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        func validURL(_ key: CodingKeys) -> URL? {
            nonEmpty(key).flatMap(URL.init(string:))
        }

        self.name = nonEmpty(.name) ?? nonEmpty(.title)
        self.imageURL = validURL(.image)
            ?? validURL(.originalImage)
            ?? validURL(.imagePortrait)
            ?? validURL(.imageLandscape)
        self.thumbnailURL = validURL(.thumbnail)
            ?? validURL(.smallImage)
            ?? validURL(.mediumImage)
            ?? self.imageURL
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(imageURL?.absoluteString, forKey: .image)
        try container.encodeIfPresent(thumbnailURL?.absoluteString, forKey: .thumbnail)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct OrphanCleanupResult: Sendable, Equatable {
    public let deletedCount: Int
    public let prunedItemIDs: Set<Int>

    public init(deletedCount: Int, prunedItemIDs: Set<Int>) {
        self.deletedCount = deletedCount
        self.prunedItemIDs = prunedItemIDs
    }
}

public struct ManualItemDeleteResult: Sendable, Equatable {
    public let detached: Bool
    public let deletedAccountItem: Bool
    public let skippedOrphanCheck: Bool

    public init(detached: Bool, deletedAccountItem: Bool, skippedOrphanCheck: Bool = false) {
        self.detached = detached
        self.deletedAccountItem = deletedAccountItem
        self.skippedOrphanCheck = skippedOrphanCheck
    }
}

public struct ManualGalleryDeleteResult: Sendable, Equatable {
    public let galleryDeleted: Bool
    public let deletedItemIDs: Set<Int>
    public let skippedOrphanCleanup: Bool

    public init(galleryDeleted: Bool, deletedItemIDs: Set<Int>, skippedOrphanCleanup: Bool = false) {
        self.galleryDeleted = galleryDeleted
        self.deletedItemIDs = deletedItemIDs
        self.skippedOrphanCleanup = skippedOrphanCleanup
    }
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let maxJitter: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxJitter: TimeInterval = 0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxJitter = maxJitter
    }

    /// Standard API retry: 3 attempts, exponential 1s..10s.
    public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10, maxJitter: 0)

    /// Upload/attach retry: 6 attempts, exponential 5s..60s + 0..10s random jitter (~3 min max per item).
    public static let upload = RetryPolicy(maxAttempts: 6, baseDelay: 5, maxDelay: 60, maxJitter: 10)

    public func delay(forAttempt attempt: Int, randomUnit: Double) -> TimeInterval {
        // attempt is 1-based (1 -> baseDelay * 2^0, 2 -> baseDelay * 2^1, ...)
        let exp = min(maxDelay, baseDelay * pow(2.0, Double(max(0, attempt - 1))))
        let jitter = maxJitter > 0 ? randomUnit * maxJitter : 0
        return exp + jitter
    }
}

public actor MeuralClient {
    public static let baseURL = "https://api.meural.com/v1"
    public static let cognitoClientID = "487bd4kvb1fnop6mbgk8gu5ibf"
    public static let cognitoRegion = "eu-west-1"

    public let instanceName: String
    private let credentialStore: any CredentialStoring
    private let transport: any HTTPTransport
    private let standardRetry: RetryPolicy
    private let uploadRetry: RetryPolicy
    private let sleepHandler: @Sendable (TimeInterval) async throws -> Void
    private let randomUnit: @Sendable () -> Double
    private let logHandler: @Sendable (String) -> Void
    private let logger = Logger(subsystem: "com.ablyler.MeuralSync", category: "MeuralClient")

    private var token: String?

    public init(
        instanceName: String,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        standardRetry: RetryPolicy = .standard,
        uploadRetry: RetryPolicy = .upload,
        sleepHandler: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0.0...1.0) },
        logHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.instanceName = instanceName
        self.credentialStore = credentialStore
        self.transport = transport
        self.standardRetry = standardRetry
        self.uploadRetry = uploadRetry
        self.sleepHandler = sleepHandler
        self.randomUnit = randomUnit
        self.logHandler = logHandler
    }

    // MARK: - Authentication

    /// Loads cached token if valid, otherwise authenticates via AWS Cognito `USER_PASSWORD_AUTH`.
    public func ensureAuthenticated() async throws {
        if token != nil { return }
        if let cached = credentialStore.getCachedToken(for: instanceName),
           await validateToken(cached)
        {
            log("Using cached token for \(instanceName)")
            token = cached
            return
        }
        log("No valid cached token, authenticating \(instanceName)")
        try await reauthenticate()
    }

    private func validateToken(_ candidate: String) async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/user/devices") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Token \(candidate)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await transport.send(req)
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    /// Direct AWS Cognito `InitiateAuth` (`USER_PASSWORD_AUTH`) over HTTPS without needing the AWS SDK.
    public func reauthenticate() async throws {
        let creds = try credentialStore.getCredentials(for: instanceName)
        guard let url = URL(string: "https://cognito-idp.\(Self.cognitoRegion).amazonaws.com/") else {
            throw MeuralAPIError.authenticationFailed("Invalid Cognito endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.InitiateAuth", forHTTPHeaderField: "X-Amz-Target")

        let payload: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": Self.cognitoClientID,
            "AuthParameters": [
                "USERNAME": creds.email,
                "PASSWORD": creds.password,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var attempt = 1
        let data: Data
        let response: HTTPURLResponse
        while true {
            do {
                let result = try await transport.send(request)
                if result.1.statusCode == 408 || result.1.statusCode == 429 || (500..<600).contains(result.1.statusCode),
                   attempt < standardRetry.maxAttempts
                {
                    let delay = standardRetry.delay(forAttempt: attempt, randomUnit: randomUnit())
                    log("Transient Cognito HTTP \(result.1.statusCode) (attempt \(attempt)/\(standardRetry.maxAttempts)); retrying in \(Int(delay.rounded()))s")
                    try await sleepHandler(delay)
                    attempt += 1
                    continue
                }
                data = result.0
                response = result.1
                break
            } catch {
                if Self.isTransientError(error) && attempt < standardRetry.maxAttempts {
                    let delay = standardRetry.delay(forAttempt: attempt, randomUnit: randomUnit())
                    log("Transient Cognito network error (attempt \(attempt)/\(standardRetry.maxAttempts)); retrying in \(Int(delay.rounded()))s: \(error.localizedDescription)")
                    try await sleepHandler(delay)
                    attempt += 1
                    continue
                }
                throw error
            }
        }
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MeuralAPIError.authenticationFailed("HTTP \(response.statusCode): \(body)")
        }

        struct CognitoResponse: Decodable {
            struct AuthResult: Decodable {
                let AccessToken: String
            }
            let AuthenticationResult: AuthResult?
        }

        let decoded = try JSONDecoder().decode(CognitoResponse.self, from: data)
        guard let accessToken = decoded.AuthenticationResult?.AccessToken else {
            throw MeuralAPIError.authenticationFailed("Missing AccessToken for \(instanceName)")
        }

        self.token = accessToken
        try? credentialStore.setCachedToken(accessToken, for: instanceName)
        log("Successfully authenticated \(instanceName)")
    }

    // MARK: - Device Methods

    public func getDevices() async throws -> [MeuralDevice] {
        struct Response: Decodable { let data: [MeuralDevice] }
        let data = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/user/devices", method: "GET")
        }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    public func sendGalleryToDevice(deviceID: Int, galleryID: Int) async throws {
        _ = try await performAuthenticated(policy: standardRetry) {
            var req = try self.makeRequest(path: "/devices/\(deviceID)/galleries/\(galleryID)", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return req
        }
    }

    public func switchDeviceToGallery(deviceID: Int, galleryID: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "parameter1": galleryID,
            "instruction": "change_gallery",
        ])
        _ = try await performAuthenticated(policy: standardRetry) {
            var req = try self.makeRequest(path: "/devices/\(deviceID)/control/", method: "POST")
            req.httpBody = body
            req.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("7.0.0", forHTTPHeaderField: "x-meural-ios-version")
            req.setValue("ios", forHTTPHeaderField: "x-meural-source-platform")
            req.setValue("5", forHTTPHeaderField: "x-meural-api-version")
            req.setValue("meural", forHTTPHeaderField: "x-meural-source-product")
            req.setValue("en", forHTTPHeaderField: "Accept-Language")
            return req
        }
    }

    /// Sends `galleryID` to all Meural devices on the account (if not already present) and switches each frame to it.
    /// Returns the number of devices updated.
    @discardableResult
    public func pushGalleryToDevices(galleryID: Int) async throws -> Int {
        let devices = try await getDevices()
        guard !devices.isEmpty else { return 0 }
        for device in devices {
            try Task.checkCancellation()
            let alreadyOnDevice = device.galleryIds?.contains(galleryID) ?? false
            if !alreadyOnDevice {
                log("Sending gallery \(galleryID) to device \(device.id)")
                try await sendGalleryToDevice(deviceID: device.id, galleryID: galleryID)
                try await sleepHandler(5)
            }
            log("Switching device \(device.id) to gallery \(galleryID)")
            try await switchDeviceToGallery(deviceID: device.id, galleryID: galleryID)
        }
        return devices.count
    }

    // MARK: - Gallery Methods

    public func getGalleries() async throws -> [MeuralGallery] {
        struct Response: Decodable { let data: [MeuralGallery] }
        var all: [MeuralGallery] = []
        var seenIDs = Set<Int>()
        let pageSize = 100
        for page in 1...100 {
            let data = try await performAuthenticated(policy: standardRetry) {
                try self.makeRequest(path: "/user/galleries?count=\(pageSize)&page=\(page)", method: "GET")
            }
            let pageGalleries = try JSONDecoder().decode(Response.self, from: data).data
            if pageGalleries.isEmpty { break }
            var addedAny = false
            for gallery in pageGalleries where seenIDs.insert(gallery.id).inserted {
                all.append(gallery)
                addedAny = true
            }
            if !addedAny {
                break
            }
        }
        return all
    }

    public func getDeviceGalleries(deviceID: Int) async throws -> [MeuralGallery] {
        struct Response: Decodable { let data: [MeuralGallery] }
        var all: [MeuralGallery] = []
        var seenIDs = Set<Int>()
        let pageSize = 100
        for page in 1...100 {
            let data = try await performAuthenticated(policy: standardRetry) {
                try self.makeRequest(path: "/devices/\(deviceID)/galleries?count=\(pageSize)&page=\(page)", method: "GET")
            }
            let pageGalleries = try JSONDecoder().decode(Response.self, from: data).data
            if pageGalleries.isEmpty { break }
            var addedAny = false
            for gallery in pageGalleries where seenIDs.insert(gallery.id).inserted {
                all.append(gallery)
                addedAny = true
            }
            if !addedAny {
                break
            }
        }
        return all
    }

    public func getGallery(id galleryID: Int) async throws -> MeuralGallery {
        struct Response: Decodable { let data: MeuralGallery }
        let data = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/galleries/\(galleryID)", method: "GET")
        }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    public func createGallery(name: String, description: String = "", orientation: String = "vertical") async throws -> MeuralGallery {
        struct Response: Decodable { let data: MeuralGallery }
        let formBody = [
            "name=\(Self.formEncode(name))",
            "description=\(Self.formEncode(description))",
            "orientation=\(Self.formEncode(orientation))",
        ].joined(separator: "&")

        let data = try await performAuthenticated(policy: standardRetry) {
            var req = try self.makeRequest(path: "/galleries", method: "POST")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(formBody.utf8)
            return req
        }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    public func getOrCreateGallery(name: String, orientation: String = "vertical") async throws -> MeuralGallery {
        let galleries = try await getGalleries()
        if let existing = galleries.first(where: { $0.name == name }) {
            return existing
        }
        return try await createGallery(name: name, orientation: orientation)
    }

    public func deleteGallery(id galleryID: Int) async throws {
        _ = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/galleries/\(galleryID)", method: "DELETE")
        }
    }

    // MARK: - Item Methods

    public func getItems(count: Int = 100, page: Int = 1) async throws -> [MeuralItem] {
        struct Response: Decodable { let data: [MeuralItem] }
        let data = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/user/items?count=\(count)&page=\(page)", method: "GET")
        }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    /// Fetches all items belonging to a specific gallery (paginated).
    public func getGalleryItems(galleryID: Int) async throws -> [MeuralItem] {
        struct Response: Decodable { let data: [MeuralItem] }
        var all: [MeuralItem] = []
        var seenIDs = Set<Int>()
        let pageSize = 100
        for page in 1...100 {
            let data = try await performAuthenticated(policy: standardRetry) {
                try self.makeRequest(path: "/galleries/\(galleryID)/items?count=\(pageSize)&page=\(page)", method: "GET")
            }
            let pageItems = try JSONDecoder().decode(Response.self, from: data).data
            if pageItems.isEmpty { break }
            var addedAny = false
            for item in pageItems where seenIDs.insert(item.id).inserted {
                all.append(item)
                addedAny = true
            }
            if !addedAny {
                break
            }
        }
        return all
    }

    /// Detaches an item from a gallery and deletes the underlying account item if it is no longer
    /// referenced by any other gallery (with an empty-`itemIds` safety guard).
    @discardableResult
    public func removeItemFromGalleryAndDeleteIfOrphan(galleryID: Int, itemID: Int) async throws -> ManualItemDeleteResult {
        do {
            try await deleteGalleryItem(galleryID: galleryID, itemID: itemID)
        } catch let err as MeuralAPIError where err.statusCode == 404 {
            // Already detached.
        }

        let otherGalleries: [MeuralGallery]
        do {
            otherGalleries = try await getGalleries().filter { $0.id != galleryID }
        } catch {
            log("Warning: item \(itemID) detached from gallery \(galleryID), but orphan check failed: \(error.localizedDescription)")
            return ManualItemDeleteResult(detached: true, deletedAccountItem: false, skippedOrphanCheck: true)
        }

        // Safety guard: if other galleries exist but none report itemIds, do not risk deleting a shared photo.
        let otherItemIDs = otherGalleries.reduce(into: Set<Int>()) { $0.formUnion($1.itemIds) }
        if !otherGalleries.isEmpty && otherItemIDs.isEmpty {
            log("Skipping account-wide delete for item \(itemID): remaining galleries returned empty itemIds (safety guard).")
            return ManualItemDeleteResult(detached: true, deletedAccountItem: false, skippedOrphanCheck: true)
        }

        guard !otherItemIDs.contains(itemID) else {
            return ManualItemDeleteResult(detached: true, deletedAccountItem: false)
        }

        do {
            try await deleteItem(id: itemID)
            return ManualItemDeleteResult(detached: true, deletedAccountItem: true)
        } catch let err as MeuralAPIError where err.statusCode == 404 {
            return ManualItemDeleteResult(detached: true, deletedAccountItem: true)
        } catch {
            log("Warning: item \(itemID) detached from gallery \(galleryID), but account delete failed: \(error.localizedDescription)")
            return ManualItemDeleteResult(detached: true, deletedAccountItem: false, skippedOrphanCheck: true)
        }
    }

    /// Detaches all items from a gallery, deletes the gallery, and best-effort deletes any detached items
    /// that are not referenced by any remaining gallery (with an empty-`itemIds` safety guard).
    @discardableResult
    public func deleteGalleryAndOrphanItems(galleryID: Int) async throws -> ManualGalleryDeleteResult {
        let detachedItemIDs: Set<Int>
        do {
            let gallery = try await getGallery(id: galleryID)
            detachedItemIDs = Set(gallery.itemIds)
            for itemID in gallery.itemIds {
                try Task.checkCancellation()
                do {
                    try await deleteGalleryItem(galleryID: galleryID, itemID: itemID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as URLError where err.code == .cancelled {
                    throw CancellationError()
                } catch let err as MeuralAPIError where err.statusCode == 404 {
                    continue
                } catch {
                    log("Warning: failed detaching item \(itemID) from gallery \(galleryID): \(error.localizedDescription)")
                }
            }
        } catch let err as MeuralAPIError where err.statusCode == 404 {
            return ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [])
        }

        do {
            try await deleteGallery(id: galleryID)
        } catch let err as MeuralAPIError where err.statusCode == 404 {
            // Already deleted.
        }

        guard !detachedItemIDs.isEmpty else {
            return ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [])
        }

        // Gallery is now deleted on Meural; orphan cleanup is best-effort so partial failures never misreport gallery deletion.
        let remainingGalleries: [MeuralGallery]
        do {
            remainingGalleries = try await getGalleries().filter { $0.id != galleryID }
        } catch {
            log("Warning: gallery \(galleryID) deleted, but orphan check failed: \(error.localizedDescription)")
            return ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [], skippedOrphanCleanup: true)
        }

        let referencedIDs = remainingGalleries.reduce(into: Set<Int>()) { $0.formUnion($1.itemIds) }
        if !remainingGalleries.isEmpty && referencedIDs.isEmpty {
            log("Skipping orphan item deletion after deleting gallery \(galleryID): remaining galleries returned empty itemIds (safety guard).")
            return ManualGalleryDeleteResult(galleryDeleted: true, deletedItemIDs: [], skippedOrphanCleanup: true)
        }

        var deletedItemIDs = Set<Int>()
        var skippedOrphanCleanup = false
        for itemID in detachedItemIDs where !referencedIDs.contains(itemID) {
            if Task.isCancelled {
                skippedOrphanCleanup = true
                break
            }
            do {
                try await deleteItem(id: itemID)
                deletedItemIDs.insert(itemID)
            } catch let err as MeuralAPIError where err.statusCode == 404 {
                deletedItemIDs.insert(itemID)
            } catch {
                skippedOrphanCleanup = true
                log("Warning: failed deleting orphan item \(itemID) after gallery delete: \(error.localizedDescription)")
            }
        }
        return ManualGalleryDeleteResult(
            galleryDeleted: true,
            deletedItemIDs: deletedItemIDs,
            skippedOrphanCleanup: skippedOrphanCleanup
        )
    }

    /// Uploads a JPEG file as a new item, then attaches it to the gallery.
    /// Attachment retries independently so a failed attach never re-uploads the image.
    @discardableResult
    public func uploadItem(galleryID: Int, fileURL: URL) async throws -> Int {
        let itemID = try await createItem(fileURL: fileURL)
        try await attachItem(galleryID: galleryID, itemID: itemID)
        return itemID
    }

    public func createItem(fileURL: URL) async throws -> Int {
        struct Response: Decodable { let data: MeuralItem }
        let data = try await performAuthenticated(policy: uploadRetry) {
            let fileData = try Data(contentsOf: fileURL)
            let boundary = "Boundary-\(UUID().uuidString)"
            var req = try self.makeRequest(path: "/items", method: "POST")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body
            return req
        }
        return try JSONDecoder().decode(Response.self, from: data).data.id
    }

    public func attachItem(galleryID: Int, itemID: Int) async throws {
        _ = try await performAuthenticated(policy: uploadRetry) {
            try self.makeRequest(path: "/galleries/\(galleryID)/items/\(itemID)", method: "POST")
        }
    }

    public func deleteItem(id itemID: Int) async throws {
        _ = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/items/\(itemID)", method: "DELETE")
        }
    }

    public func deleteGalleryItem(galleryID: Int, itemID: Int) async throws {
        _ = try await performAuthenticated(policy: standardRetry) {
            try self.makeRequest(path: "/galleries/\(galleryID)/items/\(itemID)", method: "DELETE")
        }
    }

    // MARK: - Gallery Cleanup Helpers

    /// Builds a strict regex matching gallery names generated from `destinationAlbumName`.
    /// Returns `nil` if the static (non-`:date:`) portion of the template is too short (< 3 chars),
    /// preventing accidental deletion of unrelated galleries when a template is empty or `:date:`-only.
    public static func galleryTemplateRegex(for destinationAlbumName: String) -> NSRegularExpression? {
        let staticPortion = destinationAlbumName
            .replacingOccurrences(of: ":date:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard staticPortion.count >= 3 else { return nil }

        let parts = destinationAlbumName.components(separatedBy: ":date:")
        let pattern = parts
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: #"\d{4}-\d{2}-\d{2}"#)
        let fullPattern = "^\(pattern)(?: - [0-9a-fA-F]{7})?$"
        return try? NSRegularExpression(pattern: fullPattern, options: [])
    }

    public func listOldGalleries(
        currentGalleryID: Int,
        destinationAlbumName: String,
        trackedGalleryIDs: Set<Int> = []
    ) async throws -> [Int] {
        let galleries = try await getGalleries()
        let templateRegex = Self.galleryTemplateRegex(for: destinationAlbumName)

        return galleries
            .filter { gallery in
                guard gallery.id != currentGalleryID else { return false }
                if trackedGalleryIDs.contains(gallery.id) {
                    return true
                }
                if let regex = templateRegex {
                    let range = NSRange(gallery.name.startIndex..<gallery.name.endIndex, in: gallery.name)
                    return regex.firstMatch(in: gallery.name, range: range) != nil
                }
                return false
            }
            .map(\.id)
    }

    /// Detaches items from old matching galleries without deleting account-wide items directly.
    /// Account-wide deletion is deferred to `deleteOrphanPhotos(trackedItemIDs:protectedItemIDs:)`,
    /// which only deletes MeuralSync-owned items that are not referenced by any remaining gallery.
    @discardableResult
    public func deletePhotosInOldGalleries(
        currentGalleryID: Int,
        destinationAlbumName: String,
        trackedGalleryIDs: Set<Int> = []
    ) async throws -> [Int] {
        let oldIDs = try await listOldGalleries(
            currentGalleryID: currentGalleryID,
            destinationAlbumName: destinationAlbumName,
            trackedGalleryIDs: trackedGalleryIDs
        )
        for oldID in oldIDs {
            let gallery: MeuralGallery
            do {
                gallery = try await getGallery(id: oldID)
            } catch let err as MeuralAPIError where err.statusCode == 404 {
                continue
            }
            log("Detaching items from old gallery: \(gallery.name) (id: \(gallery.id))")
            for itemID in gallery.itemIds {
                try Task.checkCancellation()
                do {
                    try await deleteGalleryItem(galleryID: gallery.id, itemID: itemID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as URLError where err.code == .cancelled {
                    throw CancellationError()
                } catch let err as MeuralAPIError where err.statusCode == 404 {
                    continue
                } catch {
                    log("Warning: failed detaching item \(itemID) from old gallery \(gallery.id): \(error.localizedDescription)")
                }
            }
        }
        return oldIDs
    }

    /// Deletes orphan items that are no longer in any gallery.
    /// When `trackedItemIDs` is provided, only items uploaded by MeuralSync are eligible for deletion,
    /// protecting any user-uploaded items on the Meural account. `protectedItemIDs` (e.g. items uploaded
    /// in the current sync run) are always excluded from deletion.
    @discardableResult
    public func deleteOrphanPhotos(
        trackedItemIDs: Set<Int>? = nil,
        protectedItemIDs: Set<Int> = []
    ) async throws -> OrphanCleanupResult {
        if let trackedItemIDs, trackedItemIDs.subtracting(protectedItemIDs).isEmpty {
            return OrphanCleanupResult(deletedCount: 0, prunedItemIDs: [])
        }

        let galleries = try await getGalleries()
        var galleryItemIDs = Set<Int>()
        for gallery in galleries {
            galleryItemIDs.formUnion(gallery.itemIds)
        }

        if !galleries.isEmpty && galleryItemIDs.isEmpty {
            log("Skipping orphan cleanup: gallery list returned no itemIds (safety guard).")
            return OrphanCleanupResult(deletedCount: 0, prunedItemIDs: [])
        }

        let candidateIDs: [Int]
        if let trackedItemIDs {
            candidateIDs = trackedItemIDs.subtracting(protectedItemIDs).sorted()
        } else {
            guard !galleries.isEmpty else {
                log("Skipping orphan cleanup: no galleries found (safety guard).")
                return OrphanCleanupResult(deletedCount: 0, prunedItemIDs: [])
            }
            var allItemIDs: [Int] = []
            var page = 1
            while page <= 200 {
                let items = try await getItems(count: 100, page: page)
                if items.isEmpty { break }
                allItemIDs.append(contentsOf: items.map(\.id))
                if items.count < 100 { break }
                page += 1
            }
            candidateIDs = allItemIDs.filter { !protectedItemIDs.contains($0) }
        }

        let orphanIDs = candidateIDs.filter { !galleryItemIDs.contains($0) }
        log("\(orphanIDs.count) orphan items to delete")
        var deletedCount = 0
        var prunedItemIDs = Set<Int>()
        for itemID in orphanIDs {
            try Task.checkCancellation()
            do {
                try await deleteItem(id: itemID)
                deletedCount += 1
                prunedItemIDs.insert(itemID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as URLError where err.code == .cancelled {
                throw CancellationError()
            } catch let err as MeuralAPIError where err.statusCode == 404 {
                // Already gone on server — prune from local tracking so we stop retrying it.
                prunedItemIDs.insert(itemID)
            } catch {
                log("Warning: failed deleting orphan item \(itemID): \(error.localizedDescription)")
            }
        }
        return OrphanCleanupResult(deletedCount: deletedCount, prunedItemIDs: prunedItemIDs)
    }

    // MARK: - Request Execution, 401 Handling & Retry

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token {
            req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func performAuthenticated(
        policy: RetryPolicy,
        buildRequest: () throws -> URLRequest
    ) async throws -> Data {
        try await ensureAuthenticated()

        var attempt = 1
        while true {
            do {
                return try await executeWith401Recovery(buildRequest: buildRequest)
            } catch {
                let isTransient = Self.isTransientError(error)
                if !isTransient || attempt >= policy.maxAttempts {
                    throw error
                }
                let delay = policy.delay(forAttempt: attempt, randomUnit: randomUnit())
                log("Transient Meural error (attempt \(attempt)/\(policy.maxAttempts)); retrying in \(Int(delay.rounded()))s: \(error.localizedDescription)")
                try await sleepHandler(delay)
                attempt += 1
            }
        }
    }

    private func executeWith401Recovery(buildRequest: () throws -> URLRequest) async throws -> Data {
        do {
            return try await executeOnce(buildRequest())
        } catch let error as MeuralAPIError where error.statusCode == 401 {
            log("Token expired (HTTP 401), re-authenticating...")
            credentialStore.clearCachedToken(for: instanceName)
            token = nil
            try await reauthenticate()
            return try await executeOnce(buildRequest())
        }
    }

    private func executeOnce(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500) ?? ""
            let method = request.httpMethod ?? "GET"
            let url = request.url?.absoluteString ?? ""
            let err = MeuralAPIError.httpError(
                statusCode: response.statusCode,
                method: method,
                url: url,
                body: String(body)
            )
            logger.error("\(err.localizedDescription, privacy: .public)")
            throw err
        }
        return data
    }

    public static func isTransientError(_ error: Error) -> Bool {
        if let apiError = error as? MeuralAPIError {
            return apiError.isTransient
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                 .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        logHandler(message)
    }
}
