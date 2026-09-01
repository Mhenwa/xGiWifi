package com.example.xgiwifi

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Locale

class MainActivity : FlutterActivity() {
    private companion object {
        const val NETWORK_IDENTITY_CHANNEL = "xgiwifi/network_identity"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NETWORK_IDENTITY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "getNetworkIdentity") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            try {
                val identity = resolveWifiIdentity()
                if (identity == null) {
                    result.error(
                        "NETWORK_IDENTITY_UNAVAILABLE",
                        "No active Wi-Fi IPv4 identity was found",
                        null,
                    )
                } else {
                    result.success(identity)
                }
            } catch (error: Exception) {
                result.error(
                    "NETWORK_IDENTITY_ERROR",
                    error.message ?: error.javaClass.simpleName,
                    null,
                )
            }
        }
    }

    private fun resolveWifiIdentity(): Map<String, String>? {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val activeWifiNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.activeNetwork?.takeIf { network ->
                connectivityManager.getNetworkCapabilities(network)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
            }
        } else {
            null
        }
        val wifiNetwork = activeWifiNetwork ?: connectivityManager.allNetworks.firstOrNull { network ->
            connectivityManager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
        val linkProperties = wifiNetwork?.let(connectivityManager::getLinkProperties)
        val linkAddress = linkProperties?.linkAddresses?.firstOrNull { value ->
            value.address is Inet4Address &&
                !value.address.isLoopbackAddress &&
                !value.address.isLinkLocalAddress &&
                !value.address.isAnyLocalAddress
        }

        if (linkAddress != null) {
            val interfaceName = linkProperties.interfaceName.orEmpty()
            val networkInterface = runCatching {
                interfaceName.takeIf(String::isNotEmpty)?.let(NetworkInterface::getByName)
                    ?: NetworkInterface.getByInetAddress(linkAddress.address)
            }.getOrNull()
            val gatewayIp = linkProperties.routes
                .asSequence()
                // Prefer the default IPv4 route.  A captive network can also
                // expose a host-specific route, so retain the first usable
                // IPv4 gateway as a fallback when no default route is listed.
                .sortedByDescending { route -> route.isDefaultRoute }
                .mapNotNull { route ->
                    val gateway = route.gateway
                    if (gateway is Inet4Address &&
                        !gateway.isLoopbackAddress &&
                        !gateway.isLinkLocalAddress &&
                        !gateway.isAnyLocalAddress
                    ) {
                        gateway.hostAddress
                    } else {
                        null
                    }
                }
                .firstOrNull()
                .orEmpty()
            return buildIdentity(
                address = linkAddress.address,
                networkInterface = networkInterface,
                interfaceName = interfaceName,
                gatewayIp = gatewayIp,
            )
        }

        @Suppress("DEPRECATION")
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (!wifiManager.isWifiEnabled) {
            return null
        }
        @Suppress("DEPRECATION")
        val wifiInfo = wifiManager.connectionInfo
        @Suppress("DEPRECATION")
        val ipAddress = wifiInfo.ipAddress
        if (ipAddress == 0) {
            return null
        }

        val address = InetAddress.getByAddress(
            byteArrayOf(
                (ipAddress and 0xff).toByte(),
                (ipAddress shr 8 and 0xff).toByte(),
                (ipAddress shr 16 and 0xff).toByte(),
                (ipAddress shr 24 and 0xff).toByte(),
            ),
        )
        val networkInterface = runCatching {
            NetworkInterface.getByInetAddress(address)
        }.getOrNull()
        return buildIdentity(
            address = address,
            networkInterface = networkInterface,
            interfaceName = networkInterface?.name.orEmpty(),
            gatewayIp = "",
        )
    }

    private fun buildIdentity(
        address: InetAddress,
        networkInterface: NetworkInterface?,
        interfaceName: String,
        gatewayIp: String,
    ): Map<String, String>? {
        val userIp = address.hostAddress.orEmpty()
        if (address !is Inet4Address ||
            userIp == "0.0.0.0" ||
            address.isLoopbackAddress ||
            address.isLinkLocalAddress ||
            address.isAnyLocalAddress
        ) {
            return null
        }

        val candidateMac = runCatching {
            formatMac(networkInterface?.hardwareAddress)
        }.getOrDefault("")
        return mapOf(
            "userIp" to userIp,
            "userMac" to candidateMac.takeIf(::isUsableMac).orEmpty(),
            "interfaceName" to interfaceName,
            "staModel" to staModel(),
            "gatewayIp" to gatewayIp,
        )
    }

    @Suppress("DEPRECATION")
    private fun staModel(): String {
        return listOf(
            Build.MANUFACTURER,
            Build.MODEL,
            Build.VERSION.SDK,
            Build.VERSION.RELEASE,
        ).joinToString(",")
    }

    private fun formatMac(bytes: ByteArray?): String {
        if (bytes == null || bytes.isEmpty()) {
            return ""
        }
        return bytes.joinToString(":") { byte ->
            String.format(Locale.US, "%02X", byte.toInt() and 0xff)
        }
    }

    private fun isUsableMac(value: String): Boolean {
        return value.matches(Regex("^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$")) &&
            value != "00:00:00:00:00:00" &&
            value != "02:00:00:00:00:00"
    }
}
