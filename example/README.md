# photo_manager_video_player example

A small gallery that plays photo library videos with
`AssetEntityVideoController`, without copying the original.

- The grid lists the device's videos through `photo_manager`.
- Tapping one opens a player page; a black cover fades out on
  `firstFrameRendered`.
- The segmented button in the app bar picks `textureView` or `platformView` (for HDR).

```sh
flutter run
```

The app asks for photo library access on start. Device tests live in
`integration_test/`; `tool/integration_test_android.sh` runs them on a connected Android
emulator and grants photo access as the app installs.
