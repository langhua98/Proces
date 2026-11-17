import Photos
import UIKit

enum PhotoLibrary {
    static func saveVideo(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SimpleError("没有相册权限，请在「设置」里允许帧工坊添加照片")
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// 把照片存到一个新相簿里（没有完整相册权限时直接存到「最近项目」）
    static func saveImages(_ urls: [URL], album: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            try await PHPhotoLibrary.shared().performChanges {
                let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
                var placeholders: [PHObjectPlaceholder] = []
                for u in urls {
                    if let p = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u)?.placeholderForCreatedAsset {
                        placeholders.append(p)
                    }
                }
                albumRequest.addAssets(placeholders as NSArray)
            }
        case .limited:
            try await PHPhotoLibrary.shared().performChanges {
                for u in urls { _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u) }
            }
        default:
            throw SimpleError("没有相册权限，请在「设置」里允许帧工坊访问照片")
        }
    }
}
