// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'dart:async';

import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:photo_manager/photo_manager.dart';

import 'platform_bridge.dart';
import 'value.dart';

/// Applies one non-error native event to [current], returning the next value.
///
/// A malformed event is ignored rather than thrown: one bad message must not
/// take down the isolate a whole gallery runs on.
AssetEntityVideoValue applyPlayerEvent(
  AssetEntityVideoValue current,
  Map<Object?, Object?> event,
) {
  switch (_asString(event['event'])) {
    case 'initialized':
      final num? durationMs = event['durationMs'] as num?;
      if (durationMs == null) {
        return current;
      }
      return current.copyWith(
        isInitialized: true,
        duration: Duration(milliseconds: durationMs.toInt()),
        clearDownloadProgress: true,
      );
    case 'videoSize':
      final num? width = event['width'] as num?;
      final num? height = event['height'] as num?;
      if (width == null || height == null || width <= 0 || height <= 0) {
        return current;
      }
      return current.copyWith(
        size: Size(width.toDouble(), height.toDouble()),
        rotationDegrees: (event['rotationDegrees'] as num?)?.toInt() ?? 0,
      );
    case 'firstFrame':
      return current.copyWith(firstFrameRendered: true);
    case 'position':
      final num? positionMs = event['positionMs'] as num?;
      if (positionMs == null) {
        return current;
      }
      return current.copyWith(
        position: Duration(milliseconds: positionMs.toInt()),
      );
    case 'playing':
      final bool isPlaying = event['isPlaying'] as bool? ?? false;
      return current.copyWith(
        isPlaying: isPlaying,
        // Playback stopping is how completion is reported, so only a fresh
        // start clears it.
        isCompleted: isPlaying ? false : current.isCompleted,
      );
    case 'buffering':
      return current.copyWith(
        isBuffering: event['isBuffering'] as bool? ?? false,
      );
    case 'completed':
      return current.copyWith(isCompleted: true, isPlaying: false);
    case 'downloadProgress':
      final num? progress = event['progress'] as num?;
      if (progress == null) {
        return current;
      }
      return current.copyWith(downloadProgress: progress.toDouble());
    default:
      return current;
  }
}

String? _asString(Object? value) => value is String ? value : null;

/// Plays a video that lives in the photo library, without copying the original.
///
/// Android resolves the asset to a MediaStore `content://` URI and hands it to
/// ExoPlayer; iOS asks PhotoKit for an `AVPlayerItem`. Neither path exports or
/// copies a file.
class AssetEntityVideoController extends ValueNotifier<AssetEntityVideoValue> {
  /// Builds a controller synchronously, seeding size and duration from the
  /// asset so the layout is correct before the first frame exists.
  AssetEntityVideoController(
    AssetEntity asset, {
    this.allowNetworkAccess = true,
    bool autoLoop = false,
    double volume = 1.0,
  })  : assetId = asset.id,
        _assetIsVideo = asset.type == AssetType.video,
        super(
          AssetEntityVideoValue(
            size: asset.orientatedSize,
            duration: asset.videoDuration,
            isLooping: autoLoop,
            volume: volume,
          ),
        );

  /// MediaStore id on Android, `PHAsset.localIdentifier` on iOS.
  final String assetId;

  /// Whether an iCloud-only asset may be downloaded on demand. iOS only.
  final bool allowNetworkAccess;

  final bool _assetIsVideo;

  int? _textureId;
  StreamSubscription<dynamic>? _events;
  Future<void>? _initializing;
  final Completer<void> _ready = Completer<void>();
  bool _disposed = false;

  /// Identifies the Flutter texture the video is drawn into.
  @internal
  int? get textureId => _textureId;

  /// Creates the platform player and completes once it reports its metadata,
  /// so `value.duration` and `value.size` are exact when this returns.
  ///
  /// Never throws: a failure lands in `value.error` so one broken asset cannot
  /// stall a gallery swipe.
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!_assetIsVideo) {
      _fail(
        const AssetEntityVideoError(
          AssetEntityVideoErrorCode.notAVideo,
          'The asset is not a video.',
        ),
      );
      return;
    }
    try {
      final int id = await AssetEntityVideoPlatform.create(
        assetId: assetId,
        allowNetworkAccess: allowNetworkAccess,
        looping: value.isLooping,
        volume: value.volume,
      );
      if (_disposed) {
        unawaited(
          AssetEntityVideoPlatform.dispose(id).catchError((Object _) {}),
        );
        return;
      }
      _textureId = id;
      // textureId isn't part of `value`, so assigning it alone wouldn't reach
      // a ValueListenableBuilder — the Texture widget would never mount.
      notifyListeners();
      _events = AssetEntityVideoPlatform.events(id).listen(
        _onEvent,
        onError: (Object e) => _fail(
          e is PlatformException
              ? decodeError(e.code, e.message)
              : AssetEntityVideoError(
                  AssetEntityVideoErrorCode.playbackFailed,
                  '$e',
                ),
        ),
      );
      await _ready.future;
    } on PlatformException catch (e) {
      _fail(decodeError(e.code, e.message));
    } catch (e) {
      _fail(
        AssetEntityVideoError(
          AssetEntityVideoErrorCode.playbackFailed,
          '$e',
        ),
      );
    }
  }

  /// Starts or resumes playback, initializing the player if needed.
  Future<void> play() => _withPlayer(AssetEntityVideoPlatform.play);

  /// Pauses playback, keeping the surface on the current frame.
  Future<void> pause() => _withPlayer(AssetEntityVideoPlatform.pause);

  /// Warms up the decoder without starting playback, so a neighbouring asset
  /// is ready the moment the user swipes to it.
  Future<void> prepare() => initialize();

  /// Moves playback to [position].
  Future<void> seekTo(Duration position) => _withPlayer(
        (int id) => AssetEntityVideoPlatform.seekTo(id, position),
      );

  /// Sets output volume; values outside 0.0–1.0 are clamped.
  Future<void> setVolume(double volume) {
    if (_disposed) {
      return Future<void>.value();
    }
    final double clamped = volume.clamp(0.0, 1.0);
    value = value.copyWith(volume: clamped);
    return _withPlayer(
      (int id) => AssetEntityVideoPlatform.setVolume(id, clamped),
    );
  }

  /// Sets whether playback restarts on completion.
  Future<void> setLooping(bool looping) {
    if (_disposed) {
      return Future<void>.value();
    }
    value = value.copyWith(isLooping: looping);
    return _withPlayer(
      (int id) => AssetEntityVideoPlatform.setLooping(id, looping),
    );
  }

  Future<void> _withPlayer(Future<void> Function(int textureId) action) async {
    await initialize();
    final int? id = _textureId;
    if (id == null || _disposed) {
      return;
    }
    try {
      await action(id);
    } on PlatformException catch (e) {
      _fail(decodeError(e.code, e.message));
    }
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) {
      return;
    }
    final Map<Object?, Object?> map = event;
    if (_asString(map['event']) == 'error') {
      _fail(decodeError(_asString(map['code']), _asString(map['message'])));
      return;
    }
    value = applyPlayerEvent(value, map);
    if (value.isInitialized) {
      _markReady();
    }
  }

  void _fail(AssetEntityVideoError error) {
    _markReady();
    if (_disposed) {
      return;
    }
    value = value.copyWith(
      error: error,
      isPlaying: false,
      isBuffering: false,
      clearDownloadProgress: true,
    );
  }

  /// Lets a pending [initialize] return; nothing more will change its outcome.
  void _markReady() {
    if (!_ready.isCompleted) {
      _ready.complete();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _markReady();
    _events?.cancel();
    final int? id = _textureId;
    if (id != null) {
      // The native side may already have dropped the player on an engine
      // detach, and that rejection must not escape into the disposing zone.
      unawaited(AssetEntityVideoPlatform.dispose(id).catchError((Object _) {}));
    }
    super.dispose();
  }
}
