package com.locashare.app

import android.content.Context
import android.content.SharedPreferences
import android.os.Build

/**
 * Shared persistent storage for device registration, sharing state, and the
 * single pending offline location point (newest fix overwrites any unsent fix).
 *
 * Credentials and coordinates are never written to system logs.
 */
object DeviceStore {
    private const val PREFS_NAME = "locashare_device_store"

    private const val KEY_SERVER_URL = "server_url"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_TOKEN = "device_token"
    private const val KEY_DEVICE_NAME = "device_name"
    private const val KEY_IS_SHARING = "is_sharing"
    private const val KEY_STATUS_STATE = "status_state"
    private const val KEY_UPDATE_INTERVAL_MS = "update_interval_ms"
    private const val KEY_LAST_UPLOAD_AT = "last_upload_at"
    private const val KEY_LAST_FIX_AT = "last_fix_at"
    private const val KEY_LAST_ACCURACY = "last_accuracy"
    private const val KEY_LAST_LAT = "last_lat"
    private const val KEY_LAST_LNG = "last_lng"
    private const val KEY_LAST_ERROR = "last_error"

    private const val KEY_HAS_PENDING = "has_pending_fix"
    private const val KEY_PENDING_LAT = "pending_lat"
    private const val KEY_PENDING_LNG = "pending_lng"
    private const val KEY_PENDING_ACC = "pending_acc"
    private const val KEY_PENDING_RECORDED_AT = "pending_recorded_at"
    private const val KEY_PENDING_NETWORK = "pending_network"

    private const val DEFAULT_SERVER_URL = "http://10.0.2.2:8080"
    private const val DEFAULT_INTERVAL_MS = 30_000L

    data class PendingFix(
        val latitude: Double,
        val longitude: Double,
        val accuracy: Float?,
        val recordedAtIso: String,
        val networkType: String
    )

    data class Snapshot(
        val serverUrl: String,
        val deviceId: String,
        val deviceToken: String,
        val deviceName: String,
        val isSharing: Boolean,
        val statusState: String,
        val updateIntervalMs: Long,
        val lastUploadAt: String?,
        val lastFixAt: String?,
        val lastAccuracy: Float?,
        val lastLatitude: Double?,
        val lastLongitude: Double?,
        val lastError: String?,
        val hasPendingFix: Boolean,
        val pendingRecordedAt: String?,
        val pendingAccuracy: Float?
    )

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun getSnapshot(context: Context): Snapshot {
        val p = prefs(context)
        val hasAcc = p.contains(KEY_LAST_ACCURACY)
        val hasLatLng = p.contains(KEY_LAST_LAT) && p.contains(KEY_LAST_LNG)
        val hasPending = p.getBoolean(KEY_HAS_PENDING, false)
        val hasPendingAcc = hasPending && p.contains(KEY_PENDING_ACC)

        return Snapshot(
            serverUrl = p.getString(KEY_SERVER_URL, DEFAULT_SERVER_URL) ?: DEFAULT_SERVER_URL,
            deviceId = p.getString(KEY_DEVICE_ID, "") ?: "",
            deviceToken = p.getString(KEY_DEVICE_TOKEN, "") ?: "",
            deviceName = p.getString(KEY_DEVICE_NAME, defaultDeviceModel()) ?: defaultDeviceModel(),
            isSharing = p.getBoolean(KEY_IS_SHARING, false),
            statusState = p.getString(KEY_STATUS_STATE, "unregistered") ?: "unregistered",
            updateIntervalMs = p.getLong(KEY_UPDATE_INTERVAL_MS, DEFAULT_INTERVAL_MS),
            lastUploadAt = p.getString(KEY_LAST_UPLOAD_AT, null),
            lastFixAt = p.getString(KEY_LAST_FIX_AT, null),
            lastAccuracy = if (hasAcc) p.getFloat(KEY_LAST_ACCURACY, 0f) else null,
            lastLatitude = if (hasLatLng) java.lang.Double.longBitsToDouble(p.getLong(KEY_LAST_LAT, 0L)) else null,
            lastLongitude = if (hasLatLng) java.lang.Double.longBitsToDouble(p.getLong(KEY_LAST_LNG, 0L)) else null,
            lastError = p.getString(KEY_LAST_ERROR, null),
            hasPendingFix = hasPending,
            pendingRecordedAt = if (hasPending) p.getString(KEY_PENDING_RECORDED_AT, null) else null,
            pendingAccuracy = if (hasPendingAcc) p.getFloat(KEY_PENDING_ACC, 0f) else null
        )
    }

    @Synchronized
    fun configureDevice(
        context: Context,
        serverUrl: String,
        deviceId: String,
        deviceToken: String,
        deviceName: String,
        statusState: String,
        updateIntervalMs: Long
    ) {
        prefs(context).edit()
            .putString(KEY_SERVER_URL, serverUrl.trim())
            .putString(KEY_DEVICE_ID, deviceId.trim())
            .putString(KEY_DEVICE_TOKEN, deviceToken.trim())
            .putString(KEY_DEVICE_NAME, deviceName.trim())
            .putString(KEY_STATUS_STATE, statusState.trim())
            .putLong(KEY_UPDATE_INTERVAL_MS, updateIntervalMs.coerceIn(10_000L, 300_000L))
            .apply()
    }

    @Synchronized
    fun setServerUrl(context: Context, serverUrl: String) {
        prefs(context).edit()
            .putString(KEY_SERVER_URL, serverUrl.trim())
            .apply()
    }

    @Synchronized
    fun setIntervalMs(context: Context, intervalMs: Long) {
        prefs(context).edit()
            .putLong(KEY_UPDATE_INTERVAL_MS, intervalMs.coerceIn(10_000L, 300_000L))
            .apply()
    }

    @Synchronized
    fun setSharingState(
        context: Context,
        isSharing: Boolean,
        statusState: String,
        errorMessage: String? = null
    ) {
        val editor = prefs(context).edit()
            .putBoolean(KEY_IS_SHARING, isSharing)
            .putString(KEY_STATUS_STATE, statusState)
        if (errorMessage != null) {
            editor.putString(KEY_LAST_ERROR, errorMessage)
        } else {
            editor.remove(KEY_LAST_ERROR)
        }
        editor.apply()
    }

    @Synchronized
    fun recordSuccessfulUpload(
        context: Context,
        uploadIso: String,
        fixRecordedAtIso: String,
        latitude: Double,
        longitude: Double,
        accuracy: Float?
    ) {
        val editor = prefs(context).edit()
            .putString(KEY_LAST_UPLOAD_AT, uploadIso)
            .putString(KEY_LAST_FIX_AT, fixRecordedAtIso)
            .putLong(KEY_LAST_LAT, java.lang.Double.doubleToRawLongBits(latitude))
            .putLong(KEY_LAST_LNG, java.lang.Double.doubleToRawLongBits(longitude))
            .remove(KEY_LAST_ERROR)

        if (accuracy != null && accuracy > 0f) {
            editor.putFloat(KEY_LAST_ACCURACY, accuracy)
        } else {
            editor.remove(KEY_LAST_ACCURACY)
        }
        editor.apply()
    }

    /**
     * Save or replace the single pending offline location point with the newest fix.
     * Never queues multiple historical coordinates.
     */
    @Synchronized
    fun saveOrReplacePendingFix(context: Context, fix: PendingFix, errorMessage: String?) {
        val editor = prefs(context).edit()
            .putBoolean(KEY_HAS_PENDING, true)
            .putLong(KEY_PENDING_LAT, java.lang.Double.doubleToRawLongBits(fix.latitude))
            .putLong(KEY_PENDING_LNG, java.lang.Double.doubleToRawLongBits(fix.longitude))
            .putString(KEY_PENDING_RECORDED_AT, fix.recordedAtIso)
            .putString(KEY_PENDING_NETWORK, fix.networkType)
            .putLong(KEY_LAST_LAT, java.lang.Double.doubleToRawLongBits(fix.latitude))
            .putLong(KEY_LAST_LNG, java.lang.Double.doubleToRawLongBits(fix.longitude))
            .putString(KEY_LAST_FIX_AT, fix.recordedAtIso)

        if (fix.accuracy != null && fix.accuracy > 0f) {
            editor.putFloat(KEY_PENDING_ACC, fix.accuracy)
            editor.putFloat(KEY_LAST_ACCURACY, fix.accuracy)
        } else {
            editor.remove(KEY_PENDING_ACC)
        }

        if (errorMessage != null) {
            editor.putString(KEY_LAST_ERROR, errorMessage)
        }
        editor.apply()
    }

    @Synchronized
    fun getPendingFix(context: Context): PendingFix? {
        val p = prefs(context)
        if (!p.getBoolean(KEY_HAS_PENDING, false)) {
            return null
        }
        val recordedAt = p.getString(KEY_PENDING_RECORDED_AT, null) ?: return null
        val acc = if (p.contains(KEY_PENDING_ACC)) p.getFloat(KEY_PENDING_ACC, 0f) else null
        return PendingFix(
            latitude = java.lang.Double.longBitsToDouble(p.getLong(KEY_PENDING_LAT, 0L)),
            longitude = java.lang.Double.longBitsToDouble(p.getLong(KEY_PENDING_LNG, 0L)),
            accuracy = acc,
            recordedAtIso = recordedAt,
            networkType = p.getString(KEY_PENDING_NETWORK, "unknown") ?: "unknown"
        )
    }

    @Synchronized
    fun clearPendingFix(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_HAS_PENDING, false)
            .remove(KEY_PENDING_LAT)
            .remove(KEY_PENDING_LNG)
            .remove(KEY_PENDING_ACC)
            .remove(KEY_PENDING_RECORDED_AT)
            .remove(KEY_PENDING_NETWORK)
            .apply()
    }

    @Synchronized
    fun clearLocationMetadata(context: Context) {
        clearPendingFix(context)
        prefs(context).edit()
            .remove(KEY_LAST_UPLOAD_AT)
            .remove(KEY_LAST_FIX_AT)
            .remove(KEY_LAST_ACCURACY)
            .remove(KEY_LAST_LAT)
            .remove(KEY_LAST_LNG)
            .remove(KEY_LAST_ERROR)
            .apply()
    }

    @Synchronized
    fun clearRegistration(context: Context) {
        val preservedUrl = getSnapshot(context).serverUrl
        prefs(context).edit().clear().apply()
        prefs(context).edit()
            .putString(KEY_SERVER_URL, preservedUrl)
            .putString(KEY_STATUS_STATE, "unregistered")
            .putBoolean(KEY_IS_SHARING, false)
            .apply()
    }

    fun defaultDeviceModel(): String {
        val model = Build.MODEL?.trim().orEmpty()
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        if (model.isEmpty()) return "Android Phone"
        return if (manufacturer.isNotEmpty() && !model.startsWith(manufacturer, ignoreCase = true)) {
            "$manufacturer $model"
        } else {
            model
        }
    }

    fun toMap(snapshot: Snapshot): Map<String, Any?> = mapOf(
        "serverUrl" to snapshot.serverUrl,
        "deviceId" to snapshot.deviceId,
        "deviceToken" to snapshot.deviceToken,
        "deviceName" to snapshot.deviceName,
        "isSharing" to snapshot.isSharing,
        "statusState" to snapshot.statusState,
        "updateIntervalMs" to snapshot.updateIntervalMs,
        "lastUploadAt" to snapshot.lastUploadAt,
        "lastFixAt" to snapshot.lastFixAt,
        "lastAccuracy" to snapshot.lastAccuracy?.toDouble(),
        "lastLatitude" to snapshot.lastLatitude,
        "lastLongitude" to snapshot.lastLongitude,
        "lastError" to snapshot.lastError,
        "hasPendingFix" to snapshot.hasPendingFix,
        "pendingRecordedAt" to snapshot.pendingRecordedAt,
        "pendingAccuracy" to snapshot.pendingAccuracy?.toDouble()
    )
}
