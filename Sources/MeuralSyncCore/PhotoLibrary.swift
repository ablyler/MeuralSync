import Foundation

/// Abstraction over the macOS Photos library so `SyncEngine` can use native PhotoKit
/// (without requiring Full Disk Access) or a test double.
public protocol PhotoLibraryProviding: Sendable {
    func fetchAllPersonNames() async throws -> [String]
    func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata]
    func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata]
}

public extension PhotoLibraryProviding {
    func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] {
        photos
    }
}
