package com.locashare.app.storage

import android.content.Context
import android.content.SharedPreferences
import com.locashare.app.model.LocationSample

/**
 * Minimal key-value storage abstraction so OfflineLocationStore can run with
 * Android SharedPreferences in production and in-memory backing in JVM unit tests.
 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
    fun clear()
}

class SharedPrefsKeyValueStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String?) {
        prefs.edit().apply {
            if (value == null) remove(key) else putString(key, value)
        }.apply()
    }

    override fun clear() {
        prefs.edit().clear().apply()
    }
}

class InMemoryKeyValueStore : KeyValueStore {
    private val map = mutableMapOf<String, String>()

    override fun getString(key: String): String? = synchronized(this) { map[key] }

    override fun putString(key: String, value: String?) = synchronized(this) {
        if (value == null) map.remove(key) else map[key] = value
    }

    override fun clear() = synchronized(this) { map.clear() }
}

/**
 * Single-slot offline location store.
 *
 * When the phone is offline or an upload fails due to connectivity, LocaShare saves or
 * replaces the single pending point with the newest location fix and retries once connectivity
 * returns. It never accumulates a historical queue that would flood the server with old locations.
 */
class OfflineLocationStore(private val store: KeyValueStore) {

    constructor(context: Context) : this(
        SharedPrefsKeyValueStore(
            context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        )
    )

    /**
     * Save [sample] as the single pending location if it is valid and at least as new
     * as any currently stored pending point.
     *
     * @return true if stored/replaced, false if invalid or older than the existing pending point.
     */
    @Synchronized
    fun saveOrReplaceNewest(sample: LocationSample): Boolean {
        if (!sample.isValid()) {
            return false
        }

        val existing = peekPending()
        if (existing != null && sample.recordedAtEpochMs < existing.recordedAtEpochMs) {
            // Do not overwrite a newer pending fix with an older out-of-order fix
            return false
        }

        store.putString(KEY_PENDING_SAMPLE, serialize(sample))
        return true
    }

    /**
     * Read the currently queued newest location fix without removing it.
     */
    @Synchronized
    fun peekPending(): LocationSample? {
        val raw = store.getString(KEY_PENDING_SAMPLE) ?: return null
        return deserialize(raw)
    }

    /**
     * Atomically remove the pending location fix if its timestamp matches [recordedAtEpochMs]
     * (or unconditionally if [recordedAtEpochMs] is null).
     */
    @Synchronized
    fun clearPending(recordedAtEpochMs: Long? = null) {
        if (recordedAtEpochMs == null) {
            store.putString(KEY_PENDING_SAMPLE, null)
            return
        }
        val current = peekPending()
        if (current != null && current.recordedAtEpochMs <= recordedAtEpochMs) {
            store.putString(KEY_PENDING_SAMPLE, null)
        }
    }

    private fun serialize(s: LocationSample): String {
        return listOf(
            s.latitude.toString(),
            s.longitude.toString(),
            s.accuracyMeters?.toString() ?: "",
            s.recordedAtEpochMs.toString(),
            s.batteryPercent?.toString() ?: "",
            s.isCharging?.toString() ?: "",
            s.networkType.replace("|", "")
        ).joinToString("|")
    }

    private fun deserialize(raw: String): LocationSample? {
        val parts = raw.split("|")
        if (parts.size < 7) return null
        return try {
            val sample = LocationSample(
                latitude = parts[0].toDouble(),
                longitude = parts[1].toDouble(),
                accuracyMeters = parts[2].takeIf { it.isNotEmpty() }?.toFloat(),
                recordedAtEpochMs = parts[3].toLong(),
                batteryPercent = parts[4].takeIf { it.isNotEmpty() }?.toInt(),
                isCharging = parts[5].takeIf { it.isNotEmpty() }?.toBooleanStrictOrNull(),
                networkType = parts[6].ifEmpty { "unknown" }
            )
            if (sample.isValid()) sample else null
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val PREFS_NAME = "locashare_offline_queue"
        private const val KEY_PENDING_SAMPLE = "pending_latest_sample"
    }
}
