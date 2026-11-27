import Foundation
import Photos

public enum PhotoExportError: Error, LocalizedError, Sendable {
    case photoLibraryUnauthorized(PHAuthorizationStatus)
    case assetNotFound(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .photoLibraryUnauthorized(let status):
            return "Photos library access not authorized (status: \(status.rawValue)). Grant access in System Settings → Privacy & Security → Photos."
        case .assetNotFound(let uuid):
            return "Photo \(uuid) not found in PhotoKit"
        case .exportFailed(let reason):
            return "Failed to export photo: \(reason)"
        }
    }
}

public protocol PhotoExporting: Sendable {
    func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL
}

/// Thread-safe state box to coordinate `PHImageManager` cancellation and single-resume continuation safety.
private final class ImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var cancelled = false
    private var resumed = false

    func setRequestID(_ id: PHImageRequestID) {
        let shouldCancelNow: Bool = lock.withLock {
            requestID = id
            return cancelled
        }
        if shouldCancelNow && id != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    func cancel() {
        let idToCancel: PHImageRequestID = lock.withLock {
            cancelled = true
            return requestID
        }
        if idToCancel != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(idToCancel)
        }
    }

    func tryClaimResume() -> Bool {
        lock.withLock {
            if resumed { return false }
            resumed = true
            return true
        }
    }
}

/// Exports photos via Apple's native `PhotoKit` (`PHImageManager`), automatically downloading
/// iCloud-only originals when needed, without requiring Full Disk Access.
public struct PhotoKitExporter: PhotoExporting {
    public init() {}

    public static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public func exportPhoto(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let status = Self.authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw PhotoExportError.photoLibraryUnauthorized(status)
        }
        return try await exportViaPhotoKit(photo, toDirectory: directory)
    }

    private func exportViaPhotoKit(_ photo: PhotoMetadata, toDirectory directory: URL) async throws -> URL {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photo.localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoExportError.assetNotFound(photo.uuid)
        }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let state = ImageRequestState()

        let (imageData, dataUTI): (Data, String?) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reqID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                    guard state.tryClaimResume() else { return }

                    if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let data else {
                        continuation.resume(throwing: PhotoExportError.exportFailed("Empty image data for \(photo.uuid)"))
                        return
                    }
                    continuation.resume(returning: (data, uti))
                }
                state.setRequestID(reqID)
            }
        } onCancel: {
            state.cancel()
        }

        let ext = (dataUTI?.contains("png") == true) ? "png" : (dataUTI?.contains("heic") == true ? "heic" : "jpg")
        let outputURL = directory.appendingPathComponent("\(photo.uuid).\(ext)")
        try imageData.write(to: outputURL, options: .atomic)
        return outputURL
    }
}
