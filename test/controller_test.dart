// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

const MethodChannel _channel =
    MethodChannel('com.fluttercandies/photo_manager_video_player');

AssetEntity _video(String id) => AssetEntity(
      id: id,
      typeInt: AssetType.video.index,
      width: 1920,
      height: 1080,
      duration: 12,
    );

/// Answers `create` with [textureId] and, once Dart listens, delivers the
/// `initialized` event that [AssetEntityVideoController.initialize] waits for.
List<MethodCall> _mockPlatform(
  int textureId, {
  Object? Function(MethodCall)? onCall,
  bool reportInitialized = true,
}) {
  final List<MethodCall> calls = <MethodCall>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final String eventChannel =
      'com.fluttercandies/photo_manager_video_player/events/$textureId';

  messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
    calls.add(call);
    if (onCall != null) {
      return onCall(call);
    }
    return call.method == 'create' ? textureId : null;
  });
  messenger.setMockMethodCallHandler(MethodChannel(eventChannel), (
    MethodCall call,
  ) async {
    if (call.method == 'listen' && reportInitialized) {
      await messenger.handlePlatformMessage(
        eventChannel,
        const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
          'event': 'initialized',
          'durationMs': 12400,
        }),
        null,
      );
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(MethodChannel(eventChannel), null);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('seeds size and duration from the asset', () {
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    expect(controller.value.size.width, 1920);
    expect(controller.value.duration, const Duration(seconds: 12));
    expect(controller.value.isInitialized, isFalse);
    controller.dispose();
  });

  test('a non-video asset is rejected when the controller is built', () {
    expect(
      () => AssetEntityVideoController(
        AssetEntity(
          id: '2',
          typeInt: AssetType.image.index,
          width: 100,
          height: 100,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('initialize() notifies listeners so the view can mount', () async {
    _mockPlatform(42);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    int notifications = 0;
    controller.addListener(() => notifications++);

    await controller.initialize();

    expect(notifications, greaterThan(0));
    controller.dispose();
  });

  test('a rejected create lands in value.error', () async {
    _mockPlatform(
      1,
      onCall: (MethodCall call) {
        throw PlatformException(code: 'permissionDenied', message: 'denied');
      },
    );
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));

    await controller.initialize();

    expect(
      controller.value.error?.code,
      AssetEntityVideoErrorCode.permissionDenied,
    );
    controller.dispose();
  });

  test('dispose() releases the native player without an uncaught exception',
      () async {
    _mockPlatform(
      9,
      onCall: (MethodCall call) {
        if (call.method == 'create') {
          return 9;
        }
        if (call.method == 'dispose') {
          // The engine can already have dropped the player on a hot restart.
          throw PlatformException(code: 'assetNotFound', message: 'gone');
        }
        return null;
      },
    );

    Object? uncaught;
    await runZonedGuarded(
      () async {
        final AssetEntityVideoController controller =
            AssetEntityVideoController(_video('1'));
        await controller.initialize();
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      },
      (Object error, StackTrace stack) => uncaught = error,
    );

    expect(uncaught, isNull);
  });

  test('setVolume/setLooping are no-ops after dispose', () async {
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    controller.dispose();

    await controller.setVolume(0.5);
    await controller.setLooping(true);
  });

  test('setters before initialize only update value, without a player',
      () async {
    final List<MethodCall> calls = _mockPlatform(3);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));

    await controller.setVolume(0);
    await controller.setLooping(true);
    await controller.pause();
    await controller.seekTo(const Duration(seconds: 1));

    expect(calls, isEmpty);
    expect(controller.value.volume, 0);
    expect(controller.value.isLooping, isTrue);

    await controller.initialize();
    final MethodCall create =
        calls.firstWhere((MethodCall c) => c.method == 'create');
    expect(create.arguments['volume'], 0.0);
    expect(create.arguments['looping'], isTrue);
    await controller.dispose();
  });

  test('a setter during create is applied once the player exists', () async {
    final Completer<int> created = Completer<int>();
    final List<MethodCall> calls = _mockPlatform(
      4,
      onCall: (MethodCall call) =>
          call.method == 'create' ? created.future : null,
    );
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));

    final Future<void> init = controller.initialize();
    await Future<void>.delayed(Duration.zero);
    await controller.setVolume(0.25);
    created.complete(4);
    await init;

    expect(
      calls.where((MethodCall c) => c.method == 'setVolume').single.arguments,
      containsPair('volume', 0.25),
    );
    await controller.dispose();
  });

  test('pause() before initialization cancels a pending play()', () async {
    final List<MethodCall> calls = _mockPlatform(5);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));

    final Future<void> playing = controller.play();
    await controller.pause();
    await playing;

    expect(calls.map((MethodCall c) => c.method), isNot(contains('play')));
    await controller.dispose();
  });

  test('seekTo clamps to the duration', () async {
    final List<MethodCall> calls = _mockPlatform(6);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    await controller.initialize();

    await controller.seekTo(const Duration(seconds: 99));
    await controller.seekTo(const Duration(seconds: -1));

    expect(
      calls
          .where((MethodCall c) => c.method == 'seekTo')
          .map((MethodCall c) => c.arguments['positionMs']),
      <int>[12400, 0],
    );
    await controller.dispose();
  });

  test('pauses in the background and resumes on return', () async {
    final List<MethodCall> calls = _mockPlatform(7);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    await controller.initialize();
    controller.value = controller.value.copyWith(isPlaying: true);
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.instance;

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(
      calls
          .map((MethodCall c) => c.method)
          .where((String m) => m == 'pause' || m == 'play'),
      <String>['pause', 'play'],
    );
    await controller.dispose();
  });

  test('seeking back from the end clears isCompleted', () async {
    _mockPlatform(8);
    final AssetEntityVideoController controller =
        AssetEntityVideoController(_video('1'));
    await controller.initialize();
    controller.value = controller.value.copyWith(isCompleted: true);

    await controller.seekTo(const Duration(seconds: 1));

    expect(controller.value.isCompleted, isFalse);
    await controller.dispose();
  });
}
