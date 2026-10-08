import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_video_player/photo_manager_video_player.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'photo_manager_video_player example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const GalleryPage(),
    );
  }
}

/// Lists the device's videos and plays each one without copying it first.
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<AssetEntity>? _videos;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final PermissionState permission =
        await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      setState(() => _errorText = 'Photo library access was denied.');
      return;
    }
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: <OrderOption>[
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (paths.isEmpty) {
      setState(() => _videos = const <AssetEntity>[]);
      return;
    }
    final List<AssetEntity> videos =
        await paths.first.getAssetListPaged(page: 0, size: 100);
    if (mounted) {
      setState(() => _videos = videos);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gallery videos')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_errorText != null) {
      return Center(child: Text(_errorText!));
    }
    final List<AssetEntity>? videos = _videos;
    if (videos == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (videos.isEmpty) {
      return const Center(child: Text('No videos found.'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: videos.length,
      itemBuilder: (BuildContext context, int index) {
        final AssetEntity asset = videos[index];
        return _VideoThumbnail(
          asset: asset,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VideoPage(asset: asset),
            ),
          ),
        );
      },
    );
  }
}

class _VideoThumbnail extends StatelessWidget {
  const _VideoThumbnail({required this.asset, required this.onTap});

  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FutureBuilder<Uint8List?>(
        future: asset.thumbnailDataWithSize(const ThumbnailSize.square(256)),
        builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
          final Uint8List? bytes = snapshot.data;
          return Container(
            color: Colors.black12,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (bytes != null) Image.memory(bytes, fit: BoxFit.cover),
                const Align(
                  alignment: Alignment.center,
                  child: Icon(Icons.play_circle_outline,
                      color: Colors.white, size: 32),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Plays one asset with [AssetEntityVideoController] — no copy first, either
/// platform. The poster thumbnail cross-fades out on `firstFrameRendered`.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final AssetEntityVideoController _controller =
      AssetEntityVideoController(widget.asset);

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) => _controller.play());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Four stills spread across the clip, read without copying the video.
  Future<void> _showFrames() async {
    final int durationMs = widget.asset.videoDuration.inMilliseconds;
    final Future<List<Uint8List?>> frames = AssetEntityVideoFrames.extract(
      assetId: widget.asset.id,
      timesMs: <int>[for (int i = 0; i < 4; i++) durationMs * i ~/ 4],
      allowNetworkAccess: true,
    );
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => FutureBuilder<List<Uint8List?>>(
        future: frames,
        builder: (BuildContext context, AsyncSnapshot<List<Uint8List?>> snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.all(8),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: <Widget>[
              for (final Uint8List? jpeg in snap.data!)
                jpeg == null
                    ? const ColoredBox(color: Colors.black12)
                    : Image.memory(jpeg, fit: BoxFit.cover),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: <Widget>[
          IconButton(
            tooltip: 'Frames',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _showFrames,
          ),
        ],
      ),
      body: Center(
        child: ValueListenableBuilder<AssetEntityVideoValue>(
          valueListenable: _controller,
          builder: (BuildContext context, AssetEntityVideoValue value, _) {
            if (value.hasError) {
              return Center(
                child: Text(
                  value.error!.message,
                  style: const TextStyle(color: Colors.white),
                ),
              );
            }
            return AspectRatio(
              aspectRatio: value.aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  AnimatedOpacity(
                    opacity: value.firstFrameRendered ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: AssetEntityVideoView(_controller),
                  ),
                  if (value.isBuffering)
                    const Center(child: CircularProgressIndicator()),
                  if (value.downloadProgress != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: LinearProgressIndicator(
                        value: value.downloadProgress,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _Controls(controller: _controller, value: value),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.value});

  final AssetEntityVideoController controller;
  final AssetEntityVideoValue value;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black45,
      child: Row(
        children: <Widget>[
          IconButton(
            color: Colors.white,
            icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: value.isPlaying ? controller.pause : controller.play,
          ),
          Expanded(
            child: Slider(
              value: value.position.inMilliseconds
                  .clamp(0, value.duration.inMilliseconds)
                  .toDouble(),
              max: value.duration.inMilliseconds
                  .toDouble()
                  .clamp(1, double.infinity),
              onChanged: (double ms) =>
                  controller.seekTo(Duration(milliseconds: ms.round())),
            ),
          ),
        ],
      ),
    );
  }
}
