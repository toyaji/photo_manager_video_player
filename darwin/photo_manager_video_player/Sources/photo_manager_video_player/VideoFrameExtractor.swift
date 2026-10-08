import AVFoundation
import Flutter
import Photos
import UIKit

/// Reads JPEG stills from a library video through the `AVAsset` PhotoKit hands
/// back, so the original is decoded in place instead of exported.
enum VideoFrameExtractor {
    private static let queue = DispatchQueue(
        label: "com.fluttercandies.photo_manager_video_player.frames",
        qos: .userInitiated)

    /// Replies with one `FlutterStandardTypedData` or `NSNull` per time, or a
    /// `FlutterError` when the asset itself cannot be loaded.
    static func extract(
        localIdentifier: String,
        timesMs: [Int64],
        maxEdge: Int,
        quality: Int,
        allowNetworkAccess: Bool,
        result: @escaping FlutterResult
    ) {
        func reply(_ value: Any?) {
            DispatchQueue.main.async { result(value) }
        }

        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            if libraryAccessDenied() {
                return reply(FlutterError(
                    code: "permissionDenied",
                    message: "Photo library access is not granted.", details: nil))
            }
            return reply(FlutterError(
                code: "assetNotFound",
                message: "Asset \(localIdentifier) is not available.", details: nil))
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetworkAccess
        options.deliveryMode = .automatic

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
            avAsset, _, info in
            guard let avAsset else {
                return reply(FlutterError(
                    code: mapErrorCode(info), message: mapErrorMessage(info), details: nil))
            }
            queue.async {
                reply(frames(
                    of: avAsset, timesMs: timesMs, maxEdge: maxEdge, quality: quality))
            }
        }
    }

    private static func frames(
        of asset: AVAsset, timesMs: [Int64], maxEdge: Int, quality: Int
    ) -> [Any] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        // Any nearby sync frame will do; exact times force decoding up to them.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let compression = CGFloat(min(max(quality, 0), 100)) / 100
        return timesMs.map { ms -> Any in
            autoreleasepool {
                let time = CMTime(value: max(ms, 0), timescale: 1000)
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
                      let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: compression)
                else { return NSNull() }
                return FlutterStandardTypedData(bytes: jpeg)
            }
        }
    }
}
