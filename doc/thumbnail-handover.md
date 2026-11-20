# Thumbnail hand-over (Android)

Starting playback on the exact frame a grid thumbnail shows, so swapping the thumbnail for the video does not jump.

## `startPosition`

`AssetEntityVideoController(startPosition: ...)` prepares the player at that
position, so the first rendered frame is the one at or after it rather than
frame 0, and `value.position` holds the start once `initialize()` returns. A
start at or past the end starts at 0.
Replays after completion and loops restart from 0. Android only for now;
elsewhere playback starts at 0.

## `mediaStoreThumbnailPosition`

A grid that swaps a thumbnail for the playing video jumps unless playback
starts on the frame the thumbnail shows. On Android 8.1 and later,
`AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId:)` returns the
position of the frame the **MediaStore system thumbnail**
(`ContentResolver.loadThumbnail`) shows; pass it as `startPosition`.

- **Which thumbnail.** Only the MediaStore one. Thumbnails rendered another
  way — for example `photo_manager`'s `thumbnailDataWithSize`, which decodes
  frame 0 by default — already match a start at 0.
- **How.** MediaStore exposes no thumbnail time. The plugin computes the sync
  frame `ThumbnailUtils` picks (nearest half the duration) and confirms it
  against the thumbnail with one small decode; the representative, first and
  neighbouring sync frames are tried only when it does not match.
- **Cover art.** `ThumbnailUtils` shows a video's embedded picture instead of
  a frame when it has one; cameras embed their first frame, so the first frame
  is tried first for such videos.
- **null.** When none of those is the thumbnail's frame (for example cover art
  that is no frame of the video), when anything cannot be read, below
  Android 8.1, and on other platforms. Decide what to
  show in that case, such as not starting playback from the thumbnail.
- **Cost.** On Android 10 and later a lookup decodes one frame in most cases — a fraction of a second
  for 4K H.264, about a second for 4K HEVC on a recent phone — and lookups run
  one at a time for the whole process on a background thread. Results, null
  included, are remembered per asset version for the life of the process, so
  a repeated request, even one made while the first is running, takes no
  decode; a failure such as running out of memory also stays null until the
  video changes or the process restarts. Requests cannot be cancelled, so ask
  only for the videos about to play.

## Putting it together

```dart
final Duration? start =
    await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: asset.id);
if (start == null) {
  // The thumbnail's frame is unknown: keep showing the thumbnail,
  // or start at 0 and accept the jump.
}
final controller = AssetEntityVideoController(
  asset,
  startPosition: start ?? Duration.zero,
);
await controller.initialize();
// value.position == start; fade the thumbnail out on firstFrameRendered.
```

[← Back to README](https://github.com/toyaji/photo_manager_video_player/blob/main/README.md)
