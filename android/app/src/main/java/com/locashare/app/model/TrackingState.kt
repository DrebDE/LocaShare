package com.locashare.app.model

import java.net.URI

/**
 * Visible operational states shown to the phone owner and reported to the backend.
 */
enum class TrackingState(
    val apiCode: String,
    val displayTitle: String,
    val detailDescription: String
) {
    UNREGISTERED(
        apiCode = "unregistered",
        displayTitle = "Not registered",
        detailDescription = "Tap “Register this device” to receive a one-time pairing code for your laptop dashboard."
    ),
    WAITING_FOR_PAIRING(
        apiCode = "waiting_for_pairing",
        displayTitle = "Waiting for pairing",
        detailDescription = "Enter the one-time pairing code or scan the QR code on your laptop dashboard."
    ),
    REGISTERED(
        apiCode = "registered",
        displayTitle = "Registered & paired",
        detailDescription = "Paired with your laptop dashboard. Tap “Start sharing” when you want to send live location updates."
    ),
    SHARING(
        apiCode = "sharing",
        displayTitle = "Sharing location",
        detailDescription = "Actively sharing your latest location with a visible foreground notification."
    ),
    PAUSED(
        apiCode = "paused",
        displayTitle = "Sharing paused",
        detailDescription = "Location sharing is stopped. No new coordinates are being sent."
    ),
    NO_GPS_FIX(
        apiCode = "no_gps_fix",
        displayTitle = "No GPS fix yet",
        detailDescription = "Sharing is enabled, waiting for Android location providers to acquire a fix."
    ),
    OFFLINE(
        apiCode = "offline",
        displayTitle = "Offline (newest point saved)",
        detailDescription = "No network connection. Only the newest location fix is retained and will be sent automatically when online."
    ),
    PERMISSION_MISSING(
        apiCode = "permission_missing",
        displayTitle = "Location permission missing",
        detailDescription = "Location permission is required before LocaShare can read or share your coordinates."
    );

    companion object {
        fun fromApiCode(code: String?): TrackingState {
            if (code.isNullOrBlank()) return REGISTERED
            return entries.firstOrNull { it.apiCode.equals(code.trim(), ignoreCase = true) } ?: REGISTERED
        }
    }
}

/**
 * Determines the phone's honest operational state from current registration, permission,
 * connectivity, pairing, and GPS fix signals.
 */
object TrackingStateResolver {
    fun resolve(
        isRegistered: Boolean,
        hasLocationPermission: Boolean,
        isSharingEnabled: Boolean,
        hasActivePairing: Boolean,
        isNetworkOnline: Boolean,
        hasGpsFix: Boolean,
        hasSharedPreviously: Boolean = false
    ): TrackingState {
        if (!isRegistered) {
            return TrackingState.UNREGISTERED
        }
        if (!hasLocationPermission) {
            return TrackingState.PERMISSION_MISSING
        }
        if (isSharingEnabled) {
            if (!isNetworkOnline) {
                return TrackingState.OFFLINE
            }
            if (!hasGpsFix) {
                return TrackingState.NO_GPS_FIX
            }
            return TrackingState.SHARING
        }
        if (!isNetworkOnline) {
            return TrackingState.OFFLINE
        }
        if (!hasActivePairing) {
            return TrackingState.WAITING_FOR_PAIRING
        }
        return if (hasSharedPreviously) TrackingState.PAUSED else TrackingState.REGISTERED
    }
}

/**
 * Represents a single point-in-time location fix captured on the phone.
 */
data class LocationSample(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Float?,
    val recordedAtEpochMs: Long,
    val batteryPercent: Int? = null,
    val isCharging: Boolean? = null,
    val networkType: String = "unknown"
) {
    fun isValid(): Boolean {
        if (!latitude.isFinite() || !longitude.isFinite()) return false
        if (latitude < -90.0 || latitude > 90.0) return false
        if (longitude < -180.0 || longitude > 180.0) return false
        if (accuracyMeters != null && (!accuracyMeters.isFinite() || accuracyMeters < 0f || accuracyMeters > 100_000f)) {
            return false
        }
        if (recordedAtEpochMs <= 0L) return false
        return true
    }
}

/**
 * Validates and normalizes the configurable backend server URL.
 * Enforces HTTPS for remote hosts while allowing cleartext HTTP only for localhost / 10.0.2.2 dev testing.
 */
object ServerUrlValidator {
    data class ValidationResult(
        val isValid: Boolean,
        val normalizedUrl: String = "",
        val isRemoteHttps: Boolean = false,
        val errorMessage: String? = null
    )

    fun validate(rawInput: String): ValidationResult {
        val trimmed = rawInput.trim().trimEnd('/')
        if (trimmed.isEmpty()) {
            return ValidationResult(false, errorMessage = "Server URL cannot be empty.")
        }

        val uri = try {
            URI(trimmed)
        } catch (_: Exception) {
            return ValidationResult(false, errorMessage = "Malformed URL format.")
        }

        val scheme = uri.scheme?.lowercase() ?: ""
        val host = uri.host?.lowercase() ?: ""

        if (scheme != "https" && scheme != "http") {
            return ValidationResult(false, errorMessage = "URL must start with https:// (or http:// for localhost dev).")
        }
        if (host.isEmpty()) {
            return ValidationResult(false, errorMessage = "Server URL must include a valid host.")
        }

        val isLocalDevHost = host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2"
        if (scheme == "http" && !isLocalDevHost) {
            return ValidationResult(
                isValid = false,
                errorMessage = "Remote servers require HTTPS (https://) to protect your location data over Wi-Fi and mobile networks."
            )
        }

        return ValidationResult(
            isValid = true,
            normalizedUrl = trimmed,
            isRemoteHttps = (scheme == "https" && !isLocalDevHost)
        )
    }
}
