package com.fluttercandies.photo_manager_video_player

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Reads JPEG stills from a MediaStore video through its `content://` URI, so
 * the original is decoded in place instead of copied into the app sandbox.
 */
class VideoFrameExtractor(private val context: Context) {

    // One at a time: each retriever holds a decoder, and devices have few.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Replies with one `ByteArray` or `null` per time, or an error when the asset cannot be opened. */
    fun extract(
        assetId: String,
        timesMs: List<Long>,
        maxEdge: Int,
        quality: Int,
        result: MethodChannel.Result,
    ) {
        val id = assetId.toLongOrNull()
            ?: return result.error("assetNotFound", "'$assetId' is not a MediaStore id.", null)
        val uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)

        executor.execute {
            val retriever = MediaMetadataRetriever()
            try {
                try {
                    retriever.setDataSource(context, uri)
                } catch (e: Exception) {
                    val (code, message) = mapOpenError(e)
                    mainHandler.post { result.error(code, message, null) }
                    return@execute
                }
                val frames = timesMs.map { frameAt(retriever, it, maxEdge, quality) }
                mainHandler.post { result.success(frames) }
            } finally {
                retriever.release()
            }
        }
    }

    fun dispose() = executor.shutdownNow()

    private fun frameAt(
        retriever: MediaMetadataRetriever,
        timeMs: Long,
        maxEdge: Int,
        quality: Int,
    ): ByteArray? {
        val timeUs = max(timeMs, 0L) * 1000
        val option = MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        val bitmap = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(timeUs, option, maxEdge, maxEdge)
            } else {
                retriever.getFrameAtTime(timeUs, option)?.let { scaleToFit(it, maxEdge) }
            }
        } catch (e: RuntimeException) {
            null
        } ?: return null

        return try {
            ByteArrayOutputStream().use { out ->
                if (bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(0, 100), out)) {
                    out.toByteArray()
                } else {
                    null
                }
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun scaleToFit(source: Bitmap, maxEdge: Int): Bitmap {
        val longest = max(source.width, source.height)
        if (longest <= maxEdge) return source
        val scale = maxEdge.toFloat() / longest
        val scaled = Bitmap.createScaledBitmap(
            source,
            max((source.width * scale).roundToInt(), 1),
            max((source.height * scale).roundToInt(), 1),
            true,
        )
        if (scaled !== source) source.recycle()
        return scaled
    }
}

/** (code, message) for a failed `setDataSource`, matching `AssetEntityVideoErrorCode` on the Dart side. */
private fun mapOpenError(error: Exception): Pair<String, String> {
    val cause = error.cause ?: error
    return when {
        error is SecurityException || cause is SecurityException ->
            "permissionDenied" to "No access to this asset."
        cause is FileNotFoundException || error is IllegalArgumentException ->
            "assetNotFound" to "Asset is no longer in the library."
        else -> "playbackFailed" to (error.message ?: "Could not open this video.")
    }
}
