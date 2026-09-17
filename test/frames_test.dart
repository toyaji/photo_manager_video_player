// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

const MethodChannel _channel = MethodChannel(
  'com.fluttercandies/photo_manager_video_player',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> calls = <MethodCall>[];

  void mockReply(Future<Object?> Function(MethodCall call) reply) {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) {
      calls.add(call);
      return reply(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  }

  setUp(calls.clear);

  test('sends every argument in one extractFrames call', () async {
    mockReply((MethodCall call) async => <Object?>[null, null]);

    await AssetEntityVideoFrames.extract(
      assetId: 'abc',
      timesMs: <int>[0, 1500],
      maxEdge: 320,
      quality: 60,
      allowNetworkAccess: true,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'extractFrames');
    expect(calls.single.arguments, <String, Object?>{
      'assetId': 'abc',
      'timesMs': <int>[0, 1500],
      'maxEdge': 320,
      'quality': 60,
      'allowNetworkAccess': true,
    });
  });

  test('defaults to 480px, quality 70, no network', () async {
    mockReply((MethodCall call) async => <Object?>[null]);

    await AssetEntityVideoFrames.extract(assetId: 'abc', timesMs: <int>[0]);

    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(args['maxEdge'], 480);
    expect(args['quality'], 70);
    expect(args['allowNetworkAccess'], false);
  });

  test('keeps order and nulls for frames that failed', () async {
    final Uint8List a = Uint8List.fromList(<int>[1]);
    final Uint8List c = Uint8List.fromList(<int>[3]);
    mockReply((MethodCall call) async => <Object?>[a, null, c]);

    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: 'abc',
      timesMs: <int>[0, 1000, 2000],
    );

    expect(frames, <Uint8List?>[a, null, c]);
  });

  test('a short reply is padded with nulls to one entry per time', () async {
    final Uint8List a = Uint8List.fromList(<int>[1]);
    mockReply((MethodCall call) async => <Object?>[a]);

    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: 'abc',
      timesMs: <int>[0, 1000],
    );

    expect(frames, <Uint8List?>[a, null]);
  });

  test('no times means no platform call', () async {
    mockReply((MethodCall call) async => null);

    final List<Uint8List?> frames = await AssetEntityVideoFrames.extract(
      assetId: 'abc',
      timesMs: <int>[],
    );

    expect(frames, isEmpty);
    expect(calls, isEmpty);
  });

  test('an asset that cannot load surfaces the platform error code', () async {
    mockReply(
      (MethodCall call) async => throw PlatformException(
        code: 'iCloudUnavailable',
        message: 'not local',
      ),
    );

    expect(
      AssetEntityVideoFrames.extract(assetId: 'abc', timesMs: <int>[0]),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException e) => e.code,
          'code',
          'iCloudUnavailable',
        ),
      ),
    );
  });
}
