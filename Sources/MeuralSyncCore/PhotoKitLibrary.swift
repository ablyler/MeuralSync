import CoreLocation
import Foundation
import ObjectiveC.runtime
import OSLog
import Photos

public enum PhotoLibraryMetadataError: Error, LocalizedError, Sendable {
    case peopleFilterUnavailable
    case curationFilterUnavailable
    case albumNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .peopleFilterUnavailable:
            return "People filtering requires Full Disk Access (Apple restricts PhotoKit People access for third-party apps). Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access, or clear People filters to sync with PhotoKit only."
        case .curationFilterUnavailable:
            return "A minimum curation score filter is configured, but PhotoKit curation score metadata is unavailable on this version of macOS."
        case .albumNotFound(let label):
            return "Photos album '\(label)' could not be found in your Apple Photos library."
        }
    }
}

/// Native PhotoKit-backed photo library provider.
/// Eliminates direct `Photos.sqlite` reads and Full Disk Access requirements by using
/// `PHAsset` for enumeration/filtering, runtime-guarded PhotoKit selectors for People (`PHPerson`)
/// and Apple's curation score (`curationScore`), and on-demand cached reverse geocoding for locations.
public final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {
    private let geocoder: LocationGeocoder
    private let logger = Logger(subsystem: "com.ablyler.MeuralSync", category: "PhotoKitLibrary")

    public init(geocoder: LocationGeocoder = LocationGeocoder()) {
        self.geocoder = geocoder
    }

    public static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Returns true if the current macOS Photos.framework exposes `PHPerson` batch fetching.
    public static var supportsPeopleMetadata: Bool {
        guard let personClass = NSClassFromString("PHPerson") as? NSObject.Type else { return false }
        let groupedSel = NSSelectorFromString("fetchPersonsGroupedByAssetLocalIdentifierForAssets:options:")
        let listSel = NSSelectorFromString("fetchPersonsWithOptions:")
        return personClass.responds(to: groupedSel) && personClass.responds(to: listSel)
    }

    /// Lists all named people in the System Photo Library (sorted alphabetically).
    /// Tries PhotoKit first, falling back to a lightweight read-only `Photos.sqlite` people lookup if Full Disk Access is granted.
    public func fetchAllPersonNames() async throws -> [String] {
        try requireAuthorized()
        let photoKitNames = Self.fetchAllPersonNamesSync()
        if !photoKitNames.isEmpty {
            return photoKitNames
        }
        if let sqliteNames = try? PhotosDatabase().fetchAllPersonNames(), !sqliteNames.isEmpty {
            return sqliteNames
        }
        return []
    }

    /// Lists all user & shared albums in the System Photo Library (sorted alphabetically).
    public func fetchAllAlbums() async throws -> [PhotoAlbumInfo] {
        try requireAuthorized()
        var albums: [PhotoAlbumInfo] = []
        var seenIDs = Set<String>()

        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  seenIDs.insert(collection.localIdentifier).inserted
            else {
                return
            }
            let count = collection.estimatedAssetCount == NSNotFound
                ? PHAsset.fetchAssets(in: collection, options: nil).count
                : collection.estimatedAssetCount
            albums.append(
                PhotoAlbumInfo(
                    id: collection.localIdentifier,
                    title: title,
                    estimatedCount: count
                )
            )
        }

        return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Fetches photos matching the given query options via PhotoKit.
    public func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata] {
        try requireAuthorized()

        let hasPeopleFilter = !options.includePeople.isEmpty || !options.excludePeople.isEmpty

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = !options.excludeHidden
        fetchOptions.includeAllBurstAssets = false

        let assetsResult: PHFetchResult<PHAsset>
        if let albumID = options.albumIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !albumID.isEmpty {
            let matching = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            if let collection = matching.firstObject {
                if options.excludeMovies {
                    fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                }
                assetsResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else if let albumName = options.albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !albumName.isEmpty,
                      let collection = Self.findAlbum(named: albumName)
            {
                if options.excludeMovies {
                    fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                }
                assetsResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else {
                throw PhotoLibraryMetadataError.albumNotFound(options.albumName ?? albumID)
            }
        } else if let albumName = options.albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !albumName.isEmpty {
            guard let collection = Self.findAlbum(named: albumName) else {
                throw PhotoLibraryMetadataError.albumNotFound(albumName)
            }
            if options.excludeMovies {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            }
            assetsResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        } else if options.excludeMovies {
            assetsResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        } else {
            assetsResult = PHAsset.fetchAssets(with: fetchOptions)
        }

        var candidates: [(asset: PHAsset, score: Double)] = []
        candidates.reserveCapacity(assetsResult.count)

        let curationSelector = NSSelectorFromString("curationScore")
        let aestheticSelector = NSSelectorFromString("overallAestheticScore")
        var checkedScoreSupport = false
        var scoreSelector: Selector?
        var sawNonScreenshotAsset = false

        assetsResult.enumerateObjects { asset, _, _ in
            if options.excludeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) {
                return
            }
            sawNonScreenshotAsset = true

            if !checkedScoreSupport {
                checkedScoreSupport = true
                if asset.responds(to: curationSelector) {
                    scoreSelector = curationSelector
                } else if asset.responds(to: aestheticSelector) {
                    scoreSelector = aestheticSelector
                }
            }

            let score: Double
            if let sel = scoreSelector {
                score = Self.readDoubleProperty(on: asset, selector: sel)
            } else {
                score = 0.0
            }

            if let minScore = options.curationScoreMin, scoreSelector != nil, score < minScore {
                return
            }

            candidates.append((asset: asset, score: score))
        }

        if options.curationScoreMin != nil && sawNonScreenshotAsset && scoreSelector == nil {
            throw PhotoLibraryMetadataError.curationFilterUnavailable
        }

        // Batch-fetch named people via PhotoKit; if macOS blocks PHPerson (NSCocoaErrorDomain 134092),
        // fall back to a lightweight read-only Photos.sqlite people lookup when Full Disk Access is granted.
        let candidateAssets = candidates.map(\.asset)
        let personsByKey: [String: [String]]
        if let photoKitPeople = try? Self.fetchPersonsByAssetLocalIdentifier(
            for: candidateAssets,
            requireSuccess: true
        ) {
            personsByKey = photoKitPeople
        } else if let sqlitePeople = try? PhotosDatabase().fetchPersonsByAssetUUID() {
            personsByKey = sqlitePeople
        } else if hasPeopleFilter {
            throw PhotoLibraryMetadataError.peopleFilterUnavailable
        } else {
            personsByKey = [:]
        }

        let includeSet = Set(options.includePeople)
        let excludeSet = Set(options.excludePeople)

        var results: [PhotoMetadata] = []
        results.reserveCapacity(candidates.count)

        for (asset, score) in candidates {
            let localID = asset.localIdentifier
            let uuid = localID.components(separatedBy: "/").first ?? localID
            // Handle both full localIdentifier ("UUID/L0/001") and bare UUID keys defensively.
            let persons = personsByKey[localID] ?? personsByKey[uuid] ?? []

            if !includeSet.isEmpty && !persons.contains(where: { includeSet.contains($0) }) {
                continue
            }
            if !excludeSet.isEmpty && persons.contains(where: { excludeSet.contains($0) }) {
                continue
            }

            let coord = asset.location?.coordinate

            results.append(
                PhotoMetadata(
                    uuid: uuid,
                    localIdentifier: localID,
                    date: asset.creationDate ?? Date.distantPast,
                    width: asset.pixelWidth,
                    height: asset.pixelHeight,
                    curationScore: score,
                    persons: persons,
                    placeName: nil,
                    areasOfInterest: [],
                    latitude: coord?.latitude,
                    longitude: coord?.longitude
                )
            )
        }

        return results
    }

    /// Reverse-geocodes only the selected photos using a persistent on-disk coordinate cache.
    public func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] {
        await geocoder.enrichLocations(for: photos)
    }

    private static func findAlbum(named title: String) -> PHAssetCollection? {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var match: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if collection.localizedTitle?.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                match = collection
                stop.pointee = true
            }
        }
        return match
    }

    // MARK: - Authorization

    private func requireAuthorized() throws {
        let status = Self.authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw PhotoExportError.photoLibraryUnauthorized(status)
        }
    }

    // MARK: - Runtime-Guarded PhotoKit Metadata Helpers

    private static func readDoubleProperty(on object: NSObject, selector: Selector) -> Double {
        let key = NSStringFromSelector(selector)
        if let number = object.value(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return 0.0
    }

    private static func extractPersonName(from person: AnyObject) -> String? {
        guard let obj = person as? NSObject else { return nil }
        let nameSel = NSSelectorFromString("name")
        if obj.responds(to: nameSel),
           let name = (obj.value(forKey: "name") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        let displaySel = NSSelectorFromString("displayName")
        if obj.responds(to: displaySel),
           let displayName = (obj.value(forKey: "displayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty
        {
            return displayName
        }
        return nil
    }

    private static func fetchAllPersonNamesSync() -> [String] {
        guard let personClass = NSClassFromString("PHPerson") as? NSObject.Type else {
            return []
        }
        let selector = NSSelectorFromString("fetchPersonsWithOptions:")
        guard personClass.responds(to: selector),
              let method = class_getClassMethod(personClass, selector)
        else {
            return []
        }

        typealias FetchPersonsFn = @convention(c) (AnyClass, Selector, PHFetchOptions?) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(method), to: FetchPersonsFn.self)

        let fetchOptions = PHFetchOptions()
        guard let rawResult = fn(personClass, selector, fetchOptions),
              let fetchResult = rawResult as? PHFetchResult<AnyObject>
        else {
            return []
        }

        var uniqueNames = Set<String>()
        fetchResult.enumerateObjects { person, _, _ in
            if let name = extractPersonName(from: person) {
                uniqueNames.insert(name)
            }
        }
        return uniqueNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func fetchPersonsByAssetLocalIdentifier(
        for assets: [PHAsset],
        requireSuccess: Bool
    ) throws -> [String: [String]] {
        guard !assets.isEmpty else { return [:] }
        guard let personClass = NSClassFromString("PHPerson") as? NSObject.Type else {
            if requireSuccess { throw PhotoLibraryMetadataError.peopleFilterUnavailable }
            return [:]
        }

        let selector = NSSelectorFromString("fetchPersonsGroupedByAssetLocalIdentifierForAssets:options:")
        guard personClass.responds(to: selector),
              let method = class_getClassMethod(personClass, selector)
        else {
            if requireSuccess { throw PhotoLibraryMetadataError.peopleFilterUnavailable }
            return [:]
        }

        typealias FetchGroupedFn = @convention(c) (AnyClass, Selector, NSArray, PHFetchOptions?) -> NSDictionary?
        let fn = unsafeBitCast(method_getImplementation(method), to: FetchGroupedFn.self)

        var result: [String: [String]] = [:]
        result.reserveCapacity(assets.count)
        let batchSize = 500
        let fetchOptions = PHFetchOptions()

        for start in stride(from: 0, to: assets.count, by: batchSize) {
            try autoreleasepool {
                let end = min(start + batchSize, assets.count)
                let batch = Array(assets[start..<end]) as NSArray
                guard let dict = fn(personClass, selector, batch, fetchOptions) else {
                    if requireSuccess { throw PhotoLibraryMetadataError.peopleFilterUnavailable }
                    return
                }
                for (key, value) in dict {
                    guard let localID = key as? String,
                          let personsFetch = value as? PHFetchResult<AnyObject>
                    else {
                        if requireSuccess { throw PhotoLibraryMetadataError.peopleFilterUnavailable }
                        continue
                    }
                    var names: [String] = []
                    var seen = Set<String>()
                    personsFetch.enumerateObjects { person, _, _ in
                        if let name = extractPersonName(from: person), seen.insert(name).inserted {
                            names.append(name)
                        }
                    }
                    if !names.isEmpty {
                        result[localID] = names
                    }
                }
            }
        }

        return result
    }
}
