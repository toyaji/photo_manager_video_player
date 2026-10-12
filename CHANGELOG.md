## Unreleased

- `AssetEntityVideoController(viewType: AssetEntityVideoViewType.platformView)`:
  on Android, shows the video in a `SurfaceView` platform view so HDR video
  keeps its own display layer. The default stays `textureView`; other
  platforms always use the texture.
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
- Pauses in the background and resumes on return; a `play()` that would start
  in the background starts on return instead. `dispose()` completes once the
  platform player is released, even while it is being created. iOS raises an ambient audio
  session to `.playback` on the first player.
- Flutter 3.29 or later; Swift Package Manager builds need Flutter 3.44.
