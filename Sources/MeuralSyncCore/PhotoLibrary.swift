import Foundation

/// Lightweight descriptor for an Apple Photos album.
public struct PhotoAlbumInfo: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let estimatedCount: Int

    public init(id: String, title: String, estimatedCount: Int = 0) {
        self.id = id
        self.title = title
        self.estimatedCount = estimatedCount
    }
}

/// Abstraction over the macOS Photos library so `SyncEngine` can use native PhotoKit
/// (without requiring Full Disk Access) or a test double.
public protocol PhotoLibraryProviding: Sendable {
    func fetchAllPersonNames() async throws -> [String]
    func fetchAllAlbums() async throws -> [PhotoAlbumInfo]
    func queryPhotos(options: PhotosQueryOptions) async throws -> [PhotoMetadata]
    func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata]
}

public extension PhotoLibraryProviding {
    func fetchAllAlbums() async throws -> [PhotoAlbumInfo] {
        []
    }

    func enrichLocations(for photos: [PhotoMetadata]) async -> [PhotoMetadata] {
        photos
    }
}
