package com.cbstudio.telltale

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIFI_ROUTE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bind" -> bindWifiRoute(call.argument<String>("host"), result)
                "release" -> releaseWifiRoute(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FORM_FACTOR_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // The platform's own answer, not an inference from window
                // geometry: a narrow split-screen phone is still a phone.
                "isWatch" -> result.success(
                    packageManager.hasSystemFeature(
                        android.content.pm.PackageManager.FEATURE_WATCH,
                    ),
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_WAKE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "keepOn" -> {
                    // A driving dashboard that dozes off mid-corner is worse
                    // than the battery it saves. Scoped to this window only:
                    // the flag clears with the activity, so a crash cannot
                    // leave the screen pinned on.
                    val on = call.argument<Boolean>("on") == true
                    if (on) {
                        window.addFlags(
                            android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                        )
                    } else {
                        window.clearFlags(
                            android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Binds this process to a connected Wi-Fi network, validated or not.
     *
     * An ELM327 soft AP never validates — it has no internet — so requiring
     * NET_CAPABILITY_VALIDATED here would refuse the exact network this
     * exists for. When Android 12+ dual-STA (Samsung Intelligent Wi-Fi) has
     * two Wi-Fi networks up at once, the candidate whose link subnet actually
     * contains the adapter's address is tried first — binding succeeding says
     * nothing about the destination being reachable — then the unvalidated
     * ones, since the validated one is the home network. Error messages are
     * transcript detail, not screen text; the Dart side owns the user-facing
     * sentence.
     *
     * This handler MUST stay synchronous on the platform thread: the Dart
     * side compensates an abandoned (timed-out) bind by enqueuing a release
     * on this same channel, and that compensation is sound only because
     * channel messages execute here in arrival order. Offloading either call
     * to another thread silently breaks the orphaned-binding guarantee. Both
     * calls are short binder IPC, so staying synchronous is also correct for
     * responsiveness.
     */
    private fun bindWifiRoute(host: String?, result: MethodChannel.Result) {
        val manager = connectivityManagerOr(result) ?: return
        // allNetworks is deprecated in favor of an async callback API; a
        // synchronous snapshot is exactly what one bind-then-connect needs.
        @Suppress("DEPRECATION")
        val wifi = manager.allNetworks.mapNotNull { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) {
                return@mapNotNull null
            }
            // A network still connecting has no link addresses yet and cannot
            // carry a socket; admitting it only manufactures spurious ties.
            val link = manager.getLinkProperties(network)
            if (link == null || link.linkAddresses.isEmpty()) {
                return@mapNotNull null
            }
            network to capabilities
        }
        if (wifi.isEmpty()) {
            result.error(
                "no_wifi_network",
                "ConnectivityManager reports no TRANSPORT_WIFI network",
                null,
            )
            return
        }
        // The Dart side only forwards numeric literals, but this handler must
        // stay synchronous, so it does not trust that contract with a blocking
        // DNS lookup on the line: anything that is not shaped like a literal
        // is dropped here too, and simply loses the reachability preference.
        val target = host?.takeIf(::isNumericHost)?.let {
            try {
                java.net.InetAddress.getByName(it)
            } catch (_: Exception) {
                null
            }
        }
        // ELM327 hosts are always on-link, so link subnets are the whole
        // route story here; gateway routes are deliberately not consulted.
        val keyed = wifi.map { (network, capabilities) ->
            val key = Pair(
                target != null && linkContains(manager, network, target),
                // Negated so the adapter-like (never validated) sorts higher.
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            )
            network to key
        }.sortedWith(
            compareByDescending<Pair<android.net.Network, Pair<Boolean, Boolean>>> { it.second.first }
                .thenByDescending { it.second.second },
        )
        // Binding succeeding proves nothing about the destination being
        // reachable, and allNetworks' order carries no routing meaning — so a
        // genuine tie at the top is a coin flip that, bound deterministically,
        // would time out the same way on every retry with the adapter taking
        // the blame. Refusing with a nameable reason is the honest outcome.
        val topKey = keyed.first().second
        val top = keyed.filter { it.second == topKey }
        if (top.size > 1) {
            result.error(
                "ambiguous_wifi_network",
                "${top.size} Wi-Fi networks are equally plausible routes " +
                    "toward the adapter",
                null,
            )
            return
        }
        // Only the unique top candidate is bound. Falling through to a
        // lower-ranked network would bind one already known not to reach the
        // adapter, hand back success, and spend the whole connect budget
        // timing out with the adapter taking the blame — the same failure
        // mode the tie refusal above exists to prevent.
        val (topNetwork, _) = keyed.first()
        if (!manager.bindProcessToNetwork(topNetwork)) {
            result.error(
                "bind_refused",
                "bindProcessToNetwork returned false for the selected " +
                    "Wi-Fi candidate",
                null,
            )
            return
        }
        result.success(null)
    }

    /**
     * IPv6 literals are colon-and-hex only (a v4-mapped tail adds dots);
     * anything else must be dotted-quad. `foo:bar` would fall through
     * InetAddress.getByName to a real DNS lookup, which this synchronous
     * handler must never perform.
     */
    private fun isNumericHost(host: String): Boolean = when {
        host.contains(':') -> host.all {
            it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.'
        }
        else -> host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))
    }

    /** Whether one of [network]'s link subnets contains [target]. */
    private fun linkContains(
        manager: ConnectivityManager,
        network: android.net.Network,
        target: java.net.InetAddress,
    ): Boolean {
        val link = manager.getLinkProperties(network) ?: return false
        return link.linkAddresses.any { linkAddress ->
            sameSubnet(linkAddress.address, target, linkAddress.prefixLength)
        }
    }

    private fun sameSubnet(
        a: java.net.InetAddress,
        b: java.net.InetAddress,
        prefixLength: Int,
    ): Boolean {
        val left = a.address
        val right = b.address
        if (left.size != right.size) return false
        var bits = prefixLength
        for (i in left.indices) {
            if (bits <= 0) break
            val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
            if ((left[i].toInt() and mask) != (right[i].toInt() and mask)) return false
            bits -= 8
        }
        return true
    }

    private fun releaseWifiRoute(result: MethodChannel.Result) {
        val manager = connectivityManagerOr(result) ?: return
        if (!manager.bindProcessToNetwork(null)) {
            result.error(
                "release_refused",
                "bindProcessToNetwork(null) returned false",
                null,
            )
            return
        }
        result.success(null)
    }

    private fun connectivityManagerOr(
        result: MethodChannel.Result,
    ): ConnectivityManager? {
        val manager = getSystemService(ConnectivityManager::class.java)
        if (manager == null) {
            result.error(
                "no_connectivity_service",
                "ConnectivityManager is unavailable",
                null,
            )
        }
        return manager
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
        const val WIFI_ROUTE_CHANNEL = "com.cbstudio.telltale/wifi_route"
        const val SCREEN_WAKE_CHANNEL = "com.cbstudio.telltale/screen_wake"
        const val FORM_FACTOR_CHANNEL = "com.cbstudio.telltale/form_factor"
        const val UNKNOWN = "unknown"
    }
}
