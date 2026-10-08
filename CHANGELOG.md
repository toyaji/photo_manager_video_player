## Unreleased

- `AssetEntityVideoFrames.extract`: JPEG stills at a list of times, read in
  place — `AVAssetImageGenerator` on iOS, `MediaMetadataRetriever` on Android.

## 0.1.0

- `AssetEntityVideoController`, `AssetEntityVideoValue`, `AssetEntityVideoView`:
  play a `photo_manager` `AssetEntity` video without an app-managed copy or
  export of the original.
- Android: MediaStore `content://` URI → ExoPlayer, drawn into a Flutter
  texture through `TextureRegistry.SurfaceProducer`.
- iOS: `PHImageManager.requestPlayerItem` → `AVPlayer`, drawn into a Flutter
  texture through `AVPlayerItemVideoOutput`.
- Pauses in the background and resumes on return; iOS raises an ambient audio
  session to `.playback` on the first player.
