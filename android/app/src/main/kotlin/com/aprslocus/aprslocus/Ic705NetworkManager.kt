// SPDX-License-Identifier: GPL-2.0-or-later
// See LICENSING.md: this file is additionally available under GPL-2.0-or-later.

package com.aprslocus.aprslocus

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * Android 平台 Wi-Fi 网络选择器与平台通道（对应 mod 的 Ic705NetworkManager.kt）。
 *
 * ## issue #35：连上电台热点后移动数据被「抢走」，APRS-IS 连不上
 *
 * 现象：手机连上 IC-705 发出的 Wi-Fi 热点后，系统把这条 Wi-Fi 当成**默认上网
 * 通道**，于是暂停移动数据 —— 可电台热点没有外网，APRS-IS 就连不上。
 *
 * 根因：电台热点只是**本地局域网**，不该需要「默认上网通道」这个身份。
 *
 * 修法（分层，逐层保底）：
 *   1. **申请一条「不含 INTERNET 能力」的 Wi-Fi 网络**（[requestRadioNetwork]，
 *      Android 10+）：系统把它当本地网络，**移动数据保持为默认上网通道**，
 *      正对应 issue 里建议的 WifiNetworkRequest 思路。
 *   2. **电台 UDP 套接字按该 Wi-Fi 的 IPv4 绑定**（本类只返回地址；绑定由 Dart
 *      的 `RawDatagramSocket.bind(sourceAddress)` 完成）：报文一定从 Wi-Fi 出去。
 *   3. **兜底**：万一系统仍把「无外网的热点」当成了默认网络（个别机型/版本），
 *      则把本进程绑到那条**有外网的网络**（移动数据）上 —— 否则移动数据被暂停，
 *      用户连 APRS-IS 都上不了。第 2 步保证电台流量照走 Wi-Fi，两不耽误。
 *
 * 兼容：minSdk = 24（Android 7）。API < 29 没有「非默认 Wi-Fi 请求」语义，
 * 退回「从已连接网络里挑 Wi-Fi」，第 2、3 步仍然生效。
 */
class Ic705NetworkManager(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "com.aprslocus/ic705_network"
    }

    /** 由 requestRadioNetwork 选中、供后续查询复用的非默认 Wi-Fi 网络。 */
    private val selectedNetworks = LinkedHashMap<Long, Network>()

    /** 已发出的「本地 Wi-Fi」请求回调（非空即表示已持有，避免重复请求）。 */
    private val localCallbacks = mutableListOf<ConnectivityManager.NetworkCallback>()

    /** 有外网的网络（移动数据等），兜底时把进程绑到它上面。 */
    private val internetNetworks = LinkedHashMap<Long, Network>()
    private var internetCallback: ConnectivityManager.NetworkCallback? = null

    /** 是否已把本进程绑到某条有外网的网络上（释放时需复位）。 */
    private var processBound = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "findRadioNetwork" -> result.success(radioNetworkInfo())
                "requestRadioNetwork" -> {
                    requestLocalWifiNetwork()
                    result.success(radioNetworkInfo())
                }
                "releaseRadioNetwork" -> {
                    releaseLocalWifiNetwork()
                    result.success(true)
                }
                "status" -> result.success(radioNetworkStatus())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("NET_ERROR", e.message, null)
        }
    }

    private fun connectivityManager(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private fun notFoundInfo(): Map<String, Any?> = mapOf("status" to "NOT_FOUND")

    // ── Android 10+：申请一条只连本地、不抢默认路由的 Wi-Fi 网络 ──

    private fun requestLocalWifiNetwork() {
        val cm = connectivityManager() ?: return
        if (localCallbacks.isNotEmpty()) return // 已持有一条，别重复请求
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 关键：**不加 INTERNET 能力**。带 INTERNET 的请求会去抢默认上网通道
            // （正是本 issue 的病根）；不带 INTERNET 时系统把它当本地网络，移动
            // 数据仍是默认 —— 这正是「既能连电台、又能上 APRS-IS」要的效果。
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    synchronized(selectedNetworks) {
                        selectedNetworks[network.networkHandle] = network
                    }
                }

                override fun onLost(network: Network) {
                    synchronized(selectedNetworks) {
                        selectedNetworks.remove(network.networkHandle)
                    }
                }
            }
            localCallbacks.add(callback)
            try {
                cm.requestNetwork(request, callback)
            } catch (_: Exception) {
                localCallbacks.remove(callback)
            }
        }
        ensureInternetReachable(cm)
    }

    private fun releaseLocalWifiNetwork() {
        val cm = connectivityManager() ?: return
        for (cb in localCallbacks) {
            runCatching { cm.unregisterNetworkCallback(cb) }
        }
        localCallbacks.clear()
        synchronized(selectedNetworks) { selectedNetworks.clear() }
        internetCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        internetCallback = null
        synchronized(internetNetworks) { internetNetworks.clear() }
        if (processBound) {
            cm.bindProcessToNetwork(null)
            processBound = false
        }
    }

    /**
     * 兜底：若默认网络是一条**没有外网**的 Wi-Fi（电台热点挤掉了移动数据），
     * 就把本进程绑到一条有外网的网络上，让 APRS-IS 恢复。
     *
     * 第 1 步（非 INTERNET 请求）通常已让移动数据保持默认，这里只在「系统仍然
     * 抢了默认」的病态下才动手，绝不误伤正常的 Wi-Fi 上网。
     */
    private fun ensureInternetReachable(cm: ConnectivityManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        registerInternetCallback(cm)

        if (defaultHasInternet(cm)) return // 默认网络能上网，无需兜底

        val internet = synchronized(internetNetworks) {
            internetNetworks.values.firstOrNull()
        } ?: return
        cm.bindProcessToNetwork(internet)
        processBound = true
    }

    private fun registerInternetCallback(cm: ConnectivityManager) {
        if (internetCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(internetNetworks) {
                    internetNetworks[network.networkHandle] = network
                }
            }

            override fun onLost(network: Network) {
                synchronized(internetNetworks) {
                    internetNetworks.remove(network.networkHandle)
                }
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { cm.registerNetworkCallback(request, cb) }
            .onSuccess { internetCallback = cb }
    }

    private fun defaultHasInternet(cm: ConnectivityManager): Boolean {
        val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // ── 通用：找 Wi-Fi 网络并取 IPv4 ──

    fun findWifiNetwork(): Network? {
        val cm = connectivityManager() ?: return null

        // 优先用它向系统申请到的「本地 Wi-Fi」。
        synchronized(selectedNetworks) {
            selectedNetworks.values.firstOrNull()?.let { return it }
        }

        // 其次：若默认网络本身就是 Wi-Fi（低版本 / 已手工连上），就用它。
        val active = cm.activeNetwork
        if (active != null) {
            val caps = cm.getNetworkCapabilities(active)
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                return active
            }
        }

        // 最后：所有网络里挑一条 Wi-Fi。
        return try {
            @Suppress("DEPRECATION")
            cm.allNetworks.firstOrNull { net ->
                cm.getNetworkCapabilities(net)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
            }
        } catch (_: Exception) {
            null
        }
    }

    fun radioNetworkInfo(): Map<String, Any?> {
        val cm = connectivityManager()
            ?: return mapOf("status" to "NO_CONNECTIVITY_SERVICE")
        val network = findWifiNetwork() ?: return notFoundInfo()
        return mapOf(
            "status" to "AVAILABLE",
            "networkHandle" to network.networkHandle,
            "ipv4Address" to ipv4Of(cm, network),
        )
    }

    private fun ipv4Of(cm: ConnectivityManager, network: Network): String? {
        val linkProps: LinkProperties = cm.getLinkProperties(network) ?: return null
        for (linkAddr in linkProps.linkAddresses) {
            val addr = linkAddr.address
            if (addr is Inet4Address && !addr.isAnyLocalAddress && !addr.isLoopbackAddress) {
                return addr.hostAddress
            }
        }
        return null
    }

    /**
     * 「电台 Wi-Fi 是否在抢默认网络」的诊断。
     *
     * [defaultIsWifi] = true 且 [defaultHasInternet] = false 就是 issue #35 的
     * 病态（无外网热点占着默认，移动数据被暂停）；期望是 [defaultHasInternet]
     * 为 true 且电台 Wi-Fi 另走一条（[splitRouting] = true）。
     */
    private fun radioNetworkStatus(): Map<String, Any?> {
        val cm = connectivityManager()
            ?: return mapOf("status" to "NO_CONNECTIVITY_SERVICE")
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        val defaultIsWifi = activeCaps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val defaultHasInternet =
            activeCaps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true

        val radio = findWifiNetwork()
        val sameAsDefault =
            radio != null && active != null && radio.networkHandle == active.networkHandle

        return mapOf(
            "radioAvailable" to (radio != null),
            "radioIpv4" to (radio?.let { ipv4Of(cm, it) }),
            "defaultIsWifi" to defaultIsWifi,
            "defaultHasInternet" to defaultHasInternet,
            // 期望为 true：电台 Wi-Fi ≠ 默认网络（两条路由并存）
            "splitRouting" to (radio != null && !sameAsDefault),
            "processBound" to processBound,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }
}
