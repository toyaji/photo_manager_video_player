# photo_manager_video_player

Play `photo_manager` gallery videos **without copying the original**.

```dart
final controller = AssetEntityVideoController(asset);
await controller.initialize();
await controller.play();

AspectRatio(
  aspectRatio: controller.value.aspectRatio,
  child: AssetEntityVideoView(controller),
);
```

| | Android | iOS |
|---|---|---|
| Resolve | MediaStore `content://` URI | `PHImageManager.requestPlayerItem` |
| Play | ExoPlayer (media3) | `AVPlayer(playerItem:)` |
| Bytes copied | **0** | **0** |
| Extra framework | none | `Photos`, `AVFoundation` |

`entity.file` copies the whole original into the app sandbox on Android and runs
an `AVAssetExportSession` on iOS. In a gallery that copy *is* the latency.

## API

| Type | Purpose |
|---|---|
| `AssetEntityVideoController` | One player. Size and duration are seeded from the `AssetEntity`, so layout is correct before the first frame |
| `AssetEntityVideoValue` | State snapshot, including `firstFrameRendered` for poster cross-fades and `downloadProgress` for iCloud assets |
| `AssetEntityVideoView` | Renders the surface, filling the space it's given |

`prepare()` warms up a neighbouring asset's decoder without playing it. How many
players to keep alive is the app's policy — devices allow only a handful of
concurrent decoders, so dispose controllers you no longer show.

Failures land in `value.error` with a typed `AssetEntityVideoErrorCode`
(`assetNotFound`, `permissionDenied`, `iCloudUnavailable`, `notAVideo`,
`playbackFailed`) — a broken asset never throws mid-swipe.

## Not in scope

Picture-in-picture, captions, DRM, casting, network URL playback (that's
`video_player`'s job), and macOS.

## License

Apache-2.0.
