package com.locashare.app.storage

import android.content.Context
import android.os.Build

/**
 * Persists phone registration credentials, server URL, pairing code metadata,
 * and latest known operational telemetry.
 */
class LocaSharePreferences(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var serverUrl: String
        get() = prefs.getString(KEY_SERVER_URL, DEFAULT_SERVER_URL) ?: DEFAULT_SERVER_URL
        set(value) = prefs.edit().putString(KEY_SERVER_URL, value.trim().trimEnd('/')).apply()

    var deviceId: String?
        get() = prefs.getString(KEY_DEVICE_ID, null)
        set(value) = prefs.edit().putString(KEY_DEVICE_ID, value).apply()

    var deviceToken: String?
        get() = prefs.getString(KEY_DEVICE_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_DEVICE_TOKEN, value).apply()

    var deviceName: String
        get() = prefs.getString(KEY_DEVICE_NAME, defaultDeviceModelName()) ?: defaultDeviceModelName()
        set(value) = prefs.edit().putString(KEY_DEVICE_NAME, value.trim()).apply()

    var pairingCode: String?
        get() = prefs.getString(KEY_PAIRING_CODE, null)
        set(value) = prefs.edit().putString(KEY_PAIRING_CODE, value).apply()

    var pairingQrPayload: String?
        get() = prefs.getString(KEY_PAIRING_QR, null)
        set(value) = prefs.edit().putString(KEY_PAIRING_QR, value).apply()

    var pairingExpiresAtEpochMs: Long
        get() = prefs.getLong(KEY_PAIRING_EXPIRES_AT, 0L)
        set(value) = prefs.edit().putLong(KEY_PAIRING_EXPIRES_AT, value).apply()

    var hasActivePairing: Boolean
        get() = prefs.getBoolean(KEY_HAS_ACTIVE_PAIRING, false)
        set(value) = prefs.edit().putBoolean(KEY_HAS_ACTIVE_PAIRING, value).apply()

    var sharingEnabled: Boolean
        get() = prefs.getBoolean(KEY_SHARING_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_SHARING_ENABLED, value).apply()

    var hasSharedPreviously: Boolean
        get() = prefs.getBoolean(KEY_HAS_SHARED_PREV, false)
        set(value) = prefs.edit().putBoolean(KEY_HAS_SHARED_PREV, value).apply()

    var lastAccuracyMeters: Float
        get() = prefs.getFloat(KEY_LAST_ACCURACY, -1f)
        set(value) = prefs.edit().putFloat(KEY_LAST_ACCURACY, value).apply()

    var lastSuccessfulUploadEpochMs: Long
        get() = prefs.getLong(KEY_LAST_UPLOAD_MS, 0L)
        set(value) = prefs.edit().putLong(KEY_LAST_UPLOAD_MS, value).apply()

    var hasGpsFix: Boolean
        get() = prefs.getBoolean(KEY_HAS_GPS_FIX, false)
        set(value) = prefs.edit().putBoolean(KEY_HAS_GPS_FIX, value).apply()

    val isRegistered: Boolean
        get() = !deviceId.isNullOrBlank() && !deviceToken.isNullOrBlank()

    fun clearRegistrationAndTelemetry() {
        val currentServerUrl = serverUrl
        val currentDeviceName = deviceName
        prefs.edit().clear()
            .putString(KEY_SERVER_URL, currentServerUrl)
            .putString(KEY_DEVICE_NAME, currentDeviceName)
            .apply()
    }

    fun clearStoredLocationMetadata() {
        prefs.edit()
            .putFloat(KEY_LAST_ACCURACY, -1f)
            .putBoolean(KEY_HAS_GPS_FIX, false)
            .apply()
    }

    private fun defaultDeviceModelName(): String {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val combined = if (model.startsWith(manufacturer, ignoreCase = true)) {
            model
        } else {
            "$manufacturer $model".trim()
        }
        return combined.ifEmpty { "Android Phone" }.take(48)
    }

    companion object {
        private const val PREFS_NAME = "locashare_prefs"
        const val DEFAULT_SERVER_URL = "http://10.0.2.2:8080"

        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEVICE_TOKEN = "device_token"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_PAIRING_CODE = "pairing_code"
        private const val KEY_PAIRING_QR = "pairing_qr"
        private const val KEY_PAIRING_EXPIRES_AT = "pairing_expires_at"
        private const val KEY_HAS_ACTIVE_PAIRING = "has_active_pairing"
        private const val KEY_SHARING_ENABLED = "sharing_enabled"
        private const val KEY_HAS_SHARED_PREV = "has_shared_prev"
        private const val KEY_LAST_ACCURACY = "last_accuracy"
        private const val KEY_LAST_UPLOAD_MS = "last_upload_ms"
        private const val KEY_HAS_GPS_FIX = "has_gps_fix"
    }
}
