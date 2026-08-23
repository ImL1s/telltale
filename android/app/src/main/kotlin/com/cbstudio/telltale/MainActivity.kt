package com.cbstudio.telltale

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLATFORM_METADATA_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPlatformMetadata" -> result.success(platformMetadata())
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun platformMetadata(): Map<String, Any> {
        val packageInfo = packageManager.getPackageInfo(packageName, 0)
        val longVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            packageInfo.versionCode.toLong()
        }

        return mapOf(
            "applicationId" to packageName,
            "appVersion" to (packageInfo.versionName ?: UNKNOWN),
            "appBuild" to longVersionCode.toString(),
            "platform" to "android",
            "osVersion" to (Build.VERSION.RELEASE ?: UNKNOWN),
            "manufacturer" to (Build.MANUFACTURER ?: UNKNOWN),
            "model" to (Build.MODEL ?: UNKNOWN),
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private companion object {
        const val PLATFORM_METADATA_CHANNEL = "com.cbstudio.telltale/platform_metadata"
        const val UNKNOWN = "unknown"
    }
}
