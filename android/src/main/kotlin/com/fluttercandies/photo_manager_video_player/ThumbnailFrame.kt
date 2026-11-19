package com.fluttercandies.photo_manager_video_player

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.MediaStore
import android.util.Size
import java.io.Closeable
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** What [ThumbnailMatch] needs to know about one video and its thumbnail. */
internal interface FrameProbe {
    /** Whether the video embeds a picture, which `ThumbnailUtils` shows instead of a frame. */
    val hasCoverArt: Boolean

    /** Half the `METADATA_KEY_DURATION`, the time `ThumbnailUtils` takes its frame near. */
    val middleUs: Long

    fun firstSync(): Long

    fun closestSync(us: Long): Long

    fun previousSync(us: Long): Long

    fun nextSync(us: Long): Long

    /** The largest of the first sync frames (`SampleTable::findThumbnailSample`). */
    fun representative(): Long

    /** Mean grey difference between the thumbnail and the frame at [us], or null when it cannot be decoded. */
    fun difference(us: Long): Double?
}

/**
 * Which sync frame the MediaStore thumbnail shows. The `ThumbnailUtils` frame
 * is tried first, so most videos take one decode; the other candidates only
 * when it does not match. Each time is decoded at most once.
 */
internal object ThumbnailMatch {
    const val SIDE = 32

    /** Mean grey difference (0–255) below which a frame is the thumbnail's; other frames measure far above. */
    const val SAME_FRAME = 8.0

    fun locate(probe: FrameProbe): Long? {
        val seen = HashMap<Long, Double?>()
        fun differenceAt(us: Long): Double? {
            if (us < 0) return null
            if (!seen.containsKey(us)) seen[us] = probe.difference(us)
            return seen[us]
        }
        fun matches(us: Long) = (differenceAt(us) ?: Double.MAX_VALUE) < SAME_FRAME

        // Cameras embed their first frame as the cover art.
        if (probe.hasCoverArt) probe.firstSync().let { if (matches(it)) return it }
        probe.closestSync(probe.middleUs).let { if (matches(it)) return it }
        // Off the rule, the closest of the rest wins, so near-static footage still lands on the right one.
        return listOf(
            probe.representative(),
            probe.firstSync(),
            probe.previousSync(probe.middleUs),
            probe.nextSync(probe.middleUs),
        ).distinct()
            .mapNotNull { us -> differenceAt(us)?.let { us to it } }
            .filter { it.second < SAME_FRAME }
            .minByOrNull { it.second }?.first
    }

    /** Luma of ARGB pixels. */
    fun grey(pixels: IntArray): IntArray = IntArray(pixels.size) { i ->
        val p = pixels[i]
        ((p shr 16 and 0xFF) * 299 + (p shr 8 and 0xFF) * 587 + (p and 0xFF) * 114) / 1000
    }

    fun difference(a: IntArray, b: IntArray): Double =
        a.indices.sumOf { abs(a[it] - b[it]) }.toDouble() / a.size
}

/** [FrameProbe] over a MediaStore video; throws when anything cannot be opened. */
internal class MediaStoreProbe(context: Context, uri: Uri) : FrameProbe, Closeable {
    private val retriever = MediaMetadataRetriever()
    private val extractor = MediaExtractor()
    private val target: IntArray
    override val hasCoverArt: Boolean
    override val middleUs: Long

    init {
        try {
            target = greyOf(thumbnail(context, uri) ?: error("No thumbnail for $uri"))
            retriever.setDataSource(context, uri)
            hasCoverArt = retriever.embeddedPicture != null
            middleUs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L) * 1000 / 2
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: error("No video track in $uri")
            extractor.selectTrack(track)
        } catch (e: Throwable) {
            close()
            throw e
        }
    }

    override fun firstSync() = syncAt(0L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

    override fun closestSync(us: Long) = syncAt(us, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

    override fun previousSync(us: Long) = syncAt(us, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

    override fun nextSync(us: Long) = syncAt(us, MediaExtractor.SEEK_TO_NEXT_SYNC)

    override fun representative(): Long {
        var best = firstSync()
        var largest = -1L
        var at = best
        for (i in 0 until REPRESENTATIVE_SCAN) {
            if (at < 0) break
            val size = extractor.sampleSize
            if (size > largest) {
                largest = size
                best = at
            }
            val following = syncAt(at + 1, MediaExtractor.SEEK_TO_NEXT_SYNC)
            if (following <= at) break
            at = following
        }
        return best
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O_MR1)
    override fun difference(us: Long): Double? {
        val side = ThumbnailMatch.SIDE * 4
        val frame = retriever.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, side, side)
            ?: return null
        return ThumbnailMatch.difference(target, greyOf(frame))
    }

    override fun close() {
        extractor.release()
        try {
            retriever.release()
        } catch (e: Exception) {
            // Releasing can throw IOException on API 29+; nothing is left to clean up.
        }
    }

    private fun syncAt(us: Long, mode: Int): Long {
        extractor.seekTo(us, mode)
        return extractor.sampleTime
    }

    private companion object {
        const val REPRESENTATIVE_SCAN = 20

        @Suppress("DEPRECATION")
        fun thumbnail(context: Context, uri: Uri): Bitmap? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val side = ThumbnailMatch.SIDE * 4
                context.contentResolver.loadThumbnail(uri, Size(side, side), null)
            } else {
                MediaStore.Video.Thumbnails.getThumbnail(
                    context.contentResolver, ContentUris.parseId(uri), MediaStore.Video.Thumbnails.MINI_KIND, null,
                )
            }

        /** Recycles [bitmap]. */
        fun greyOf(bitmap: Bitmap): IntArray {
            val side = ThumbnailMatch.SIDE
            try {
                val small = Bitmap.createScaledBitmap(bitmap, side, side, true)
                val pixels = IntArray(side * side)
                try {
                    small.getPixels(pixels, 0, side, 0, 0, side, side)
                } finally {
                    if (small !== bitmap) small.recycle()
                }
                return ThumbnailMatch.grey(pixels)
            } finally {
                bitmap.recycle()
            }
        }
    }
}

/**
 * Runs thumbnail-frame lookups one at a time for the whole process and
 * replies to each request exactly once, from the end of its own task.
 *
 * Results — found or not, including failures — are remembered per asset
 * version, so a second request for the same video, even one queued while the
 * first ran, is answered from memory. [remembered] is touched on the
 * executor's single thread only.
 */
internal class ThumbnailLookups(
    private val executor: Executor,
    private val post: (Runnable) -> Unit,
) {
    private val remembered = object : LinkedHashMap<String, Long?>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long?>?) = size > REMEMBERED
    }

    /**
     * Replies with the thumbnail frame's time in microseconds, or null.
     * [version] names the asset's current version; [locate] finds the time.
     */
    fun request(
        key: String,
        isAttached: () -> Boolean,
        version: (String) -> String?,
        locate: (String) -> Long?,
        reply: (Long?) -> Unit,
    ) {
        executor.execute {
            val value = if (!isAttached()) {
                null
            } else {
                // Without a version the key alone names it; an edit is then only noticed by a new process.
                val versioned = runCatching { version(key) }.getOrNull()?.let { "$key@$it" } ?: key
                if (remembered.containsKey(versioned)) {
                    remembered[versioned]
                } else {
                    runCatching { locate(key) }.getOrNull().also { remembered[versioned] = it }
                }
            }
            // An engine that detached during the decode is still answered, with null.
            post(Runnable { reply(if (isAttached()) value else null) })
        }
    }

    companion object {
        const val REMEMBERED = 512

        /** The process-wide queue: a background thread that ends after 30 s idle. */
        val shared: ThumbnailLookups by lazy {
            val executor = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue()) { task ->
                Thread({
                    Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                    task.run()
                }, "photo_manager_video_player-thumbnail-frame")
            }.apply { allowCoreThreadTimeOut(true) }
            val main = Handler(Looper.getMainLooper())
            ThumbnailLookups(executor) { main.post(it) }
        }
    }
}

/** Android glue for [ThumbnailLookups]: MediaStore versions and probes. */
internal object ThumbnailFrame {
    fun version(context: Context, uri: Uri): String? {
        val columns = arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE)
        return context.contentResolver.query(uri, columns, null, null, null)?.use { c ->
            if (c.moveToFirst()) "${c.getLong(0)}:${c.getLong(1)}" else null
        }
    }

    /** Below API 27 a candidate can only be decoded at full size, which a 4K video cannot afford. */
    fun locate(context: Context, uri: Uri): Long? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return null
        return MediaStoreProbe(context, uri).use { ThumbnailMatch.locate(it) }
    }
}
