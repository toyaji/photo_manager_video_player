// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

// `startPosition` and `mediaStoreThumbnailPosition` against the real Android
// player and MediaStore. The sample clips are added to the device library on
// first run; grant photo access before running.
//
// `pmvp_steps.mp4`: 6 s, 320×240, a sync frame every second, and one solid
// colour per second — red, green, blue, yellow, magenta, cyan.
// `pmvp_steps_cover.mp4`: the same with a red cover picture (its first frame).
// `pmvp_steps_poster.mp4`: the same with a test-pattern cover that is no frame.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

/// A sample clip from `integration_test/assets`, added to the library once.
Future<AssetEntity> _clip(String name) async {
  final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
    type: RequestType.video,
    onlyAll: true,
    filterOption: FilterOptionGroup(orders: <OrderOption>[const OrderOption()]),
  );
  final int count = paths.isEmpty ? 0 : await paths.first.assetCountAsync;
  if (count > 0) {
    final List<AssetEntity> all =
        await paths.first.getAssetListRange(start: 0, end: count);
    for (final AssetEntity asset in all) {
      if (await asset.titleAsync == '$name.mp4') {
        return asset;
      }
    }
  }
  final ByteData data =
      await rootBundle.load('integration_test/assets/$name.mp4');
  final File file = File('${Directory.systemTemp.path}/$name.mp4')
    ..writeAsBytesSync(data.buffer.asUint8List());
  return PhotoManager.editor.saveVideo(file, title: '$name.mp4');
}

Future<void> _until(
  AssetEntityVideoController controller,
  bool Function(AssetEntityVideoValue value) done,
) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!done(controller.value)) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('Timed out; last value: ${controller.value}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// The centre pixel of the first frame [controller] renders, as RGB.
Future<(int, int, int)> _firstFrameColour(
  WidgetTester tester,
  AssetEntityVideoController controller,
) async {
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(
    Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 160,
          height: 120,
          child: AssetEntityVideoView(controller),
        ),
      ),
    ),
  );
  await _until(controller, (AssetEntityVideoValue v) => v.firstFrameRendered);
  await tester.pump(const Duration(milliseconds: 100));
  final ui.Image image =
      await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage();
  final ByteData bytes =
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final int o = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  await tester.pumpWidget(const SizedBox());
  return (bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2));
}

Matcher _near((int, int, int) rgb) => predicate<(int, int, int)>(
      (c) =>
          (c.$1 - rgb.$1).abs() < 40 &&
          (c.$2 - rgb.$2).abs() < 40 &&
          (c.$3 - rgb.$3).abs() < 40,
      'close to $rgb',
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bool android = Platform.isAndroid;

  setUpAll(() async {
    final PermissionState state = await PhotoManager.requestPermissionExtend();
    expect(state.hasAccess, isTrue, reason: 'Grant photo access first.');
  });

  group('startPosition', () {
    testWidgets('prepares on the frame at the position', (WidgetTester tester) async {
      final AssetEntityVideoController controller = AssetEntityVideoController(
        await _clip('pmvp_steps'),
        startPosition: const Duration(seconds: 4),
      );
      await controller.initialize();
      expect(controller.value.hasError, isFalse, reason: '${controller.value}');
      expect(controller.value.position, const Duration(seconds: 4));
      expect(await _firstFrameColour(tester, controller), _near((255, 0, 255)),
          reason: 'magenta is 4–5 s');
      await controller.dispose();
    }, skip: !android);

    testWidgets('a start past the end starts at 0', (WidgetTester tester) async {
      final AssetEntityVideoController controller = AssetEntityVideoController(
        await _clip('pmvp_steps'),
        startPosition: const Duration(seconds: 7),
      );
      await controller.initialize();
      expect(controller.value.position, Duration.zero);
      expect(await _firstFrameColour(tester, controller), _near((255, 0, 0)));
      await controller.dispose();
    }, skip: !android);
  });

  group('mediaStoreThumbnailPosition', () {
    test('finds the ThumbnailUtils frame, half the duration in', () async {
      final AssetEntity clip = await _clip('pmvp_steps');
      expect(
        await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id),
        const Duration(seconds: 3),
      );
    }, skip: !android);

    test('a cover picture that is the first frame gives 0', () async {
      final AssetEntity clip = await _clip('pmvp_steps_cover');
      expect(
        await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id),
        Duration.zero,
      );
    }, skip: !android);

    test('a cover picture that is no frame gives null', () async {
      final AssetEntity clip = await _clip('pmvp_steps_poster');
      expect(
        await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id),
        isNull,
      );
    }, skip: !android);

    test('a repeated request is answered from memory', () async {
      final AssetEntity clip = await _clip('pmvp_steps');
      await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id);
      final Stopwatch watch = Stopwatch()..start();
      final List<Duration?> both = await Future.wait(<Future<Duration?>>[
        AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id),
        AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id),
      ]);
      expect(both, <Duration?>[const Duration(seconds: 3), const Duration(seconds: 3)]);
      expect(watch.elapsedMilliseconds, lessThan(200), reason: 'no decode');
    }, skip: !android);

    testWidgets('a player started there shows the thumbnail\'s frame',
        (WidgetTester tester) async {
      final AssetEntity clip = await _clip('pmvp_steps');
      final Duration? start =
          await AssetEntityVideoFrames.mediaStoreThumbnailPosition(assetId: clip.id);
      final AssetEntityVideoController controller =
          AssetEntityVideoController(clip, startPosition: start!);
      await controller.initialize();
      expect(await _firstFrameColour(tester, controller), _near((255, 255, 0)),
          reason: 'yellow is 3–4 s, the MediaStore thumbnail');
      await controller.dispose();
    }, skip: !android);
  });
}
