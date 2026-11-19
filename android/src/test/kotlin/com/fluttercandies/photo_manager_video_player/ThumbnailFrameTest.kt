package com.fluttercandies.photo_manager_video_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.Executor

/** A probe whose frames differ from the thumbnail by [differences]; missing times cannot be decoded. */
private class FakeProbe(
    override val hasCoverArt: Boolean = false,
    override val middleUs: Long = 5_000_000,
    private val first: Long = 0,
    private val closest: Long = 5_000_000,
    private val previous: Long = 4_000_000,
    private val next: Long = 6_000_000,
    private val representative: Long = 1_000_000,
    private val differences: Map<Long, Double> = emptyMap(),
    private val failing: Boolean = false,
) : FrameProbe {
    val decoded = mutableListOf<Long>()
    var representativeCalls = 0

    override fun firstSync() = first
    override fun closestSync(us: Long) = closest
    override fun previousSync(us: Long) = previous
    override fun nextSync(us: Long) = next
    override fun representative(): Long {
        representativeCalls++
        return representative
    }

    override fun difference(us: Long): Double? {
        if (failing) throw IllegalStateException("decoder failed")
        decoded += us
        return differences[us]
    }
}

/** Runs queued tasks only when told to, like the single lookup thread. */
private class ManualExecutor : Executor {
    val queue = ArrayDeque<Runnable>()
    override fun execute(command: Runnable) {
        queue.addLast(command)
    }

    fun runAll() {
        while (queue.isNotEmpty()) queue.removeFirst().run()
    }
}

class ThumbnailMatchTest {
    @Test
    fun coverArtIsTriedOnTheFirstFrameFirst() {
        val probe = FakeProbe(hasCoverArt = true, differences = mapOf(0L to 1.5, 5_000_000L to 1.0))
        assertEquals(0L, ThumbnailMatch.locate(probe))
        assertEquals(listOf(0L), probe.decoded)
    }

    @Test
    fun theThumbnailUtilsFrameNeedsNoOtherCandidate() {
        val probe = FakeProbe(differences = mapOf(5_000_000L to 3.2))
        assertEquals(5_000_000L, ThumbnailMatch.locate(probe))
        assertEquals(listOf(5_000_000L), probe.decoded)
        assertEquals(0, probe.representativeCalls)
    }

    @Test
    fun offTheRuleTheClosestMatchWins() {
        val probe = FakeProbe(differences = mapOf(5_000_000L to 30.0, 1_000_000L to 6.0, 4_000_000L to 3.0))
        assertEquals(4_000_000L, ThumbnailMatch.locate(probe))
    }

    @Test
    fun eachTimeIsDecodedOnce() {
        val probe = FakeProbe(
            hasCoverArt = true,
            representative = 0,
            previous = 5_000_000,
            differences = mapOf(0L to 40.0, 5_000_000L to 40.0, 6_000_000L to 2.0),
        )
        assertEquals(6_000_000L, ThumbnailMatch.locate(probe))
        assertEquals(probe.decoded.distinct(), probe.decoded)
    }

    @Test
    fun noMatchOrNoFrameIsNull() {
        assertNull(ThumbnailMatch.locate(FakeProbe(differences = mapOf(5_000_000L to 30.0))))
        assertNull(ThumbnailMatch.locate(FakeProbe()))
    }

    @Test(expected = IllegalStateException::class)
    fun aProbeFailureIsLeftToTheCaller() {
        ThumbnailMatch.locate(FakeProbe(failing = true))
    }

    @Test
    fun greyAndDifference() {
        assertEquals(listOf(255, 0, 76), ThumbnailMatch.grey(intArrayOf(0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFFFF0000.toInt())).toList())
        assertEquals(0.0, ThumbnailMatch.difference(intArrayOf(1, 2), intArrayOf(1, 2)), 0.0)
        assertEquals(2.0, ThumbnailMatch.difference(intArrayOf(0, 4), intArrayOf(2, 2)), 0.0)
    }
}

class ThumbnailLookupsTest {
    private val executor = ManualExecutor()
    private val posted = ArrayDeque<Runnable>()
    private val lookups = ThumbnailLookups(executor) { posted.addLast(it) }
    private val replies = mutableListOf<Long?>()
    private var locates = 0

    private var attached = true

    /** Runs the queue and then the replies it posted, as the main thread would. */
    private fun drain() {
        executor.runAll()
        while (posted.isNotEmpty()) posted.removeFirst().run()
    }

    private fun request(
        key: String = "content://media/1",
        version: () -> String? = { "v1" },
        found: () -> Long? = { 7L },
    ) = lookups.request(
        key,
        isAttached = { attached },
        version = { version() },
        locate = {
            locates++
            found()
        },
        reply = { replies += it },
    )

    @Test
    fun aRequestQueuedBehindTheSameAssetIsAnsweredFromMemory() {
        request()
        request()
        drain()
        assertEquals(1, locates)
        assertEquals(listOf(7L, 7L), replies)
    }

    @Test
    fun aFailureIsRememberedAsNullAndStillAnswered() {
        request(found = { throw OutOfMemoryError() })
        request()
        drain()
        assertEquals(1, locates)
        assertEquals(listOf<Long?>(null, null), replies)
    }

    @Test
    fun aNewVersionIsLookedUpAgain() {
        request(version = { "v1" })
        request(version = { "v2" }, found = { 9L })
        drain()
        assertEquals(listOf<Long?>(7L, 9L), replies)
    }

    @Test
    fun withoutAVersionTheKeyAloneIsRemembered() {
        request(version = { null })
        request(version = { throw IllegalStateException("no row") })
        drain()
        assertEquals(1, locates)
    }

    @Test
    fun aDetachedEngineGetsNullWithoutADecode() {
        attached = false
        request()
        drain()
        assertEquals(0, locates)
        assertEquals(listOf<Long?>(null), replies)
    }

    @Test
    fun theLeastRecentlyUsedAssetIsForgottenPastTheLimit() {
        for (i in 0 until ThumbnailLookups.REMEMBERED) request(key = "content://media/$i")
        request(key = "content://media/0") // used again, so 1 is now the least recent
        request(key = "content://media/new")
        drain()
        val before = locates
        request(key = "content://media/0")
        drain()
        assertEquals("key 0 was kept", before, locates)
        request(key = "content://media/1")
        drain()
        assertEquals("key 1 was forgotten", before + 1, locates)
    }

    @Test
    fun theReplyWaitsForThePostedTask() {
        request()
        executor.runAll()
        assertEquals(emptyList<Long?>(), replies)
        while (posted.isNotEmpty()) posted.removeFirst().run()
        assertEquals(listOf<Long?>(7L), replies)
    }

    @Test
    fun anEngineThatDetachesDuringTheLookupGetsNull() {
        request(found = {
            attached = false
            7L
        })
        drain()
        assertEquals(listOf<Long?>(null), replies)
    }
}
