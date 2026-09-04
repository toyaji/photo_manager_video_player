// Copyright 2026 The FlutterCandies author. All rights reserved.
// Use of this source code is governed by an Apache license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'value.dart';

/// Renders a controller's video, filling the space it's given.
///
/// Wrap it in an `AspectRatio(aspectRatio: controller.value.aspectRatio)` to
/// letterbox. The frames arrive as a Flutter texture, so this composites like
/// any other widget — opacity, transforms and scrolling all behave normally.
class AssetEntityVideoView extends StatelessWidget {
  /// Renders [controller].
  const AssetEntityVideoView(this.controller, {super.key});

  /// The controller whose video is shown.
  final AssetEntityVideoController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AssetEntityVideoValue>(
      valueListenable: controller,
      builder: (BuildContext context, AssetEntityVideoValue value, _) {
        final int? textureId = controller.textureId;
        if (textureId == null || value.hasError) {
          return const SizedBox.expand();
        }
        return RotatedBox(
          quarterTurns: value.rotationDegrees ~/ 90,
          child: Texture(textureId: textureId),
        );
      },
    );
  }
}
