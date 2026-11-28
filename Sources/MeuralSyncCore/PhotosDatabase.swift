import Foundation
import SQLite3

public enum PhotosDatabaseError: Error, LocalizedError, Sendable {
    case libraryNotFound(URL)
    case accessDenied(URL)
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound(let url):
            return "Photos database not found at \(url.path)"
        case .accessDenied(let url):
            return "Full Disk Access is required to read \(url.path). Enable it in System Settings → Privacy & Security → Full Disk Access."
        case .openFailed(let message):
            return "Failed to open Photos.sqlite: \(message)"
        case .queryFailed(let message):
            return "SQLite query failed: \(message)"
        }
    }
}

public struct PhotosQueryOptions: Sendable, Equatable {
    public var includePeople: [String]
    public var excludePeople: [String]
    public var albumIdentifier: String?
    public var albumName: String?
    public var curationScoreMin: Double?
    public var excludeScreenshots: Bool
    public var excludeMovies: Bool
    public var excludeHidden: Bool

    public init(
        includePeople: [String] = [],
        excludePeople: [String] = [],
        albumIdentifier: String? = nil,
        albumName: String? = nil,
        curationScoreMin: Double? = nil,
        excludeScreenshots: Bool = true,
        excludeMovies: Bool = true,
        excludeHidden: Bool = true
    ) {
        self.includePeople = includePeople
        self.excludePeople = excludePeople
        self.albumIdentifier = albumIdentifier
        self.albumName = albumName
        self.curationScoreMin = curationScoreMin
        self.excludeScreenshots = excludeScreenshots
        self.excludeMovies = excludeMovies
        self.excludeHidden = excludeHidden
    }
}

public struct ReverseLocationInfo: Sendable, Equatable {
    public let placeName: String?
    public let areasOfInterest: [String]

    public init(placeName: String?, areasOfInterest: [String]) {
        self.placeName = placeName
        self.areasOfInterest = areasOfInterest
    }
}

/// Legacy read-only reader for Apple Photos' `Photos.sqlite` database.
/// Prefer `PhotoKitLibrary` for normal app operation (no Full Disk Access required).
public final class PhotosDatabase: PhotoLibraryProviding, Sendable {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
    }

    public let databaseURL: URL

    public init(databaseURL: URL = PhotosDatabase.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// Checks whether the current process has Full Disk Access to read `Photos.sqlite`.
    public static func hasFullDiskAccess(databaseURL: URL = defaultDatabaseURL) -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return false
        }
        var db: OpaquePointer?
        let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if db != nil { sqlite3_close(db) } }
        guard rc == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        return prep == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Lists all named people in the Photos library (sorted alphabetically) for UI pickers.
    public func fetchAllPersonNames() throws -> [String] {
        try withReadOnlyDB { db in
            let sql = """
            SELECT DISTINCT COALESCE(NULLIF(TRIM(ZFULLNAME), ''), NULLIF(TRIM(ZDISPLAYNAME), '')) AS name
            FROM ZPERSON
            WHERE name IS NOT NULL AND name != ''
            ORDER BY name COLLATE NOCASE ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PhotosDatabaseError.queryFailed(Self.lastError(db))
            }
            defer { sqlite3_finalize(stmt) }

            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    names.append(String(cString: cStr))
                }
            }
            return names
        }
    }

    /// Lightweight lookup returning `[assetUUID: [personName]]` from `ZDETECTEDFACE`/`ZPERSON`
    /// so `PhotoKitLibrary` can enrich PhotoKit assets with People names when macOS blocks `PHPerson`.
    public func fetchPersonsByAssetUUID() throws -> [String: [String]] {
        try withReadOnlyDB { db in
            guard Self.tableExists(db, name: "ZDETECTEDFACE") && Self.tableExists(db, name: "ZPERSON") else {
                return [:]
            }
            let assetTable = Self.tableExists(db, name: "ZASSET") ? "ZASSET" : "ZGENERICASSET"
            let faceColumns = Self.tableColumns(db, table: "ZDETECTEDFACE")
            let facePersonCol = Self.firstMatchingColumn(
                in: faceColumns,
                candidates: ["ZPERSONFORFACE", "ZPERSON", "ZPERSONBEINGKEYFACE"]
            ) ?? "ZPERSON"
            let faceAssetCol = Self.firstMatchingColumn(
                in: faceColumns,
                candidates: ["ZASSETFORFACE", "ZASSET"]
            ) ?? "ZASSET"

            let sql = """
            SELECT a.ZUUID,
                   COALESCE(NULLIF(TRIM(p.ZFULLNAME), ''), NULLIF(TRIM(p.ZDISPLAYNAME), ''))
            FROM ZDETECTEDFACE df
            JOIN ZPERSON p ON df.\(facePersonCol) = p.Z_PK
            JOIN \(assetTable) a ON df.\(faceAssetCol) = a.Z_PK
            WHERE a.ZUUID IS NOT NULL
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PhotosDatabaseError.queryFailed(Self.lastError(db))
            }
            defer { sqlite3_finalize(stmt) }

            var result: [String: [String]] = [:]
            var seenByUUID: [String: Set<String>] = [:]
            var stepRC = sqlite3_step(stmt)
            while stepRC == SQLITE_ROW {
                defer { stepRC = sqlite3_step(stmt) }
                guard let uuidCStr = sqlite3_column_text(stmt, 0),
                      let nameCStr = sqlite3_column_text(stmt, 1)
                else { continue }
                let uuid = String(cString: uuidCStr)
                let name = String(cString: nameCStr)
                if !name.isEmpty && seenByUUID[uuid, default: []].insert(name).inserted {
                    result[uuid, default: []].append(name)
                }
            }
            guard stepRC == SQLITE_DONE else {
                throw PhotosDatabaseError.queryFailed(Self.lastError(db))
            }
            return result
        }
    }

    /// Fetches photos matching the given query options.
    public func queryPhotos(options: PhotosQueryOptions) throws -> [PhotoMetadata] {
        try withReadOnlyDB { db in
            let assetTable = Self.tableExists(db, name: "ZASSET") ? "ZASSET" : "ZGENERICASSET"
            let faceColumns = Self.tableColumns(db, table: "ZDETECTEDFACE")
            let assetColumns = Self.tableColumns(db, table: assetTable)

            let facePersonCol = Self.firstMatchingColumn(
                in: faceColumns,
                candidates: ["ZPERSONFORFACE", "ZPERSON", "ZPERSONBEINGKEYFACE"]
            ) ?? "ZPERSON"
            let faceAssetCol = Self.firstMatchingColumn(
                in: faceColumns,
                candidates: ["ZASSETFORFACE", "ZASSET"]
            ) ?? "ZASSET"

            // 1. Load person names keyed by asset Z_PK
            var personsByAssetPK: [Int64: [String]] = [:]
            if Self.tableExists(db, name: "ZDETECTEDFACE") && Self.tableExists(db, name: "ZPERSON") {
                let faceSQL = """
                SELECT df.\(faceAssetCol),
                       COALESCE(NULLIF(TRIM(p.ZFULLNAME), ''), NULLIF(TRIM(p.ZDISPLAYNAME), ''))
                FROM ZDETECTEDFACE df
                JOIN ZPERSON p ON df.\(facePersonCol) = p.Z_PK
                WHERE df.\(faceAssetCol) IS NOT NULL
                """
                var faceStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, faceSQL, -1, &faceStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(faceStmt) }
                    while sqlite3_step(faceStmt) == SQLITE_ROW {
                        let assetPK = sqlite3_column_int64(faceStmt, 0)
                        if let cStr = sqlite3_column_text(faceStmt, 1) {
                            let name = String(cString: cStr)
                            if !name.isEmpty {
                                personsByAssetPK[assetPK, default: []].append(name)
                            }
                        }
                    }
                }
            }

            // 2. Query assets joined with ZADDITIONALASSETATTRIBUTES
            let hasCuration = assetColumns.contains("ZCURATIONSCORE")
            let hasKindSubtype = assetColumns.contains("ZKINDSUBTYPE")
            let hasTrashedState = assetColumns.contains("ZTRASHEDSTATE")
            let hasVisibilityState = assetColumns.contains("ZVISIBILITYSTATE")
            let hasAdditionalAttr = assetColumns.contains("ZADDITIONALATTRIBUTES")
                && Self.tableExists(db, name: "ZADDITIONALASSETATTRIBUTES")

            let curationExpr = hasCuration ? "a.ZCURATIONSCORE" : "0.0"
            let subtypeExpr = hasKindSubtype ? "a.ZKINDSUBTYPE" : "0"
            let revGeoExpr = hasAdditionalAttr ? "aa.ZREVERSELOCATIONDATA" : "NULL"
            let joinClause = hasAdditionalAttr
                ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON a.ZADDITIONALATTRIBUTES = aa.Z_PK"
                : ""

            var whereClauses: [String] = ["a.ZUUID IS NOT NULL"]
            if options.excludeMovies {
                whereClauses.append("a.ZKIND = 0") // 0 = photo, 1 = video
            }
            if options.excludeHidden {
                whereClauses.append("(a.ZHIDDEN IS NULL OR a.ZHIDDEN = 0)")
            }
            if hasTrashedState {
                whereClauses.append("(a.ZTRASHEDSTATE IS NULL OR a.ZTRASHEDSTATE = 0)")
            }
            if hasVisibilityState {
                whereClauses.append("(a.ZVISIBILITYSTATE IS NULL OR a.ZVISIBILITYSTATE = 0)")
            }
            if options.excludeScreenshots && hasKindSubtype {
                // In Photos.sqlite, ZKINDSUBTYPE == 10 is screenshot (PHAssetMediaSubtypePhotoScreenshot)
                whereClauses.append("(a.ZKINDSUBTYPE IS NULL OR a.ZKINDSUBTYPE != 10)")
            }
            var bindCurationMin: Double?
            if let minScore = options.curationScoreMin, minScore.isFinite, hasCuration {
                whereClauses.append("COALESCE(a.ZCURATIONSCORE, 0.0) >= ?")
                bindCurationMin = minScore
            }

            let sql = """
            SELECT a.Z_PK,
                   a.ZUUID,
                   a.ZDATECREATED,
                   a.ZWIDTH,
                   a.ZHEIGHT,
                   \(curationExpr),
                   \(subtypeExpr),
                   a.ZDIRECTORY,
                   a.ZFILENAME,
                   \(revGeoExpr)
            FROM \(assetTable) a
            \(joinClause)
            WHERE \(whereClauses.joined(separator: " AND "))
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PhotosDatabaseError.queryFailed(Self.lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            if let bindCurationMin {
                sqlite3_bind_double(stmt, 1, bindCurationMin)
            }

            let includeSet = Set(options.includePeople)
            let excludeSet = Set(options.excludePeople)
            var results: [PhotoMetadata] = []

            var stepRC = sqlite3_step(stmt)
            while stepRC == SQLITE_ROW {
                defer { stepRC = sqlite3_step(stmt) }
                let pk = sqlite3_column_int64(stmt, 0)
                guard let uuidCStr = sqlite3_column_text(stmt, 1) else { continue }
                let uuid = String(cString: uuidCStr)

                let persons = personsByAssetPK[pk] ?? []

                // Person include filter: match photos where any listed person appears.
                if !includeSet.isEmpty && !persons.contains(where: { includeSet.contains($0) }) {
                    continue
                }
                // Person exclude filter: none of the excluded people may appear.
                if !excludeSet.isEmpty && persons.contains(where: { excludeSet.contains($0) }) {
                    continue
                }

                let dateCreated = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                    ? Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
                    : Date.distantPast
                let width = Int(sqlite3_column_int(stmt, 3))
                let height = Int(sqlite3_column_int(stmt, 4))
                let curationScore = sqlite3_column_double(stmt, 5)
                let directory = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let filename = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

                var placeName: String?
                var areasOfInterest: [String] = []
                if let blobPtr = sqlite3_column_blob(stmt, 9) {
                    let blobLen = Int(sqlite3_column_bytes(stmt, 9))
                    if blobLen > 0 {
                        let data = Data(bytes: blobPtr, count: blobLen)
                        if let revGeo = Self.parseReverseLocationData(data) {
                            placeName = revGeo.placeName
                            areasOfInterest = revGeo.areasOfInterest
                        }
                    }
                }

                results.append(
                    PhotoMetadata(
                        uuid: uuid,
                        date: dateCreated,
                        width: width,
                        height: height,
                        curationScore: curationScore,
                        persons: persons,
                        placeName: placeName,
                        areasOfInterest: areasOfInterest,
                        directory: directory,
                        filename: filename
                    )
                )
            }

            guard stepRC == SQLITE_DONE else {
                throw PhotosDatabaseError.queryFailed(Self.lastError(db))
            }

            return results
        }
    }

    // MARK: - ZREVERSELOCATIONDATA Binary Plist / NSKeyedArchiver Parser

    /// Parses Apple Photos' `ZREVERSELOCATIONDATA` (`NSKeyedArchiver` binary plist for `PLRevGeoLocationInfo`)
    /// without relying on private framework classes by traversing the `$objects` graph directly.
    public static func parseReverseLocationData(_ data: Data) -> ReverseLocationInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any]
        else {
            return nil
        }

        func resolveUID(_ value: Any?) -> Any? {
            guard let value else { return nil }
            // CFKeyedArchiverUID bridges in Swift as an opaque object whose description contains `{value = N}`
            // or can be decoded via KeyedArchiverUID inspection.
            if let index = extractUIDIndex(value), index >= 0, index < objects.count {
                let target = objects[index]
                if let str = target as? String, str == "$null" {
                    return nil
                }
                return target
            }
            return value
        }

        func resolveArray(_ value: Any?) -> [Any] {
            guard let dict = resolveUID(value) as? [String: Any],
                  let rawItems = dict["NS.objects"] as? [Any]
            else {
                return []
            }
            return rawItems.compactMap { resolveUID($0) }
        }

        guard let root = resolveUID(top["root"]) as? [String: Any] else {
            return nil
        }

        var byPlaceType: [Int: [(name: String, area: Double)]] = [:]
        if let mapItem = resolveUID(root["mapItem"]) as? [String: Any] {
            let placeInfos = resolveArray(mapItem["sortedPlaceInfos"]) + resolveArray(mapItem["finalPlaceInfos"])
            var seen = Set<String>()
            for item in placeInfos {
                guard let infoDict = item as? [String: Any],
                      let name = resolveUID(infoDict["name"]) as? String,
                      !name.isEmpty,
                      let placeType = infoDict["placeType"] as? Int
                else {
                    continue
                }
                let area = (infoDict["area"] as? Double) ?? 0.0
                let dedupeKey = "\(placeType)|\(name)"
                if seen.insert(dedupeKey).inserted {
                    byPlaceType[placeType, default: []].append((name: name, area: area))
                }
            }
        }

        func sortedNames(for placeType: Int) -> [String] {
            (byPlaceType[placeType] ?? [])
                .sorted { $0.area < $1.area }
                .map(\.name)
        }

        // Apple PLRevGeoMapItemAdditionalPlaceInfo placeType codes:
        // 1 = country, 2 = state/province, 4 = city, 6 = subLocality, 8 = area_of_interest
        let areasOfInterest = sortedNames(for: 8)
        let city = sortedNames(for: 4).first
        let state = sortedNames(for: 2).first
        let country = sortedNames(for: 1).first

        var nameParts: [String] = []
        if let aoi = areasOfInterest.first {
            nameParts.append(aoi)
        }
        if let city, !nameParts.contains(city) {
            nameParts.append(city)
        }
        if let state, !nameParts.contains(state) {
            nameParts.append(state)
        }
        if let country, !nameParts.contains(country) {
            nameParts.append(country)
        }

        var placeName: String? = nameParts.isEmpty ? nil : nameParts.joined(separator: ", ")

        // Fallback to compoundNames or addressString if sortedPlaceInfos was empty
        if placeName == nil {
            let compoundNames = resolveArray(root["compoundNames"]).compactMap { $0 as? String }
            if !compoundNames.isEmpty {
                placeName = compoundNames.joined(separator: ", ")
            } else if let addressString = resolveUID(root["addressString"]) as? String, !addressString.isEmpty {
                placeName = addressString
            }
        }

        return ReverseLocationInfo(placeName: placeName, areasOfInterest: areasOfInterest)
    }

    private static func extractUIDIndex(_ value: Any) -> Int? {
        if let dict = value as? [String: Any], let uid = dict["CF$UID"] as? Int {
            return uid
        }
        let desc = String(describing: value)
        // Format: <CFKeyedArchiverUID 0x...>{value = 12}
        guard desc.contains("CFKeyedArchiverUID"),
              let range = desc.range(of: "value = ")
        else {
            return nil
        }
        let tail = desc[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - SQLite Helpers

    private func withReadOnlyDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw PhotosDatabaseError.libraryNotFound(databaseURL)
        }
        var db: OpaquePointer?
        let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let msg = db.map(Self.lastError) ?? "SQLite error \(rc)"
            if db != nil { sqlite3_close(db) }
            if rc == SQLITE_CANTOPEN || rc == SQLITE_PERM || rc == SQLITE_AUTH {
                throw PhotosDatabaseError.accessDenied(databaseURL)
            }
            throw PhotosDatabaseError.openFailed(msg)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        return try body(handle)
    }

    private static func tableExists(_ db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func tableColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var cols = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                cols.insert(String(cString: cStr).uppercased())
            }
        }
        return cols
    }

    private static func firstMatchingColumn(in columns: Set<String>, candidates: [String]) -> String? {
        candidates.first { columns.contains($0.uppercased()) }
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        if let msg = sqlite3_errmsg(db) {
            return String(cString: msg)
        }
        return "Unknown SQLite error"
    }
}
