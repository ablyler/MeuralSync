import Foundation

/// Top-level configuration matching the existing `config.json` format plus app-level schedule settings.
public struct AppConfig: Codable, Sendable, Equatable {
    public var instances: [InstanceConfig]
    public var schedule: ScheduleConfig?

    public init(instances: [InstanceConfig] = [], schedule: ScheduleConfig? = nil) {
        self.instances = instances
        self.schedule = schedule
    }
}

public enum SyncFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case hourly
    case daily
    case weekly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hourly: return "Every N Hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

public struct ScheduleConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var frequency: SyncFrequency
    /// Used when `frequency == .hourly` (1...24).
    public var intervalHours: Int
    /// Used when `frequency == .daily` or `.weekly` (0...23).
    public var hour: Int
    /// Used when `frequency == .daily` or `.weekly` (0...59).
    public var minute: Int
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday), used when `frequency == .weekly`.
    public var weekdays: [Int]

    public init(
        enabled: Bool = true,
        frequency: SyncFrequency = .daily,
        intervalHours: Int = 6,
        hour: Int = 12,
        minute: Int = 0,
        weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    ) {
        self.enabled = enabled
        self.frequency = frequency
        self.intervalHours = max(1, min(24, intervalHours))
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.weekdays = weekdays.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : Array(Set(weekdays)).sorted()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.frequency = try container.decodeIfPresent(SyncFrequency.self, forKey: .frequency) ?? .daily
        self.intervalHours = max(1, min(24, try container.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 6))
        self.hour = max(0, min(23, try container.decodeIfPresent(Int.self, forKey: .hour) ?? 12))
        self.minute = max(0, min(59, try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0))
        let decodedDays = try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? [1, 2, 3, 4, 5, 6, 7]
        self.weekdays = decodedDays.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : Array(Set(decodedDays)).sorted()
    }

    /// Computes the next scheduled sync date strictly after `referenceDate` (or based on `lastRun` for `.hourly`).
    public func nextRunDate(
        after referenceDate: Date = Date(),
        lastRun: Date? = nil,
        calendar: Calendar = .current
    ) -> Date? {
        guard enabled else { return nil }

        switch frequency {
        case .hourly:
            let interval = TimeInterval(max(1, intervalHours) * 3600)
            if let lastRun {
                let candidate = lastRun.addingTimeInterval(interval)
                return candidate > referenceDate ? candidate : referenceDate
            }
            return referenceDate.addingTimeInterval(interval)

        case .daily:
            var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let todayCandidate = calendar.date(from: comps) else { return nil }
            if todayCandidate > referenceDate {
                return todayCandidate
            }
            return calendar.date(byAdding: .day, value: 1, to: todayCandidate)

        case .weekly:
            let validDays = Set(weekdays.filter { (1...7).contains($0) })
            guard !validDays.isEmpty else { return nil }
            var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let todayCandidate = calendar.date(from: comps) else { return nil }

            for offset in 0...7 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: todayCandidate) else {
                    continue
                }
                let weekday = calendar.component(.weekday, from: candidate)
                if validDays.contains(weekday) && candidate > referenceDate {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Returns true if a scheduled sync should run now, given the last completed/triggered scheduled run time.
    public func isDue(
        at now: Date = Date(),
        lastRun: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }

        switch frequency {
        case .hourly:
            guard let lastRun else { return true }
            let interval = TimeInterval(max(1, intervalHours) * 3600)
            return now.timeIntervalSince(lastRun) >= interval

        case .daily, .weekly:
            let validDays: Set<Int>
            if frequency == .weekly {
                validDays = Set(weekdays.filter { (1...7).contains($0) })
                guard !validDays.isEmpty else { return false }
            } else {
                validDays = Set(1...7)
            }

            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let todaySlot = calendar.date(from: comps) else { return false }

            // When no previous run is recorded, only trigger once today's scheduled time is reached on a valid day.
            guard let lastRun else {
                let todayWeekday = calendar.component(.weekday, from: now)
                return validDays.contains(todayWeekday) && now >= todaySlot
            }

            // Catch up across missed days (e.g. Mac asleep overnight or over a weekend):
            // find the most recent scheduled slot <= now within the past 7 days.
            for offset in 0...7 {
                guard let candidate = calendar.date(byAdding: .day, value: -offset, to: todaySlot) else {
                    continue
                }
                guard candidate <= now else { continue }
                let weekday = calendar.component(.weekday, from: candidate)
                if validDays.contains(weekday) {
                    return lastRun < candidate
                }
            }
            return false
        }
    }
}

public struct PeopleFilter: Codable, Sendable, Equatable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.include = try container.decodeIfPresent([String].self, forKey: .include) ?? []
        self.exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }
}

public enum FrameOrientation: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case portrait
    case landscape

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (from Meural)"
        case .portrait: return "Portrait (1080×1920)"
        case .landscape: return "Landscape (1920×1080)"
        }
    }
}

public enum CanvasOrientation: String, Codable, Sendable, Equatable {
    case portrait
    case landscape

    public var canvasWidth: Int {
        self == .portrait ? 1080 : 1920
    }

    public var canvasHeight: Int {
        self == .portrait ? 1920 : 1080
    }

    /// Orientation string expected by the Meural API (`vertical` or `horizontal`).
    public var meuralAPIOrientation: String {
        self == .portrait ? "vertical" : "horizontal"
    }

    public var displayName: String {
        self == .portrait ? "Portrait" : "Landscape"
    }
}

public struct InstanceConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID

    public var name: String
    public var enabled: Bool
    public var sendToDevices: Bool
    public var frameOrientation: FrameOrientation
    public var photoCount: Int
    public var photoScoreCurationMin: Double?
    public var onThisDayPercent: Int?
    public var onThisDayCount: Int?
    public var onThisDayWindowDays: Int
    public var people: PeopleFilter
    public var destinationAlbumName: String
    public var randomizeGalleryName: Bool
    public var captionLocationAliases: [String: String]
    public var captionPersonAliases: [String: String]
    public var maxConsecutiveUploadFailures: Int
    public var uploadIntervalSeconds: Double

    /// Stable key for Keychain & sync state storage.
    public var storageKey: String { id.uuidString }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case sendToDevices = "send_to_devices"
        case frameOrientation = "frame_orientation"
        case photoCount = "photo_count"
        case photoScoreCurationMin = "photo_score_curation_min"
        case onThisDayPercent = "on_this_day_percent"
        case onThisDayCount = "on_this_day_count"
        case onThisDayWindowDays = "on_this_day_window_days"
        case people
        case destinationAlbumName = "destination_album_name"
        case randomizeGalleryName = "randomize_gallery_name"
        case captionLocationAliases = "caption_location_aliases"
        case captionPersonAliases = "caption_person_aliases"
        case maxConsecutiveUploadFailures = "max_consecutive_upload_failures"
        case uploadIntervalSeconds = "upload_interval_seconds"
    }

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        sendToDevices: Bool = true,
        frameOrientation: FrameOrientation = .auto,
        photoCount: Int = 100,
        photoScoreCurationMin: Double? = 0.5,
        onThisDayPercent: Int? = 20,
        onThisDayCount: Int? = nil,
        onThisDayWindowDays: Int = 3,
        people: PeopleFilter = PeopleFilter(),
        destinationAlbumName: String = "Family Photos - :date:",
        randomizeGalleryName: Bool = true,
        captionLocationAliases: [String: String] = [:],
        captionPersonAliases: [String: String] = [:],
        maxConsecutiveUploadFailures: Int = 3,
        uploadIntervalSeconds: Double = 10
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sendToDevices = sendToDevices
        self.frameOrientation = frameOrientation
        self.photoCount = max(1, min(1000, photoCount))
        self.photoScoreCurationMin = photoScoreCurationMin.map { max(0.0, min(1.0, $0)) }
        self.onThisDayPercent = onThisDayPercent.map { max(0, min(100, $0)) }
        self.onThisDayCount = onThisDayCount.map { max(0, $0) }
        self.onThisDayWindowDays = max(0, min(30, onThisDayWindowDays))
        self.people = people
        self.destinationAlbumName = destinationAlbumName
        self.randomizeGalleryName = randomizeGalleryName
        self.captionLocationAliases = captionLocationAliases
        self.captionPersonAliases = captionPersonAliases
        self.maxConsecutiveUploadFailures = max(1, min(50, maxConsecutiveUploadFailures))
        self.uploadIntervalSeconds = max(0, min(300, uploadIntervalSeconds))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.sendToDevices = try container.decodeIfPresent(Bool.self, forKey: .sendToDevices) ?? false
        self.frameOrientation = try container.decodeIfPresent(FrameOrientation.self, forKey: .frameOrientation) ?? .auto
        let rawPhotoCount = try container.decodeIfPresent(Int.self, forKey: .photoCount) ?? 100
        self.photoCount = max(1, min(1000, rawPhotoCount))
        self.photoScoreCurationMin = (try container.decodeIfPresent(Double.self, forKey: .photoScoreCurationMin))
            .map { max(0.0, min(1.0, $0)) }
        self.onThisDayPercent = (try container.decodeIfPresent(Int.self, forKey: .onThisDayPercent))
            .map { max(0, min(100, $0)) }
        self.onThisDayCount = (try container.decodeIfPresent(Int.self, forKey: .onThisDayCount))
            .map { max(0, $0) }
        let rawWindow = try container.decodeIfPresent(Int.self, forKey: .onThisDayWindowDays) ?? 3
        self.onThisDayWindowDays = max(0, min(30, rawWindow))
        self.people = try container.decodeIfPresent(PeopleFilter.self, forKey: .people) ?? PeopleFilter()
        self.destinationAlbumName = try container.decodeIfPresent(String.self, forKey: .destinationAlbumName) ?? "Family Photos - :date:"
        self.randomizeGalleryName = try container.decodeIfPresent(Bool.self, forKey: .randomizeGalleryName) ?? false
        self.captionLocationAliases = try container.decodeIfPresent([String: String].self, forKey: .captionLocationAliases) ?? [:]
        self.captionPersonAliases = try container.decodeIfPresent([String: String].self, forKey: .captionPersonAliases) ?? [:]
        let rawMaxFailures = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveUploadFailures) ?? 3
        self.maxConsecutiveUploadFailures = max(1, min(50, rawMaxFailures))
        let rawInterval = try container.decodeIfPresent(Double.self, forKey: .uploadIntervalSeconds) ?? 10
        self.uploadIntervalSeconds = rawInterval.isFinite ? max(0, min(300, rawInterval)) : 10
    }

    /// Computes how many slots to reserve for "On This Day" photos.
    public var resolvedOnThisDayCount: Int {
        if let count = onThisDayCount {
            return max(0, count)
        }
        if let percent = onThisDayPercent {
            return max(0, Int(Double(photoCount * percent) / 100.0))
        }
        return 0
    }
}

/// Metadata for a single photo from the macOS Photos library.
public struct PhotoMetadata: Sendable, Equatable, Identifiable {
    public var id: String { uuid }

    public let uuid: String
    public let localIdentifier: String
    public let date: Date
    public let width: Int
    public let height: Int
    public let curationScore: Double
    public let persons: [String]
    public let placeName: String?
    public let areasOfInterest: [String]
    public let latitude: Double?
    public let longitude: Double?
    public let directory: String?
    public let filename: String?

    public init(
        uuid: String,
        localIdentifier: String? = nil,
        date: Date,
        width: Int,
        height: Int,
        curationScore: Double = 0.0,
        persons: [String] = [],
        placeName: String? = nil,
        areasOfInterest: [String] = [],
        latitude: Double? = nil,
        longitude: Double? = nil,
        directory: String? = nil,
        filename: String? = nil
    ) {
        self.uuid = uuid
        self.localIdentifier = localIdentifier ?? "\(uuid)/L0/001"
        self.date = date
        self.width = width
        self.height = height
        self.curationScore = curationScore
        self.persons = persons
        self.placeName = placeName
        self.areasOfInterest = areasOfInterest
        self.latitude = latitude
        self.longitude = longitude
        self.directory = directory
        self.filename = filename
    }

    public func withLocation(placeName: String?, areasOfInterest: [String]) -> PhotoMetadata {
        PhotoMetadata(
            uuid: uuid,
            localIdentifier: localIdentifier,
            date: date,
            width: width,
            height: height,
            curationScore: curationScore,
            persons: persons,
            placeName: placeName,
            areasOfInterest: areasOfInterest,
            latitude: latitude,
            longitude: longitude,
            directory: directory,
            filename: filename
        )
    }

    public var isPortrait: Bool {
        height > width
    }
}
