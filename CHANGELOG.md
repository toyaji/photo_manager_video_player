## 0.1.0

- `AssetEntityVideoController`, `AssetEntityVideoValue`, `AssetEntityVideoView`:
  play a `photo_manager` `AssetEntity` video with zero copies of the original.
- Android: MediaStore `content://` URI → ExoPlayer, drawn into a Flutter
  texture through `TextureRegistry.SurfaceProducer`.
- iOS: `PHImageManager.requestPlayerItem` → `AVPlayer`, drawn into a Flutter
  texture through `AVPlayerItemVideoOutput`.
