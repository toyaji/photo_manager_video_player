// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

const String _name = 'com.fluttercandies/photo_manager_video_player';
const MethodChannel _channel = MethodChannel(_name);

AssetEntity _video() => AssetEntity(
      id: '1',
      typeInt: AssetType.video.index,
      width: 1920,
      height: 1080,
      duration: 6,
    );

/// Answers `create` with texture 1 and replays [events] once Dart listens.
void _mockPlatform(List<Map<String, Object?>> events) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const String eventChannel = '$_name/events/1';

  messenger.setMockMethodCallHandler(
    _channel,
    (MethodCall call) async => call.method == 'create' ? 1 : null,
  );
  messenger.setMockMethodCallHandler(const MethodChannel(eventChannel), (
    MethodCall call,
  ) async {
    if (call.method != 'listen') {
      return null;
    }
    for (final Map<String, Object?> event in events) {
      await messenger.handlePlatformMessage(
        eventChannel,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        null,
      );
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(const MethodChannel(eventChannel), null);
  });
}

Future<AssetEntityVideoController> _ready(
  List<Map<String, Object?>> events,
) async {
  _mockPlatform(<Map<String, Object?>>[
    <String, Object?>{'event': 'initialized', 'durationMs': 6000},
    ...events,
  ]);
  final AssetEntityVideoController controller = AssetEntityVideoController(
    _video(),
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nothing is drawn before the platform player exists', (
    WidgetTester tester,
  ) async {
    _mockPlatform(const <Map<String, Object?>>[]);
    final AssetEntityVideoController controller = AssetEntityVideoController(
      _video(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(AssetEntityVideoView(controller));

    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('an upright track is drawn without a quarter turn', (
    WidgetTester tester,
  ) async {
    final AssetEntityVideoController controller = await _ready(
      <Map<String, Object?>>[
        <String, Object?>{
          'event': 'videoSize',
          'width': 1920,
          'height': 1080,
          'rotationDegrees': 0,
        },
      ],
    );

    await tester.pumpWidget(AssetEntityVideoView(controller));

    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
  });

  testWidgets('a quarter-turned track is rotated back upright', (
    WidgetTester tester,
  ) async {
    final AssetEntityVideoController controller = await _ready(
      <Map<String, Object?>>[
        <String, Object?>{
          'event': 'videoSize',
          'width': 1080,
          'height': 1920,
          'rotationDegrees': 90,
        },
      ],
    );

    await tester.pumpWidget(AssetEntityVideoView(controller));

    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(controller.value.size, const Size(1080, 1920));
  });
}
