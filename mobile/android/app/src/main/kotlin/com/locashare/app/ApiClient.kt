package com.locashare.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/**
 * Lightweight HTTPS/HTTP client for background location, heartbeat,
 * Saved Place transition alerts, and family event syncing across both
 * self-hosted PHP LocaShare and Supabase Cloud backends.
 *
 * Never logs bearer tokens, anon keys, or device coordinates.
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
        val errorCode: String? = null,
        val placesJson: String? = null,
        val bodyJson: JSONObject? = null
    )

    data class RemotePlaceEvent(
        val eventId: String,
        val deviceId: String,
        val memberName: String,
        val placeId: String,
        val placeName: String,
        val placeCategory: String,
        val eventType: String,
        val occurredAt: String
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
        snap: DeviceStore.Snapshot,
        latitude: Double,
        longitude: Double,
        accuracy: Float?,
        recordedAtIso: String,
        networkType: String,
        presenceMode: String,
        currentPlaceId: String?,
        currentPlaceName: String?,
        homePrivacyMasked: Boolean,
        speedMps: Float?
    ): ApiResult {
        val (battery, charging) = getBatteryInfo(context)
        if (snap.backendMode == "supabase") {
            val rpcPayload = JSONObject().apply {
                put("p_device_id", snap.deviceId)
                put("p_device_token", snap.deviceToken)
                put("p_latitude", latitude)
                put("p_longitude", longitude)
                put("p_accuracy", if (accuracy != null && accuracy > 0f) accuracy.toDouble() else JSONObject.NULL)
                put("p_recorded_at", recordedAtIso)
                put("p_battery", battery ?: JSONObject.NULL)
                put("p_is_charging", charging ?: JSONObject.NULL)
                put("p_network_type", networkType)
                put("p_presence_mode", presenceMode)
                put("p_current_place_id", currentPlaceId ?: JSONObject.NULL)
                put("p_current_place_name", currentPlaceName ?: JSONObject.NULL)
                put("p_home_privacy_masked", homePrivacyMasked)
                put("p_smart_home_mode", snap.smartHomeMode)
                put("p_speed_mps", speedMps?.toDouble() ?: JSONObject.NULL)
            }
            return requestJson(
                method = "POST",
                fullUrl = "${snap.supabaseUrl.trimEnd('/')}/rest/v1/rpc/rpc_report_location",
                headers = supabaseHeaders(snap.supabaseAnonKey),
                body = rpcPayload
            )
        }

        val payload = JSONObject().apply {
            put("device_id", snap.deviceId)
            put("latitude", latitude)
            put("longitude", longitude)
            if (accuracy != null && accuracy > 0f) {
                put("accuracy", accuracy.toDouble())
            }
            put("recorded_at", recordedAtIso)
            if (battery != null) put("battery", battery)
            if (charging != null) put("is_charging", charging)
            put("network_type", networkType)
            put("presence_mode", presenceMode)
            if (!currentPlaceId.isNullOrEmpty()) put("current_place_id", currentPlaceId)
            if (!currentPlaceName.isNullOrEmpty()) put("current_place_name", currentPlaceName)
            put("home_privacy_masked", homePrivacyMasked)
            put("smart_home_mode", snap.smartHomeMode)
            if (speedMps != null && speedMps >= 0f) put("speed_mps", speedMps.toDouble())
        }
        return requestJson(
            method = "POST",
            fullUrl = "${snap.serverUrl.trimEnd('/')}/api/location/update.php",
            headers = phpHeaders(snap.deviceToken),
            body = payload
        )
    }

    fun sendHeartbeat(
        context: Context,
        snap: DeviceStore.Snapshot,
        sharingEnabled: Boolean,
        statusState: String
    ): ApiResult {
        val (battery, charging) = getBatteryInfo(context)
        val netType = getNetworkType(context)
        if (snap.backendMode == "supabase") {
            val rpcPayload = JSONObject().apply {
                put("p_device_id", snap.deviceId)
                put("p_device_token", snap.deviceToken)
                put("p_sharing_enabled", sharingEnabled)
                put("p_status_state", statusState)
                put("p_battery", battery ?: JSONObject.NULL)
                put("p_is_charging", charging ?: JSONObject.NULL)
                put("p_network_type", netType)
                put("p_presence_mode", snap.presenceMode)
                put("p_current_place_id", snap.currentPlaceId ?: JSONObject.NULL)
                put("p_current_place_name", snap.currentPlaceName ?: JSONObject.NULL)
                put("p_smart_home_mode", snap.smartHomeMode)
            }
            return requestJson(
                method = "POST",
                fullUrl = "${snap.supabaseUrl.trimEnd('/')}/rest/v1/rpc/rpc_report_heartbeat",
                headers = supabaseHeaders(snap.supabaseAnonKey),
                body = rpcPayload
            )
        }

        val payload = JSONObject().apply {
            put("device_id", snap.deviceId)
            put("sharing_enabled", sharingEnabled)
            put("status_state", statusState)
            if (battery != null) put("battery", battery)
            if (charging != null) put("is_charging", charging)
            put("network_type", netType)
            put("presence_mode", snap.presenceMode)
            if (!snap.currentPlaceId.isNullOrEmpty()) put("current_place_id", snap.currentPlaceId)
            if (!snap.currentPlaceName.isNullOrEmpty()) put("current_place_name", snap.currentPlaceName)
            put("smart_home_mode", snap.smartHomeMode)
        }
        return requestJson(
            method = "POST",
            fullUrl = "${snap.serverUrl.trimEnd('/')}/api/device/heartbeat.php",
            headers = phpHeaders(snap.deviceToken),
            body = payload
        )
    }

    fun reportPlaceEvent(
        snap: DeviceStore.Snapshot,
        placeId: String,
        eventType: String,
        occurredAtIso: String
    ): ApiResult {
        if (snap.backendMode == "supabase") {
            val base = snap.supabaseUrl.trimEnd('/')
            val edgeBody = JSONObject().apply {
                put("device_id", snap.deviceId)
                put("device_token", snap.deviceToken)
                put("place_id", placeId)
                put("event_type", eventType)
                put("occurred_at", occurredAtIso)
            }
            val edgeRes = requestJson(
                method = "POST",
                fullUrl = "$base/functions/v1/place-event-notify",
                headers = supabaseHeaders(snap.supabaseAnonKey),
                body = edgeBody
            )
            if (edgeRes.statusCode != 404) {
                return edgeRes
            }
            val rpcBody = JSONObject().apply {
                put("p_device_id", snap.deviceId)
                put("p_device_token", snap.deviceToken)
                put("p_place_id", placeId)
                put("p_event_type", eventType)
                put("p_occurred_at", occurredAtIso)
            }
            return requestJson(
                method = "POST",
                fullUrl = "$base/rest/v1/rpc/rpc_report_place_event",
                headers = supabaseHeaders(snap.supabaseAnonKey),
                body = rpcBody
            )
        }

        val payload = JSONObject().apply {
            put("device_id", snap.deviceId)
            put("place_id", placeId)
            put("event_type", eventType)
            put("occurred_at", occurredAtIso)
        }
        return requestJson(
            method = "POST",
            fullUrl = "${snap.serverUrl.trimEnd('/')}/api/family/events/report.php",
            headers = phpHeaders(snap.deviceToken),
            body = payload
        )
    }

    fun fetchCircleSnapshot(
        snap: DeviceStore.Snapshot,
        eventsSinceIso: String? = null
    ): Pair<ApiResult, List<RemotePlaceEvent>> {
        val res = if (snap.backendMode == "supabase") {
            val rpcBody = JSONObject().apply {
                put("p_device_id", snap.deviceId)
                put("p_device_token", snap.deviceToken)
                put("p_events_since", eventsSinceIso ?: JSONObject.NULL)
            }
            requestJson(
                method = "POST",
                fullUrl = "${snap.supabaseUrl.trimEnd('/')}/rest/v1/rpc/rpc_get_circle_snapshot",
                headers = supabaseHeaders(snap.supabaseAnonKey),
                body = rpcBody
            )
        } else {
            val base = snap.serverUrl.trimEnd('/')
            val q = StringBuilder("?device_id=").append(URLEncoder.encode(snap.deviceId, "UTF-8"))
            if (!eventsSinceIso.isNullOrBlank()) {
                q.append("&events_since=").append(URLEncoder.encode(eventsSinceIso, "UTF-8"))
            }
            requestJson(
                method = "GET",
                fullUrl = "$base/api/family/circle/snapshot.php$q",
                headers = phpHeaders(snap.deviceToken),
                body = null
            )
        }

        val events = ArrayList<RemotePlaceEvent>()
        val arr: JSONArray? = res.bodyJson?.optJSONArray("events")
        if (arr != null) {
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                events.add(
                    RemotePlaceEvent(
                        eventId = obj.optString("event_id", ""),
                        deviceId = obj.optString("device_id", ""),
                        memberName = obj.optString("member_name", "Family member"),
                        placeId = obj.optString("place_id", ""),
                        placeName = obj.optString("place_name", "Place"),
                        placeCategory = obj.optString("place_category", "custom"),
                        eventType = obj.optString("event_type", "entered"),
                        occurredAt = obj.optString("occurred_at", "")
                    )
                )
            }
        }
        return Pair(res, events)
    }

    private fun phpHeaders(deviceToken: String): Map<String, String> = mapOf(
        "Accept" to "application/json",
        "Content-Type" to "application/json; charset=utf-8",
        "Authorization" to "Bearer $deviceToken"
    )

    private fun supabaseHeaders(anonKey: String): Map<String, String> = mapOf(
        "Accept" to "application/json",
        "Content-Type" to "application/json; charset=utf-8",
        "apikey" to anonKey,
        "Authorization" to "Bearer $anonKey"
    )

    private fun requestJson(
        method: String,
        fullUrl: String,
        headers: Map<String, String>,
        body: JSONObject?
    ): ApiResult {
        if (fullUrl.isBlank() || (!fullUrl.startsWith("http://") && !fullUrl.startsWith("https://"))) {
            return ApiResult(Outcome.CLIENT_REJECTED, 0, "Backend URL is not configured")
        }

        var conn: HttpURLConnection? = null
        return try {
            val url = URL(fullUrl)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 10_000
                readTimeout = 12_000
                doOutput = body != null
                useCaches = false
                for ((k, v) in headers) {
                    setRequestProperty(k, v)
                }
            }

            if (body != null) {
                OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use { writer ->
                    writer.write(body.toString())
                    writer.flush()
                }
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
            val placesArr = parsed?.optJSONArray("places")?.toString()

            val isSupabaseUnauthorized = parsed?.optString("message")?.contains("UNAUTHORIZED", ignoreCase = true) == true

            when {
                code in 200..299 -> ApiResult(Outcome.SUCCESS, code, msg, errCode, placesArr, parsed)
                code == 401 || code == 403 || isSupabaseUnauthorized ->
                    ApiResult(Outcome.UNAUTHORIZED, code, msg, errCode, null, parsed)
                code in 400..499 && code != 429 && code != 408 ->
                    ApiResult(Outcome.CLIENT_REJECTED, code, msg, errCode, null, parsed)
                else -> ApiResult(Outcome.NETWORK_OR_SERVER_ERROR, code, msg, errCode, null, parsed)
            }
        } catch (e: Exception) {
            ApiResult(Outcome.NETWORK_OR_SERVER_ERROR, 0, e.message ?: "Network unavailable")
        } finally {
            conn?.disconnect()
        }
    }
}
