package com.fluttercandies.photo_manager_video_player

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import kotlin.math.abs

/**
 * Finds the video frame that the MediaStore thumbnail shows, so playback can
 * start on that exact frame instead of jumping away from the thumbnail.
 *
 * `ThumbnailUtils` takes the sync frame nearest the middle, so that one is
 * computed without decoding and confirmed with a single decode. Thumbnails
 * made another way are looked for among the other candidates. Results are kept
 * per asset version, so each video is decoded once per process.
 */
internal object ThumbnailFrame {
    private const val SIDE = 32

    /** Mean grey difference (0–255) below which a candidate is the same frame; other frames measure above 20. */
    private const val SAME_FRAME = 8.0

    /** Representative frame of an MP4: the largest of the first sync frames (`SampleTable::findThumbnailSample`). */
    private const val REPRESENTATIVE_SCAN = 20

    /** Most recently used first out; keyed by the file's version, so an edited video is looked up again. */
    private const val REMEMBERED = 512

    /** Remembered for a thumbnail that is no candidate frame. */
    private const val NO_MATCH = -1L

    private val located = object : LinkedHashMap<String, Long>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > REMEMBERED
    }

    /**
     * Presentation time in microseconds of the thumbnail's frame, or null when
     * no candidate is that frame (cover art that is no frame), or anything cannot be
     * read. A thumbnail that was read is remembered either way; an unreadable
     * one is tried again next time.
     */
    fun locateUs(context: Context, uri: Uri): Long? {
        // Below API 27 a candidate can only be decoded at full size, which a 4K video cannot afford.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return null
        return try {
            // Without a version the URI alone keys it; an edit is then only noticed by a new process.
            val key = versionKey(context, uri) ?: uri.toString()
            synchronized(located) { located[key] }?.let { known -> return known.takeIf { it >= 0 } }
            val found = findUs(context, uri) ?: return null
            synchronized(located) { located[key] = found }
            found.takeIf { it >= 0 }
        } catch (e: Throwable) {
            // Out of memory or a decoder failure means no position, never a crash on the executor.
            null
        }
    }

    private fun versionKey(context: Context, uri: Uri): String? {
        val columns = arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE)
        val version = try {
            context.contentResolver.query(uri, columns, null, null, null)?.use { c ->
                if (c.moveToFirst()) "${c.getLong(0)}:${c.getLong(1)}" else null
            }
        } catch (e: Exception) {
            null
        }
        return version?.let { "$uri@$it" }
    }

    /** The matching candidate, [NO_MATCH] when the thumbnail is no candidate frame, null when it cannot be read. */
    private fun findUs(context: Context, uri: Uri): Long? {
        val thumbnail = systemThumbnail(context, uri) ?: return null
        val target = try {
            grey(thumbnail)
        } finally {
            thumbnail.recycle()
        }
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            // `ThumbnailUtils` shows embedded cover art instead of a frame when there is one;
            // cameras embed their first frame, so that is checked first.
            val hasCoverArt = retriever.embeddedPicture != null
            val durationUs =
                (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) *
                    1000
            val tried = mutableSetOf<Long>()
            fun differenceAt(timeUs: Long): Double? {
                if (timeUs < 0 || !tried.add(timeUs)) return null
                val frame = frameAt(retriever, timeUs) ?: return null
                return try {
                    difference(target, grey(frame))
                } finally {
                    frame.recycle()
                }
            }
            fun matches(timeUs: Long) = (differenceAt(timeUs) ?: Double.MAX_VALUE) < SAME_FRAME
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(context, uri, null)
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                } ?: return NO_MATCH
                extractor.selectTrack(track)
                if (hasCoverArt) {
                    val first = syncAt(extractor, 0L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    if (matches(first)) return first
                }
                val closest = syncAt(extractor, durationUs / 2, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                if (matches(closest)) return closest
                // Off the rule, the closest of the rest wins, so near-static footage still lands on the right one.
                return otherCandidatesUs(extractor, durationUs / 2)
                    .mapNotNull { t -> differenceAt(t)?.let { t to it } }
                    .filter { it.second < SAME_FRAME }
                    .minByOrNull { it.second }?.first ?: NO_MATCH
            } finally {
                extractor.release()
            }
        } catch (e: Exception) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // Releasing can throw IOException on API 29+; nothing is left to clean up.
            }
        }
    }

    private fun syncAt(extractor: MediaExtractor, timeUs: Long, mode: Int): Long {
        extractor.seekTo(timeUs, mode)
        return extractor.sampleTime
    }

    /** Tried only when the `ThumbnailUtils` frame does not match: representative, first, then neighbours. */
    private fun otherCandidatesUs(extractor: MediaExtractor, middleUs: Long): List<Long> {
        val first = syncAt(extractor, 0L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        var representative = first
        var largest = -1L
        var at = first
        for (i in 0 until REPRESENTATIVE_SCAN) {
            if (at < 0) break
            val size = extractor.sampleSize
            if (size > largest) {
                largest = size
                representative = at
            }
            val following = syncAt(extractor, at + 1, MediaExtractor.SEEK_TO_NEXT_SYNC)
            if (following <= at) break
            at = following
        }
        val previous = syncAt(extractor, middleUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val next = syncAt(extractor, middleUs, MediaExtractor.SEEK_TO_NEXT_SYNC)
        return listOf(representative, first, previous, next).filter { it >= 0 }.distinct()
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O_MR1)
    private fun frameAt(retriever: MediaMetadataRetriever, timeUs: Long): Bitmap? =
        retriever.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, SIDE * 4, SIDE * 4)

    @Suppress("DEPRECATION")
    private fun systemThumbnail(context: Context, uri: Uri): Bitmap? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.contentResolver.loadThumbnail(uri, Size(SIDE * 4, SIDE * 4), null)
        } else {
            MediaStore.Video.Thumbnails.getThumbnail(
                context.contentResolver,
                ContentUris.parseId(uri),
                MediaStore.Video.Thumbnails.MINI_KIND,
                null,
            )
        }
    } catch (e: Exception) {
        null
    }

    private fun grey(bitmap: Bitmap): IntArray {
        val small = Bitmap.createScaledBitmap(bitmap, SIDE, SIDE, true)
        val pixels = IntArray(SIDE * SIDE)
        small.getPixels(pixels, 0, SIDE, 0, 0, SIDE, SIDE)
        if (small !== bitmap) small.recycle()
        return IntArray(pixels.size) { i ->
            val p = pixels[i]
            ((p shr 16 and 0xFF) * 299 + (p shr 8 and 0xFF) * 587 + (p and 0xFF) * 114) / 1000
        }
    }

    private fun difference(a: IntArray, b: IntArray): Double =
        a.indices.sumOf { abs(a[it] - b[it]) }.toDouble() / a.size
}
