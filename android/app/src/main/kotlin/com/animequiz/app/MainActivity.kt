package com.animequiz.app

import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var tokenProvider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "requestToken") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val nonce = call.argument<String>("nonce")
                val projectNumber = call.argument<Number>("cloudProjectNumber")?.toLong()
                if (nonce.isNullOrEmpty() || projectNumber == null) {
                    result.error("bad_args", "nonce and cloudProjectNumber are required", null)
                    return@setMethodCallHandler
                }
                requestToken(nonce, projectNumber, result)
            }
    }

    private fun requestToken(nonce: String, projectNumber: Long, result: MethodChannel.Result) {
        val existing = tokenProvider
        if (existing != null) {
            fetchToken(existing, nonce, result)
            return
        }
        val manager = IntegrityManagerFactory.createStandard(applicationContext)
        val prepare = StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
            .setCloudProjectNumber(projectNumber)
            .build()
        manager.prepareIntegrityToken(prepare)
            .addOnSuccessListener { provider ->
                tokenProvider = provider
                fetchToken(provider, nonce, result)
            }
            .addOnFailureListener { e ->
                result.error("prepare_failed", e.message, null)
            }
    }

    private fun fetchToken(
        provider: StandardIntegrityManager.StandardIntegrityTokenProvider,
        nonce: String,
        result: MethodChannel.Result,
    ) {
        val request = StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
            .setRequestHash(nonce)
            .build()
        provider.request(request)
            .addOnSuccessListener { response -> result.success(response.token()) }
            .addOnFailureListener { e ->
                // A stale provider is the usual cause; rebuild it on the next call.
                tokenProvider = null
                result.error("request_failed", e.message, null)
            }
    }

    companion object {
        private const val CHANNEL = "com.animequiz.app/play_integrity"
    }
}
