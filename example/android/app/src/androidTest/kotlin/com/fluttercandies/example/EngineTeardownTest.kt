package com.fluttercandies.example

import androidx.test.platform.app.InstrumentationRegistry
import com.fluttercandies.photo_manager_video_player.PhotoManagerVideoPlayerPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Test

/** An engine torn down without Dart disposing its controllers must not leak players. */
class EngineTeardownTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private val ignoreResult = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }

    @Test
    fun engineTeardownReleasesPlayersWithoutDartDispose() {
        instrumentation.runOnMainSync {
            val engine = FlutterEngine(instrumentation.targetContext)
            val plugin = engine.plugins.get(PhotoManagerVideoPlayerPlugin::class.java)
                as PhotoManagerVideoPlayerPlugin
            // An id that is never prepared still owns an ExoPlayer and a texture.
            plugin.onMethodCall(MethodCall("create", mapOf("assetId" to "1")), ignoreResult)
            plugin.onMethodCall(MethodCall("create", mapOf("assetId" to "2")), ignoreResult)
            assertEquals(2, plugin.playerCount)

            engine.destroy()

            assertEquals(0, plugin.playerCount)
        }
    }
}
