package com.locashare.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * Lightweight HTTPS/HTTP client for background location and heartbeat uploads.
 * Never logs bearer tokens or device coordinates.
 */
object ApiClient {

    enum class Outcome {
        SUCCESS,
        UNAUTHORIZED,
        CLIENT_REJECTED,
        NETWORK_OR_SERVER_ERROR
    }

    data class ApiResult(
        val outcome: Outcome,
        val statusCode: Int,
        val message: String,
        val errorCode: String? = null
    )

    fun isNetworkConnected(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
    }

    fun getNetworkType(context: Context): String {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return "unknown"
        val network = cm.activeNetwork ?: return "none"
        val caps = cm.getNetworkCapabilities(network) ?: return "none"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> "unknown"
            else -> "none"
        }
    }

    fun getBatteryInfo(context: Context): Pair<Int?, Boolean?> {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return Pair(null, null)
        val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val validPct = if (pct in 0..100) pct else null
        val isCharging = bm.isCharging
        return Pair(validPct, isCharging)
    }

    fun uploadLocation(
        context: Context,
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        latitude: Double,
        longitude: Double,
        accuracy: Float?,
        recordedAtIso: String,
        networkType: String
    ): ApiResult {
        val (battery, charging) = getBatteryInfo(context)
        val payload = JSONObject().apply {
            put("device_id", deviceId)
            put("latitude", latitude)
            put("longitude", longitude)
            if (accuracy != null && accuracy > 0f) {
                put("accuracy", accuracy.toDouble())
            }
            put("recorded_at", recordedAtIso)
            if (battery != null) put("battery", battery)
            if (charging != null) put("is_charging", charging)
            put("network_type", networkType)
        }
        return postJson(serverUrl, "/api/location/update.php", deviceToken, payload)
    }

    fun sendHeartbeat(
        context: Context,
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        sharingEnabled: Boolean,
        statusState: String
    ): ApiResult {
        val (battery, charging) = getBatteryInfo(context)
        val payload = JSONObject().apply {
            put("device_id", deviceId)
            put("sharing_enabled", sharingEnabled)
            put("status_state", statusState)
            if (battery != null) put("battery", battery)
            if (charging != null) put("is_charging", charging)
            put("network_type", getNetworkType(context))
        }
        return postJson(serverUrl, "/api/device/heartbeat.php", deviceToken, payload)
    }

    private fun postJson(
        serverUrl: String,
        endpointPath: String,
        deviceToken: String,
        body: JSONObject
    ): ApiResult {
        val base = serverUrl.trim().trimEnd('/')
        if (base.isEmpty()) {
            return ApiResult(Outcome.CLIENT_REJECTED, 0, "Server URL is not configured")
        }

        var conn: HttpURLConnection? = null
        return try {
            val url = URL(base + endpointPath)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 12_000
                doOutput = true
                useCaches = false
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Authorization", "Bearer $deviceToken")
            }

            OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use { writer ->
                writer.write(body.toString())
                writer.flush()
            }

            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val rawResp = if (stream != null) {
                BufferedReader(InputStreamReader(stream, StandardCharsets.UTF_8)).use { it.readText() }
            } else {
                ""
            }
            val parsed = runCatching { JSONObject(rawResp) }.getOrNull()
            val msg = parsed?.optString("error")?.takeIf { it.isNotEmpty() }
                ?: parsed?.optString("message")?.takeIf { it.isNotEmpty() }
                ?: "HTTP $code"
            val errCode = parsed?.optString("error_code")?.takeIf { it.isNotEmpty() }

            when {
                code in 200..299 -> ApiResult(Outcome.SUCCESS, code, msg, errCode)
                code == 401 || code == 403 -> ApiResult(Outcome.UNAUTHORIZED, code, msg, errCode)
                code in 400..499 && code != 429 && code != 408 ->
                    ApiResult(Outcome.CLIENT_REJECTED, code, msg, errCode)
                else -> ApiResult(Outcome.NETWORK_OR_SERVER_ERROR, code, msg, errCode)
            }
        } catch (e: Exception) {
            ApiResult(Outcome.NETWORK_OR_SERVER_ERROR, 0, e.message ?: "Network unavailable")
        } finally {
            conn?.disconnect()
        }
    }
}
