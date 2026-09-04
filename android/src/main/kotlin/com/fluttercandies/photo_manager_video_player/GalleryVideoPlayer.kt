package com.fluttercandies.photo_manager_video_player

import android.content.ContentUris
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import java.io.FileNotFoundException

/**
 * Owns one ExoPlayer fed straight from a MediaStore `content://` URI, drawing
 * into a Flutter texture — so nothing is copied into the app sandbox, and
 * Flutter composites the video like any other widget.
 */
class GalleryVideoPlayer(
    context: Context,
    messenger: BinaryMessenger,
    private val surface: TextureRegistry.SurfaceProducer,
    private val assetId: String,
    initialLooping: Boolean,
    initialVolume: Double,
) {
    val textureId: Long = surface.id()

    private val events =
        EventChannel(messenger, "${PhotoManagerVideoPlayerPlugin.CHANNEL_NAME}/events/$textureId")
    private var sink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private var prepared = false
    private var released = false
    private var initializedEventSent = false

    private val playerListener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width <= 0 || videoSize.height <= 0) return
            surface.setSize(videoSize.width, videoSize.height)
            emit(
                "videoSize",
                mapOf(
                    "width" to videoSize.width,
                    "height" to videoSize.height,
                    "rotationDegrees" to (exoPlayer.videoFormat?.rotationDegrees ?: 0),
                ),
            )
        }

        override fun onRenderedFirstFrame() {
            emit("firstFrame")
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_READY -> emitInitializedOnce()
                Player.STATE_ENDED -> {
                    stopPositionUpdates()
                    emit("completed")
                }
            }
            emit("buffering", mapOf("isBuffering" to (playbackState == Player.STATE_BUFFERING)))
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emit("playing", mapOf("isPlaying" to isPlaying))
            if (isPlaying) startPositionUpdates() else stopPositionUpdates()
        }

        override fun onPlayerError(error: PlaybackException) {
            val (code, message) = mapPlaybackError(error)
            emitError(code, message)
        }
    }

    private val exoPlayer: ExoPlayer = ExoPlayer.Builder(context).build().apply {
        // Requests audio focus, so starting a gallery video pauses whatever
        // else the user was listening to.
        setAudioAttributes(
            AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
            true,
        )
        volume = initialVolume.toFloat().coerceIn(0f, 1f)
        repeatMode = if (initialLooping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        addListener(playerListener)
        setVideoSurface(surface.surface)
    }

    init {
        // Android can reclaim the surface while the app is backgrounded; the
        // player has to be re-attached to the new one on the way back.
        surface.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (!released) exoPlayer.setVideoSurface(surface.surface)
            }

            override fun onSurfaceCleanup() {
                if (!released) exoPlayer.setVideoSurface(null)
            }
        })

        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                this@GalleryVideoPlayer.sink = sink
                prepare()
            }

            override fun onCancel(arguments: Any?) {
                this@GalleryVideoPlayer.sink = null
            }
        })
    }

    /** Hands the MediaStore URI to ExoPlayer. Idempotent. */
    fun prepare() {
        if (prepared || released) return
        prepared = true
        val id = assetId.toLongOrNull()
        if (id == null) {
            emitError("assetNotFound", "'$assetId' is not a MediaStore id.")
            return
        }
        val uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
        exoPlayer.setMediaItem(MediaItem.fromUri(uri))
        exoPlayer.prepare()
    }

    fun play() {
        // play() does nothing once playback ended, so a replay has to rewind.
        if (exoPlayer.playbackState == Player.STATE_ENDED) exoPlayer.seekTo(0)
        exoPlayer.play()
    }

    fun pause() = exoPlayer.pause()

    fun seekTo(positionMs: Long) {
        exoPlayer.seekTo(positionMs)
        // The position poller only runs while playing, so a paused seek would
        // otherwise never reach the UI.
        emit("position", mapOf("positionMs" to positionMs))
    }

    fun setVolume(volume: Double) {
        exoPlayer.volume = volume.toFloat().coerceIn(0f, 1f)
    }

    fun setLooping(looping: Boolean) {
        exoPlayer.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    fun release() {
        if (released) return
        released = true
        stopPositionUpdates()
        exoPlayer.removeListener(playerListener)
        exoPlayer.release()
        surface.release()
        events.setStreamHandler(null)
        sink = null
    }

    private fun emitInitializedOnce() {
        if (initializedEventSent) return
        val duration = exoPlayer.duration
        if (duration == C.TIME_UNSET) return
        initializedEventSent = true
        emit("initialized", mapOf("durationMs" to duration))
    }

    private val positionRunnable = object : Runnable {
        override fun run() {
            emit("position", mapOf("positionMs" to exoPlayer.currentPosition))
            mainHandler.postDelayed(this, POSITION_POLL_INTERVAL_MS)
        }
    }

    private fun startPositionUpdates() {
        mainHandler.removeCallbacks(positionRunnable)
        mainHandler.post(positionRunnable)
    }

    private fun stopPositionUpdates() = mainHandler.removeCallbacks(positionRunnable)

    private fun emit(event: String, extra: Map<String, Any?> = emptyMap()) {
        sink?.success(mapOf("event" to event) + extra)
    }

    private fun emitError(code: String, message: String) =
        emit("error", mapOf("code" to code, "message" to message))

    companion object {
        private const val POSITION_POLL_INTERVAL_MS = 200L
    }
}

/** (code, message) for a [PlaybackException], matching `AssetEntityVideoErrorCode` on the Dart side. */
private fun mapPlaybackError(error: PlaybackException): Pair<String, String> {
    return when (error.cause) {
        is SecurityException -> "permissionDenied" to "No access to this asset."
        is FileNotFoundException -> "assetNotFound" to "Asset is no longer in the library."
        else -> "playbackFailed" to (error.message ?: "Playback failed.")
    }
}
