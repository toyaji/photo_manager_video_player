package com.fluttercandies.photo_manager_video_player

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class PhotoManagerVideoPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var messenger: BinaryMessenger
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry

    private val players = mutableMapOf<Long, GalleryVideoPlayer>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        textures = binding.textureRegistry
        channel = MethodChannel(messenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        releaseAll()
        channel.setMethodCallHandler(null)
    }

    private fun releaseAll() {
        players.values.forEach { it.release() }
        players.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // A hot restart keeps the engine, so players from the previous isolate
        // would keep holding decoders with no Dart side left to dispose them.
        if (call.method == "disposeAll") {
            releaseAll()
            return result.success(null)
        }

        if (call.method == "create") {
            val assetId = call.argument<String>("assetId")
                ?: return result.error("playbackFailed", "Missing 'assetId'.", null)
            val player = GalleryVideoPlayer(
                context = context,
                messenger = messenger,
                surface = textures.createSurfaceProducer(),
                assetId = assetId,
                initialLooping = call.argument<Boolean>("looping") ?: false,
                initialVolume = call.argument<Double>("volume") ?: 1.0,
            )
            players[player.textureId] = player
            return result.success(player.textureId)
        }

        val textureId = call.argument<Number>("textureId")?.toLong()
        val player = players[textureId]
            ?: return result.error("assetNotFound", "No player for the given texture.", null)

        when (call.method) {
            "play" -> player.play()
            "pause" -> player.pause()
            "seekTo" -> player.seekTo(call.argument<Number>("positionMs")?.toLong() ?: 0L)
            "setVolume" -> player.setVolume(call.argument<Double>("volume") ?: 1.0)
            "setLooping" -> player.setLooping(call.argument<Boolean>("looping") ?: false)
            "dispose" -> players.remove(textureId)?.release()
            else -> return result.notImplemented()
        }
        result.success(null)
    }

    companion object {
        const val CHANNEL_NAME = "com.fluttercandies/photo_manager_video_player"
    }
}
