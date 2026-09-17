// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

/// Needs three videos in the library, added with `xcrun simctl addmedia` or
/// `adb push` and named `landscape.mp4`, `rotated.mp4`, `noise.mp4`:
/// - 10 s, 1920×1080, red for 0–4 s, green for 4–7 s, blue for 7–10 s.
/// - 6 s, 1920×1080 yellow, stored with a 90° display rotation.
/// - 3 s, 1280×720 random noise.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AssetEntity colors;
  late AssetEntity rotated;
  late AssetEntity noise;

  setUpAll(() async {
    final PermissionState state = await PhotoManager.requestPermissionExtend();
    expect(state.hasAccess, isTrue, reason: 'grant photo access first');
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );
    final List<AssetEntity> videos =
        await paths.single.getAssetListRange(start: 0, end: 100);
    colors = await _pick(videos, 'landscape', 10);
    rotated = await _pick(videos, 'rotated', 6);
    noise = await _pick(videos, 'noise', 3);
  });

  test('one JPEG per time, in order, fitted to maxEdge', () async {
    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: colors.id,
      timesMs: <int>[1000, 5500, 8500],
    );

    expect(frames, hasLength(3));
    final List<_Decoded> decoded = <_Decoded>[
      for (final Uint8List? jpeg in frames) await _decode(jpeg!),
    ];
    for (final _Decoded d in decoded) {
      expect(d.jpegMagic, isTrue);
      expect((d.width, d.height), (480, 270));
    }
    expect(decoded.map((_Decoded d) => d.dominant), <String>[
      'red',
      'green',
      'blue',
    ]);
  });

  test('the preferred track transform makes a rotated video upright', () async {
    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: rotated.id,
      timesMs: <int>[1000],
      maxEdge: 320,
    );

    final _Decoded d = await _decode(frames.single!);
    expect((d.width, d.height), (180, 320));
    expect(d.dominant, 'yellow');
  });

  test('lower quality gives a smaller JPEG', () async {
    Future<int> sizeAt(int quality) async =>
        (await AssetEntityVideoFrames.extract(
          assetId: noise.id,
          timesMs: <int>[1000],
          maxEdge: 1080,
          quality: quality,
        ))
            .single!
            .length;

    expect(await sizeAt(10), lessThan(await sizeAt(95)));
  });

  test('an unknown id throws assetNotFound', () async {
    await expectLater(
      AssetEntityVideoFrames.extract(
        assetId: 'not-an-asset',
        timesMs: <int>[0],
      ),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException e) => e.code,
          'code',
          'assetNotFound',
        ),
      ),
    );
  });

  test('a time past the end still returns an entry', () async {
    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: colors.id,
      timesMs: <int>[0, 60000],
    );
    expect(frames, hasLength(2));
    expect(frames.first, isNotNull);
    // ignore: avoid_print
    print('past-end frame: ${frames.last == null ? 'null' : 'jpeg'}');
  });
}

/// By file name where the platform keeps it, else by duration.
Future<AssetEntity> _pick(
  List<AssetEntity> videos,
  String name,
  int seconds,
) async {
  for (final AssetEntity video in videos) {
    if ((await video.titleAsync).startsWith(name)) {
      return video;
    }
  }
  return videos.firstWhere((AssetEntity a) => a.duration == seconds);
}

class _Decoded {
  _Decoded(this.jpegMagic, this.width, this.height, this.dominant);

  final bool jpegMagic;
  final int width;
  final int height;
  final String dominant;
}

Future<_Decoded> _decode(Uint8List jpeg) async {
  final ui.Codec codec = await ui.instantiateImageCodec(jpeg);
  final ui.Image image = (await codec.getNextFrame()).image;
  final ByteData rgba = (await image.toByteData())!;
  final int o = (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
  final int r = rgba.getUint8(o),
      g = rgba.getUint8(o + 1),
      b = rgba.getUint8(o + 2);
  final String dominant = r > 180 && g > 180 && b < 80
      ? 'yellow'
      : r > 150 && g < 80 && b < 80
          ? 'red'
          : g > 80 && r < 80 && b < 80
              ? 'green'
              : b > 150 && r < 80 && g < 80
                  ? 'blue'
                  : 'rgb($r,$g,$b)';
  final _Decoded result = _Decoded(
    jpeg[0] == 0xFF && jpeg[1] == 0xD8,
    image.width,
    image.height,
    dominant,
  );
  image.dispose();
  return result;
}
