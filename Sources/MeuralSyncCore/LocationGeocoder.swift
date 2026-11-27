import CoreLocation
import Foundation
import OSLog

/// On-demand reverse geocoder with a persistent disk cache keyed by rounded coordinates.
/// Designed to geocode only the ~100 selected photos per sync rather than the entire Photos library.
public actor LocationGeocoder {
    private struct CachedPlace: Codable {
        let placeName: String?
        let areasOfInterest: [String]
    }

    private let cacheURL: URL
    private let minRequestInterval: TimeInterval
    private let logger = Logger(subsystem: "com.ablyler.MeuralSync", category: "LocationGeocoder")
    private var cache: [String: CachedPlace]
    private var lastRequestTime: Date?
    private var isDirty = false

    public static var defaultCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MeuralSync", isDirectory: true)
            .appendingPathComponent("location_cache.json")
    }

    public init(
        cacheURL: URL = LocationGeocoder.defaultCacheURL,
        minRequestInterval: TimeInterval = 1.25
    ) {
        self.cacheURL = cacheURL
        self.minRequestInterval = minRequestInterval
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: CachedPlace].self, from: data)
        {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    /// Enriches only photos that have coordinates but no `placeName` yet.
    public func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] {
        var result: [PhotoMetadata] = []
        result.reserveCapacity(photos.count)

        for photo in photos {
            if Task.isCancelled {
                result.append(photo)
                continue
            }
            if photo.placeName != nil {
                result.append(photo)
                continue
            }
            guard let lat = photo.latitude, let lon = photo.longitude else {
                result.append(photo)
                continue
            }
            if let info = await reverseGeocode(latitude: lat, longitude: lon) {
                result.append(photo.withLocation(placeName: info.placeName, areasOfInterest: info.areasOfInterest))
            } else {
                result.append(photo)
            }
        }

        if isDirty {
            persistCache()
        }
        return result
    }

    public func reverseGeocode(latitude: Double, longitude: Double) async -> ReverseLocationInfo? {
        let key = Self.coordinateKey(latitude: latitude, longitude: longitude)
        if let cached = cache[key] {
            return ReverseLocationInfo(placeName: cached.placeName, areasOfInterest: cached.areasOfInterest)
        }

        // Throttle uncached requests to stay well under Apple's ~50 req/min CLGeocoder limit.
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minRequestInterval {
                let wait = minRequestInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        if Task.isCancelled { return nil }

        lastRequestTime = Date()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            let info = Self.extractLocationInfo(from: placemark)
            cache[key] = CachedPlace(placeName: info.placeName, areasOfInterest: info.areasOfInterest)
            isDirty = true
            return info
        } catch {
            logger.debug("Reverse geocode failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func coordinateKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    private static func extractLocationInfo(from placemark: CLPlacemark) -> ReverseLocationInfo {
        let areasOfInterest = (placemark.areasOfInterest ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parts: [String] = []
        if let aoi = areasOfInterest.first {
            parts.append(aoi)
        }
        if let city = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines),
           !city.isEmpty, !parts.contains(city)
        {
            parts.append(city)
        }
        if let state = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines),
           !state.isEmpty, !parts.contains(state)
        {
            parts.append(state)
        }
        if let country = placemark.country?.trimmingCharacters(in: .whitespacesAndNewlines),
           !country.isEmpty, !parts.contains(country)
        {
            parts.append(country)
        }

        let placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
        return ReverseLocationInfo(placeName: placeName, areasOfInterest: areasOfInterest)
    }

    private func persistCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            isDirty = false
        } catch {
            logger.warning("Failed to persist location cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
