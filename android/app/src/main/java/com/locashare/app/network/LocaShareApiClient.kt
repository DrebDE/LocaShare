package com.locashare.app.network

import com.locashare.app.model.LocationSample
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * HTTPS API client for phone-to-backend communication.
 * Authenticates every device request with Bearer token + device_id.
 * Never logs pairing codes, tokens, or coordinates.
 */
object LocaShareApiClient {

    private const val CONNECT_TIMEOUT_MS = 10_000
    private const val READ_TIMEOUT_MS = 10_000

    data class ApiResult<T>(
        val success: Boolean,
        val statusCode: Int,
        val data: T? = null,
        val errorMessage: String? = null,
        val isNetworkError: Boolean = false
    )

    data class RegistrationResponse(
        val deviceId: String,
        val deviceName: String,
        val deviceToken: String,
        val pairingCode: String,
        val pairingQrPayload: String,
        val pairingExpiresAtEpochMs: Long,
        val statusState: String
    )

    data class PairingCodeResponse(
        val pairingCode: String,
        val pairingQrPayload: String,
        val pairingExpiresAtEpochMs: Long,
        val pairedDashboardsCount: Int
    )

    data class DeviceStatusResponse(
        val deviceId: String,
        val sharingEnabled: Boolean,
        val statusState: String,
        val hasActivePairing: Boolean,
        val pairedDashboardsCount: Int,
        val hasStoredLocation: Boolean
    )

    fun registerDevice(serverUrl: String, deviceName: String): ApiResult<RegistrationResponse> {
        val body = JSONObject().apply {
            put("device_name", deviceName)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/register.php",
            method = "POST",
            bearerToken = null,
            jsonBody = body
        )
        if (!raw.success || raw.data == null) {
            return ApiResult(false, raw.statusCode, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
        }

        val json = raw.data
        val ttlSec = json.optLong("pairing_ttl_seconds", 300L)
        val expiresMs = System.currentTimeMillis() + (ttlSec * 1000L)

        return ApiResult(
            success = true,
            statusCode = raw.statusCode,
            data = RegistrationResponse(
                deviceId = json.optString("device_id"),
                deviceName = json.optString("device_name", deviceName),
                deviceToken = json.optString("device_token"),
                pairingCode = json.optString("pairing_code"),
                pairingQrPayload = json.optString("pairing_qr_payload"),
                pairingExpiresAtEpochMs = expiresMs,
                statusState = json.optString("status_state", "waiting_for_pairing")
            )
        )
    }

    fun generateNewPairingCode(
        serverUrl: String,
        deviceId: String,
        deviceToken: String
    ): ApiResult<PairingCodeResponse> {
        val body = JSONObject().apply {
            put("device_id", deviceId)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/pairing-code.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        if (!raw.success || raw.data == null) {
            return ApiResult(false, raw.statusCode, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
        }

        val json = raw.data
        val ttlSec = json.optLong("pairing_ttl_seconds", 300L)
        val expiresMs = System.currentTimeMillis() + (ttlSec * 1000L)

        return ApiResult(
            success = true,
            statusCode = raw.statusCode,
            data = PairingCodeResponse(
                pairingCode = json.optString("pairing_code"),
                pairingQrPayload = json.optString("pairing_qr_payload"),
                pairingExpiresAtEpochMs = expiresMs,
                pairedDashboardsCount = json.optInt("paired_dashboards", 0)
            )
        )
    }

    fun sendHeartbeat(
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        sharingEnabled: Boolean,
        statusState: String,
        batteryPercent: Int? = null,
        isCharging: Boolean? = null,
        networkType: String = "unknown"
    ): ApiResult<DeviceStatusResponse> {
        val body = JSONObject().apply {
            put("device_id", deviceId)
            put("sharing_enabled", sharingEnabled)
            put("status_state", statusState)
            put("network_type", networkType)
            if (batteryPercent != null) put("battery", batteryPercent)
            if (isCharging != null) put("is_charging", isCharging)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/heartbeat.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        if (!raw.success || raw.data == null) {
            return ApiResult(false, raw.statusCode, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
        }

        val statusObj = raw.data.optJSONObject("status") ?: JSONObject()
        return ApiResult(
            success = true,
            statusCode = raw.statusCode,
            data = parseStatusObject(statusObj, deviceId)
        )
    }

    fun sendLocationUpdate(
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        sample: LocationSample
    ): ApiResult<Int> {
        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val body = JSONObject().apply {
            put("device_id", deviceId)
            put("latitude", sample.latitude)
            put("longitude", sample.longitude)
            if (sample.accuracyMeters != null) {
                put("accuracy", sample.accuracyMeters.toDouble())
            }
            put("timestamp", isoFormat.format(Date(sample.recordedAtEpochMs)))
            put("network_type", sample.networkType)
            if (sample.batteryPercent != null) put("battery", sample.batteryPercent)
            if (sample.isCharging != null) put("is_charging", sample.isCharging)
        }

        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/location/update.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        if (!raw.success || raw.data == null) {
            return ApiResult(false, raw.statusCode, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
        }

        val pairedCount = raw.data.optInt("paired_dashboards_count", 0)
        return ApiResult(true, raw.statusCode, data = pairedCount)
    }

    fun fetchDeviceStatus(
        serverUrl: String,
        deviceId: String,
        deviceToken: String
    ): ApiResult<DeviceStatusResponse> {
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/status.php?device_id=${java.net.URLEncoder.encode(deviceId, "UTF-8")}",
            method = "GET",
            bearerToken = deviceToken,
            jsonBody = null
        )
        if (!raw.success || raw.data == null) {
            return ApiResult(false, raw.statusCode, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
        }

        val statusObj = raw.data.optJSONObject("status") ?: JSONObject()
        return ApiResult(
            success = true,
            statusCode = raw.statusCode,
            data = parseStatusObject(statusObj, deviceId)
        )
    }

    fun unpairDashboards(
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        clearLocation: Boolean = true
    ): ApiResult<Boolean> {
        val body = JSONObject().apply {
            put("device_id", deviceId)
            put("clear_location", clearLocation)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/unpair.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        return ApiResult(raw.success, raw.statusCode, data = raw.success, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
    }

    fun deleteStoredLocation(
        serverUrl: String,
        deviceId: String,
        deviceToken: String
    ): ApiResult<Boolean> {
        val body = JSONObject().apply {
            put("device_id", deviceId)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/location/delete.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        return ApiResult(raw.success, raw.statusCode, data = raw.success, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
    }

    fun unregisterDevice(
        serverUrl: String,
        deviceId: String,
        deviceToken: String
    ): ApiResult<Boolean> {
        val body = JSONObject().apply {
            put("device_id", deviceId)
        }
        val raw = executeJsonRequest(
            url = "${serverUrl.trimEnd('/')}/api/device/unregister.php",
            method = "POST",
            bearerToken = deviceToken,
            jsonBody = body
        )
        return ApiResult(raw.success, raw.statusCode, data = raw.success, errorMessage = raw.errorMessage, isNetworkError = raw.isNetworkError)
    }

    private fun parseStatusObject(statusObj: JSONObject, fallbackDeviceId: String): DeviceStatusResponse {
        val pairedCount = statusObj.optInt("paired_dashboards_count", 0)
        return DeviceStatusResponse(
            deviceId = statusObj.optString("device_id", fallbackDeviceId),
            sharingEnabled = statusObj.optBoolean("sharing_enabled", false),
            statusState = statusObj.optString("status_state", "registered"),
            hasActivePairing = statusObj.optBoolean("has_active_pairing", pairedCount > 0),
            pairedDashboardsCount = pairedCount,
            hasStoredLocation = statusObj.optBoolean("has_stored_location", false)
        )
    }

    private fun executeJsonRequest(
        url: String,
        method: String,
        bearerToken: String?,
        jsonBody: JSONObject?
    ): ApiResult<JSONObject> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                setRequestProperty("Accept", "application/json")
                if (!bearerToken.isNullOrBlank()) {
                    setRequestProperty("Authorization", "Bearer $bearerToken")
                }
                if (jsonBody != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                }
            }

            if (jsonBody != null) {
                OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { writer ->
                    writer.write(jsonBody.toString())
                    writer.flush()
                }
            }

            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val responseText = if (stream != null) {
                BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            } else {
                ""
            }

            val parsed = if (responseText.isNotBlank()) JSONObject(responseText) else JSONObject()
            val ok = (code in 200..299) && parsed.optBoolean("success", true)
            if (ok) {
                ApiResult(true, code, data = parsed)
            } else {
                ApiResult(
                    success = false,
                    statusCode = code,
                    errorMessage = parsed.optString("error", "Request failed with HTTP $code")
                )
            }
        } catch (e: Exception) {
            ApiResult(
                success = false,
                statusCode = 0,
                errorMessage = "Network error: unable to reach server.",
                isNetworkError = true
            )
        } finally {
            conn?.disconnect()
        }
    }
}
