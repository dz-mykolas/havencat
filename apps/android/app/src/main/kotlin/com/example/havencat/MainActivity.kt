package com.example.havencat

import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        generationBackgroundChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOST_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureRunning" -> result.success(ensureGenerationHost())
                "stop" -> {
                    stopService(Intent(this, GenerationForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        generationBackgroundChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun ensureGenerationHost(): Boolean {
        val intent = Intent(this, GenerationForegroundService::class.java).apply {
            action = GenerationForegroundService.ACTION_START
        }
        ContextCompat.startForegroundService(this, intent)
        return true
    }

    companion object {
        private const val HOST_CHANNEL = "com.example.havencat/generation_host"
        private const val BACKGROUND_CHANNEL =
            "com.example.havencat/generation_background"

        @Volatile
        private var generationBackgroundChannel: MethodChannel? = null

        fun notifyBackgroundTimeExpired() {
            Handler(Looper.getMainLooper()).post {
                generationBackgroundChannel?.invokeMethod(
                    "backgroundTimeExpired",
                    null,
                )
            }
        }
    }
}
