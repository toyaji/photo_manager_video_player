// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show PlatformException, Uint8List;

import 'platform_bridge.dart';

/// Still frames from a gallery video, read in place — the original is never
/// exported or copied.
abstract final class AssetEntityVideoFrames {
  /// JPEG frames of the video [assetId] (an `AssetEntity.id`) near each of
  /// [timesMs], resolved and loaded once for the whole call.
  ///
  /// The result has one entry per time, in the same order; an entry is `null`
  /// when that frame could not be decoded. Frames snap to the nearest sync
  /// frame, trading exact timing for speed. The longer edge is at most
  /// [maxEdge] pixels and [quality] is the JPEG quality, 0–100.
  ///
  /// Throws a `PlatformException` only when the asset itself cannot be
  /// loaded; its code is one of the `AssetEntityVideoErrorCode` names:
  /// `assetNotFound`, `permissionDenied`, `iCloudUnavailable` (iOS: the video
  /// is not on the device and [allowNetworkAccess] is false, or the download
  /// failed), or `playbackFailed`.
  static Future<List<Uint8List?>> extract({
    required String assetId,
    required List<int> timesMs,
    int maxEdge = 480,
    int quality = 70,
    bool allowNetworkAccess = false,
  }) async {
    assert(maxEdge > 0, 'maxEdge must be positive.');
    assert(quality >= 0 && quality <= 100, 'quality must be 0–100.');
    if (timesMs.isEmpty) {
      return <Uint8List?>[];
    }
    return AssetEntityVideoPlatform.extractFrames(
      assetId: assetId,
      timesMs: timesMs,
      maxEdge: maxEdge,
      quality: quality.clamp(0, 100),
      allowNetworkAccess: allowNetworkAccess,
    );
  }

  /// Position of the frame the Android MediaStore system thumbnail
  /// (`ContentResolver.loadThumbnail`) shows, for
  /// [AssetEntityVideoController.startPosition], so that thumbnail can hand
  /// over to playback without a jump.
  ///
  /// MediaStore exposes no thumbnail time, so the plugin computes the sync
  /// frame `ThumbnailUtils` picks (nearest half the duration), confirms it
  /// against the thumbnail with one small decode, and tries the
  /// representative, first and neighbouring sync frames only when it does not
  /// match; a video with embedded cover art, which the thumbnail then shows,
  /// is tried against its first frame first. Returns null when none of them is
  /// the thumbnail's frame, when anything cannot be read, below Android 8.1,
  /// and on other platforms. Results are kept per asset version
  /// for the life of the process; lookups run one at a time, and concurrent
  /// requests for one asset share a single lookup. Throws a
  /// [PlatformException] when the plugin is detached from its engine.
  static Future<Duration?> mediaStoreThumbnailPosition({
    required String assetId,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    final int? ms =
        await AssetEntityVideoPlatform.mediaStoreThumbnailPositionMs(assetId);
    return ms == null ? null : Duration(milliseconds: ms);
  }
}
