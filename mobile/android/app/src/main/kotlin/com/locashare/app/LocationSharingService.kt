package com.locashare.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Visible foreground location sharing & Home-geofence service.
 *
 * Implements Smart Home Mode:
 *   - Inside Home geofence: low-power monitoring + Home privacy coordinate masking.
 *   - Leaving Home geofence: automatically escalates to live GPS tracking and emits
 *     place enter/exit events + family notifications.
 */
class LocationSharingService : Service() {

    companion object {
        const val ACTION_START_SHARING = "com.locashare.app.action.START_SHARING"
        const val ACTION_STOP_SHARING = "com.locashare.app.action.STOP_SHARING"
        const val ACTION_FLUSH_PENDING = "com.locashare.app.action.FLUSH_PENDING"
        const val ACTION_SYNC_ALERTS = "com.locashare.app.action.SYNC_ALERTS"
        const val ACTION_RECONFIGURE_MODE = "com.locashare.app.action.RECONFIGURE_MODE"

        private const val CHANNEL_ID = "locashare_sharing_channel"
        private const val NOTIFICATION_ID = 4401

        private const val NO_GPS_TIMEOUT_MS = 25_000L
        private const val HEARTBEAT_INTERVAL_MS = 60_000L
        private const val HOME_LOW_POWER_INTERVAL_MS = 120_000L
        private const val HOME_MIN_DISTANCE_METERS = 40f
        private const val AWAY_MIN_DISTANCE_METERS = 15f

        @Volatile
        private var stateListener: ((Map<String, Any?>) -> Unit)? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        fun setStateListener(listener: ((Map<String, Any?>) -> Unit)?) {
            stateListener = listener
        }

        fun notifyStateChanged(context: Context) {
            val snap = DeviceStore.toMap(DeviceStore.getSnapshot(context))
            mainHandler.post {
                stateListener?.invoke(snap)
            }
        }
    }

    private lateinit var executor: ExecutorService
    private var locationManager: LocationManager? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastSubmittedUploadAtMs: Long = 0L
    private var lastAcceptedLocation: Location? = null
    private var receivedFixThisSession: Boolean = false
    private var listenersRegistered: Boolean = false
    private var activeLowPowerHomeSampling: Boolean = false
    private var gpsProbeActive: Boolean = false

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            handleNewLocation(location)
        }

        @Deprecated("Deprecated in Android API")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {
            notifyAndRefreshNotification()
        }

        override fun onProviderDisabled(provider: String) {
            if (!receivedFixThisSession) {
                DeviceStore.setSharingState(
                    applicationContext,
                    isSharing = true,
                    statusState = "no_gps_fix",
                    errorMessage = "Device GPS/Location provider is turned off."
                )
                notifyAndRefreshNotification()
            }
        }
    }

    private val gpsProbeListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            gpsProbeActive = false
            runCatching { locationManager?.removeUpdates(this) }
            handleNewLocation(location)
        }

        @Deprecated("Deprecated in Android API")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val noGpsTimeoutRunnable = Runnable {
        val snap = DeviceStore.getSnapshot(applicationContext)
        if (snap.isSharing && !receivedFixThisSession) {
            val nextState = if (ApiClient.isNetworkConnected(applicationContext)) "no_gps_fix" else "offline"
            DeviceStore.setSharingState(
                applicationContext,
                isSharing = true,
                statusState = nextState,
                errorMessage = if (nextState == "no_gps_fix") {
                    "Still waiting for GPS/network fix."
                } else {
                    "Device offline; waiting for connectivity."
                }
            )
            notifyAndRefreshNotification()
            sendHeartbeatAsync(sharingEnabled = true, statusState = nextState)
        }
    }

    private val periodicHeartbeatRunnable = object : Runnable {
        override fun run() {
            val snap = DeviceStore.getSnapshot(applicationContext)
            if (!snap.isSharing) return

            val connected = ApiClient.isNetworkConnected(applicationContext)
            if (!connected) {
                DeviceStore.setSharingState(
                    applicationContext,
                    isSharing = true,
                    statusState = "offline",
                    errorMessage = "Offline — waiting for Wi-Fi or mobile data."
                )
                notifyAndRefreshNotification()
            } else {
                if (snap.hasPendingFix) {
                    flushPendingFixAsync()
                } else if (System.currentTimeMillis() - lastSubmittedUploadAtMs >= 50_000L) {
                    val heartbeatState = if (receivedFixThisSession) "sharing" else "no_gps_fix"
                    sendHeartbeatAsync(sharingEnabled = true, statusState = heartbeatState)
                }
                syncCirclePlacesAndAlertsAsync()
            }
            mainHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        executor = Executors.newSingleThreadExecutor()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        ensureNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_SHARING -> {
                handleStopSharing()
                return START_NOT_STICKY
            }
            ACTION_FLUSH_PENDING -> {
                flushPendingFixAsync()
                return START_STICKY
            }
            ACTION_SYNC_ALERTS -> {
                syncCirclePlacesAndAlertsAsync()
                return START_STICKY
            }
            ACTION_RECONFIGURE_MODE -> {
                val snap = DeviceStore.getSnapshot(applicationContext)
                if (snap.isSharing && hasLocationPermission()) {
                    startLocationRequests(snap.updateIntervalMs, preferHomeLowPower = shouldUseHomeLowPower(snap))
                    notifyAndRefreshNotification()
                }
                return START_STICKY
            }
            else -> {
                handleStartSharing()
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        unregisterLocationAndNetworkCallbacks()
        mainHandler.removeCallbacks(noGpsTimeoutRunnable)
        mainHandler.removeCallbacks(periodicHeartbeatRunnable)
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun shouldUseHomeLowPower(snap: DeviceStore.Snapshot): Boolean =
        snap.smartHomeMode && snap.presenceMode == "at_home"

    private fun handleStartSharing() {
        startAsForeground(buildNotification(DeviceStore.getSnapshot(applicationContext)))

        val snap = DeviceStore.getSnapshot(applicationContext)
        if (snap.deviceId.isEmpty() || snap.deviceToken.isEmpty()) {
            DeviceStore.setSharingState(
                applicationContext,
                isSharing = false,
                statusState = "unregistered",
                errorMessage = "Register this device before starting location sharing."
            )
            notifyStateChanged(applicationContext)
            stopSelfCleanly()
            return
        }

        if (!hasLocationPermission()) {
            DeviceStore.setSharingState(
                applicationContext,
                isSharing = false,
                statusState = "permission_missing",
                errorMessage = "Location permission is required to share coordinates."
            )
            notifyStateChanged(applicationContext)
            sendHeartbeatAsync(sharingEnabled = false, statusState = "permission_missing")
            stopSelfCleanly()
            return
        }

        receivedFixThisSession = false
        lastAcceptedLocation = null

        val initialState = if (ApiClient.isNetworkConnected(applicationContext)) "sharing" else "offline"
        DeviceStore.setSharingState(applicationContext, isSharing = true, statusState = initialState)
        notifyAndRefreshNotification()

        registerNetworkObserver()
        startLocationRequests(snap.updateIntervalMs, preferHomeLowPower = shouldUseHomeLowPower(snap))
        flushPendingFixAsync()
        syncCirclePlacesAndAlertsAsync()

        mainHandler.removeCallbacks(noGpsTimeoutRunnable)
        mainHandler.postDelayed(noGpsTimeoutRunnable, NO_GPS_TIMEOUT_MS)

        mainHandler.removeCallbacks(periodicHeartbeatRunnable)
        mainHandler.postDelayed(periodicHeartbeatRunnable, HEARTBEAT_INTERVAL_MS)

        sendHeartbeatAsync(sharingEnabled = true, statusState = if (initialState == "offline") "offline" else "no_gps_fix")
    }

    private fun handleStopSharing() {
        unregisterLocationAndNetworkCallbacks()
        mainHandler.removeCallbacks(noGpsTimeoutRunnable)
        mainHandler.removeCallbacks(periodicHeartbeatRunnable)

        val snap = DeviceStore.getSnapshot(applicationContext)
        val nextState = if (snap.deviceId.isNotEmpty()) "paused" else "unregistered"
        DeviceStore.setSharingState(applicationContext, isSharing = false, statusState = nextState)
        notifyStateChanged(applicationContext)

        if (snap.deviceId.isNotEmpty() && snap.deviceToken.isNotEmpty() && ApiClient.isNetworkConnected(applicationContext)) {
            executor.execute {
                ApiClient.sendHeartbeat(
                    context = applicationContext,
                    snap = snap,
                    sharingEnabled = false,
                    statusState = "paused"
                )
            }
        }

        stopSelfCleanly()
    }

    private fun stopSelfCleanly() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun startLocationRequests(intervalMs: Long, preferHomeLowPower: Boolean) {
        val lm = locationManager ?: return
        if (!hasLocationPermission()) return

        unregisterLocationOnly()
        activeLowPowerHomeSampling = preferHomeLowPower

        val minTime = if (preferHomeLowPower) HOME_LOW_POWER_INTERVAL_MS else intervalMs.coerceIn(10_000L, 300_000L)
        val minDistance = if (preferHomeLowPower) HOME_MIN_DISTANCE_METERS else AWAY_MIN_DISTANCE_METERS
        var anyProviderRequested = false

        try {
            val providers = mutableListOf<String>()
            if (preferHomeLowPower) {
                if (lm.allProviders.contains(LocationManager.NETWORK_PROVIDER) && lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    providers.add(LocationManager.NETWORK_PROVIDER)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && lm.allProviders.contains(LocationManager.FUSED_PROVIDER)) {
                    providers.add(LocationManager.FUSED_PROVIDER)
                }
                if (providers.isEmpty() && lm.allProviders.contains(LocationManager.GPS_PROVIDER) && lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    providers.add(LocationManager.GPS_PROVIDER)
                }
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && lm.allProviders.contains(LocationManager.FUSED_PROVIDER)) {
                    providers.add(LocationManager.FUSED_PROVIDER)
                }
                if (lm.allProviders.contains(LocationManager.GPS_PROVIDER) && lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    providers.add(LocationManager.GPS_PROVIDER)
                }
                if (lm.allProviders.contains(LocationManager.NETWORK_PROVIDER) && lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    providers.add(LocationManager.NETWORK_PROVIDER)
                }
            }

            if (providers.isEmpty()) {
                DeviceStore.setSharingState(
                    applicationContext,
                    isSharing = true,
                    statusState = "no_gps_fix",
                    errorMessage = "All Android location providers are disabled in device settings."
                )
                notifyAndRefreshNotification()
                return
            }

            for (provider in providers) {
                lm.requestLocationUpdates(provider, minTime, minDistance, locationListener, Looper.getMainLooper())
                anyProviderRequested = true

                val cached = lm.getLastKnownLocation(provider)
                if (cached != null && (System.currentTimeMillis() - cached.time) <= 60_000L) {
                    if (isBetterFix(cached, lastAcceptedLocation)) {
                        lastAcceptedLocation = cached
                    }
                }
            }

            listenersRegistered = anyProviderRequested
            lastAcceptedLocation?.let { handleNewLocation(it) }
        } catch (_: SecurityException) {
            DeviceStore.setSharingState(
                applicationContext,
                isSharing = false,
                statusState = "permission_missing",
                errorMessage = "Location permission denied by Android."
            )
            notifyStateChanged(applicationContext)
            stopSelfCleanly()
        }
    }

    private fun triggerQuickGpsProbe() {
        if (gpsProbeActive || !hasLocationPermission()) return
        val lm = locationManager ?: return
        if (!lm.allProviders.contains(LocationManager.GPS_PROVIDER) || !lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            return
        }
        try {
            gpsProbeActive = true
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2_000L, 0f, gpsProbeListener, Looper.getMainLooper())
            mainHandler.postDelayed({
                if (gpsProbeActive) {
                    gpsProbeActive = false
                    runCatching { lm.removeUpdates(gpsProbeListener) }
                }
            }, 15_000L)
        } catch (_: SecurityException) {
            gpsProbeActive = false
        }
    }

    private fun isBetterFix(candidate: Location, current: Location?): Boolean {
        if (current == null) return true
        val timeDelta = candidate.time - current.time
        if (timeDelta > 15_000L) return true
        if (timeDelta < -15_000L) return false
        val accDelta = (candidate.accuracy - current.accuracy)
        return accDelta < 0 || (timeDelta > 0 && accDelta <= 20f)
    }

    private fun handleNewLocation(location: Location) {
        val snap = DeviceStore.getSnapshot(applicationContext)
        if (!snap.isSharing) return
        if (!isBetterFix(location, lastAcceptedLocation)) return

        lastAcceptedLocation = location
        receivedFixThisSession = true
        mainHandler.removeCallbacks(noGpsTimeoutRunnable)

        val nowMs = System.currentTimeMillis()
        val clampedTimeMs = if (location.time > nowMs) nowMs else location.time
        val recordedAtIso = formatIsoUtc(clampedTimeMs)
        val accuracy = if (location.hasAccuracy() && location.accuracy > 0f) location.accuracy else null
        val speedMps = if (location.hasSpeed() && location.speed >= 0f) location.speed else null
        val netType = ApiClient.getNetworkType(applicationContext)

        // Evaluate Home & Saved Places geofences with hysteresis
        val places = GeofenceEvaluator.parsePlacesJson(snap.savedPlacesJson)
        val prevStates = GeofenceEvaluator.parseStatesJson(snap.geofenceStatesJson)
        val eval = GeofenceEvaluator.evaluate(
            latitude = location.latitude,
            longitude = location.longitude,
            accuracyMeters = accuracy,
            places = places,
            previousStates = prevStates,
            smartHomeMode = snap.smartHomeMode
        )

        DeviceStore.updatePresenceAndGeofenceStates(
            context = applicationContext,
            presenceMode = eval.presenceMode,
            currentPlaceId = eval.currentPlaceId,
            currentPlaceName = eval.currentPlaceName,
            homePrivacyMasked = eval.homePrivacyMasked,
            statesJson = GeofenceEvaluator.encodeStatesJson(eval.updatedStates)
        )

        val nextLowPowerHome = snap.smartHomeMode && eval.presenceMode == "at_home"
        if (nextLowPowerHome != activeLowPowerHomeSampling) {
            startLocationRequests(snap.updateIntervalMs, preferHomeLowPower = nextLowPowerHome)
        } else if (eval.shouldProbeGps && activeLowPowerHomeSampling) {
            triggerQuickGpsProbe()
        }

        if (!ApiClient.isNetworkConnected(applicationContext)) {
            DeviceStore.saveOrReplacePendingFix(
                applicationContext,
                DeviceStore.PendingFix(
                    latitude = eval.uploadLatitude,
                    longitude = eval.uploadLongitude,
                    accuracy = accuracy,
                    recordedAtIso = recordedAtIso,
                    networkType = netType
                ),
                errorMessage = "Offline — saved newest location point for upload on reconnect."
            )
            DeviceStore.setSharingState(
                applicationContext,
                isSharing = true,
                statusState = "offline",
                errorMessage = "Offline — saved newest location point for upload on reconnect."
            )
            notifyAndRefreshNotification()
            return
        }

        executor.execute {
            val currentSnap = DeviceStore.getSnapshot(applicationContext)
            if (!currentSnap.isSharing || currentSnap.deviceToken.isEmpty()) return@execute

            for (transition in eval.transitions) {
                ApiClient.reportPlaceEvent(
                    snap = currentSnap,
                    placeId = transition.place.placeId,
                    eventType = transition.eventType,
                    occurredAtIso = recordedAtIso
                )
            }

            val result = ApiClient.uploadLocation(
                context = applicationContext,
                snap = currentSnap,
                latitude = eval.uploadLatitude,
                longitude = eval.uploadLongitude,
                accuracy = accuracy,
                recordedAtIso = recordedAtIso,
                networkType = netType,
                presenceMode = eval.presenceMode,
                currentPlaceId = eval.currentPlaceId,
                currentPlaceName = eval.currentPlaceName,
                homePrivacyMasked = eval.homePrivacyMasked,
                speedMps = speedMps
            )

            if (!result.placesJson.isNullOrBlank()) {
                DeviceStore.setSavedPlacesJson(applicationContext, result.placesJson)
            }

            handleUploadResult(result, eval.uploadLatitude, eval.uploadLongitude, accuracy, recordedAtIso, netType)
        }
    }

    private fun flushPendingFixAsync() {
        val pending = DeviceStore.getPendingFix(applicationContext) ?: return
        if (!ApiClient.isNetworkConnected(applicationContext)) return

        executor.execute {
            val snap = DeviceStore.getSnapshot(applicationContext)
            if (snap.deviceId.isEmpty() || snap.deviceToken.isEmpty()) return@execute

            val result = ApiClient.uploadLocation(
                context = applicationContext,
                snap = snap,
                latitude = pending.latitude,
                longitude = pending.longitude,
                accuracy = pending.accuracy,
                recordedAtIso = pending.recordedAtIso,
                networkType = ApiClient.getNetworkType(applicationContext),
                presenceMode = snap.presenceMode,
                currentPlaceId = snap.currentPlaceId,
                currentPlaceName = snap.currentPlaceName,
                homePrivacyMasked = snap.homePrivacyMasked,
                speedMps = null
            )

            if (result.outcome == ApiClient.Outcome.SUCCESS) {
                DeviceStore.clearPendingFix(applicationContext)
                lastSubmittedUploadAtMs = System.currentTimeMillis()
                DeviceStore.recordSuccessfulUpload(
                    context = applicationContext,
                    uploadIso = formatIsoUtc(lastSubmittedUploadAtMs),
                    fixRecordedAtIso = pending.recordedAtIso,
                    latitude = pending.latitude,
                    longitude = pending.longitude,
                    accuracy = pending.accuracy
                )
                if (!result.placesJson.isNullOrBlank()) {
                    DeviceStore.setSavedPlacesJson(applicationContext, result.placesJson)
                }
                if (DeviceStore.getSnapshot(applicationContext).isSharing) {
                    DeviceStore.setSharingState(applicationContext, isSharing = true, statusState = "sharing")
                }
                notifyAndRefreshNotification()
            } else if (result.outcome == ApiClient.Outcome.UNAUTHORIZED) {
                handleUnauthorizedFromServer(result.message, result.errorCode)
            }
        }
    }

    private fun syncCirclePlacesAndAlertsAsync() {
        val snap = DeviceStore.getSnapshot(applicationContext)
        if (snap.deviceId.isEmpty() || snap.deviceToken.isEmpty() || !ApiClient.isNetworkConnected(applicationContext)) {
            return
        }
        executor.execute {
            val currentSnap = DeviceStore.getSnapshot(applicationContext)
            val (res, events) = ApiClient.fetchCircleSnapshot(currentSnap, currentSnap.lastSeenEventIso)
            if (res.outcome != ApiClient.Outcome.SUCCESS) return@execute

            val placesArr = res.bodyJson?.optJSONArray("places")?.toString()
            if (!placesArr.isNullOrBlank()) {
                DeviceStore.setSavedPlacesJson(applicationContext, placesArr)
            }

            if (events.isNotEmpty()) {
                val newestIso = events.first().occurredAt
                if (newestIso.isNotBlank()) {
                    DeviceStore.setLastSeenEventIso(applicationContext, newestIso)
                }
            } else if (currentSnap.lastSeenEventIso.isNullOrBlank()) {
                DeviceStore.setLastSeenEventIso(applicationContext, formatIsoUtc(System.currentTimeMillis()))
            }
        }
    }

    private fun handleUploadResult(
        result: ApiClient.ApiResult,
        latitude: Double,
        longitude: Double,
        accuracy: Float?,
        recordedAtIso: String,
        networkType: String
    ) {
        when (result.outcome) {
            ApiClient.Outcome.SUCCESS -> {
                lastSubmittedUploadAtMs = System.currentTimeMillis()
                DeviceStore.clearPendingFix(applicationContext)
                DeviceStore.recordSuccessfulUpload(
                    context = applicationContext,
                    uploadIso = formatIsoUtc(lastSubmittedUploadAtMs),
                    fixRecordedAtIso = recordedAtIso,
                    latitude = latitude,
                    longitude = longitude,
                    accuracy = accuracy
                )
                DeviceStore.setSharingState(applicationContext, isSharing = true, statusState = "sharing")
                notifyAndRefreshNotification()
            }
            ApiClient.Outcome.UNAUTHORIZED -> {
                handleUnauthorizedFromServer(result.message, result.errorCode)
            }
            ApiClient.Outcome.CLIENT_REJECTED -> {
                DeviceStore.setSharingState(
                    applicationContext,
                    isSharing = true,
                    statusState = "sharing",
                    errorMessage = result.message
                )
                notifyAndRefreshNotification()
            }
            ApiClient.Outcome.NETWORK_OR_SERVER_ERROR -> {
                DeviceStore.saveOrReplacePendingFix(
                    applicationContext,
                    DeviceStore.PendingFix(
                        latitude = latitude,
                        longitude = longitude,
                        accuracy = accuracy,
                        recordedAtIso = recordedAtIso,
                        networkType = networkType
                    ),
                    errorMessage = "Server unreachable (${result.message}). Keeping newest fix for retry."
                )
                DeviceStore.setSharingState(
                    applicationContext,
                    isSharing = true,
                    statusState = "offline",
                    errorMessage = "Server unreachable; kept newest fix for retry."
                )
                notifyAndRefreshNotification()
            }
        }
    }

    private fun handleUnauthorizedFromServer(message: String, errorCode: String?) {
        val nextState = if (errorCode == "DEVICE_UNREGISTERED") "unregistered" else "paused"
        DeviceStore.clearPendingFix(applicationContext)
        DeviceStore.setSharingState(
            applicationContext,
            isSharing = false,
            statusState = nextState,
            errorMessage = message
        )
        notifyStateChanged(applicationContext)
        mainHandler.post { stopSelfCleanly() }
    }

    private fun sendHeartbeatAsync(sharingEnabled: Boolean, statusState: String) {
        val snap = DeviceStore.getSnapshot(applicationContext)
        if (snap.deviceId.isEmpty() || snap.deviceToken.isEmpty()) return
        if (!ApiClient.isNetworkConnected(applicationContext)) return

        executor.execute {
            val res = ApiClient.sendHeartbeat(
                context = applicationContext,
                snap = snap,
                sharingEnabled = sharingEnabled,
                statusState = statusState
            )
            if (res.outcome == ApiClient.Outcome.UNAUTHORIZED) {
                handleUnauthorizedFromServer(res.message, res.errorCode)
            }
        }
    }

    private fun registerNetworkObserver() {
        val cm = connectivityManager ?: return
        if (networkCallback != null) return

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val snap = DeviceStore.getSnapshot(applicationContext)
                if (snap.isSharing && snap.statusState == "offline") {
                    DeviceStore.setSharingState(
                        applicationContext,
                        isSharing = true,
                        statusState = if (receivedFixThisSession) "sharing" else "no_gps_fix"
                    )
                    notifyAndRefreshNotification()
                }
                flushPendingFixAsync()
            }

            override fun onLost(network: Network) {
                if (!ApiClient.isNetworkConnected(applicationContext) && DeviceStore.getSnapshot(applicationContext).isSharing) {
                    DeviceStore.setSharingState(
                        applicationContext,
                        isSharing = true,
                        statusState = "offline",
                        errorMessage = "Network lost — newest location will queue until reconnected."
                    )
                    notifyAndRefreshNotification()
                }
            }
        }
        networkCallback = cb
        runCatching { cm.registerDefaultNetworkCallback(cb) }
    }

    private fun unregisterLocationOnly() {
        if (listenersRegistered) {
            runCatching { locationManager?.removeUpdates(locationListener) }
            listenersRegistered = false
        }
        if (gpsProbeActive) {
            runCatching { locationManager?.removeUpdates(gpsProbeListener) }
            gpsProbeActive = false
        }
    }

    private fun unregisterLocationAndNetworkCallbacks() {
        unregisterLocationOnly()
        networkCallback?.let { cb ->
            runCatching { connectivityManager?.unregisterNetworkCallback(cb) }
            networkCallback = null
        }
    }

    private fun notifyAndRefreshNotification() {
        val snap = DeviceStore.getSnapshot(applicationContext)
        notifyStateChanged(applicationContext)
        if (snap.isSharing) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.notify(NOTIFICATION_ID, buildNotification(snap))
        }
    }

    private fun ensureNotificationChannels() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Active Location Sharing",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Background foreground-service channel used while LocaShare shares your location."
                    setShowBadge(false)
                }
            )
        }
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(snap: DeviceStore.Snapshot): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            100,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, StopSharingReceiver::class.java)
        val stopPending = PendingIntent.getBroadcast(
            this,
            101,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = when {
            snap.statusState == "offline" -> "LocaShare · Offline (newest point saved)"
            snap.statusState == "no_gps_fix" -> "LocaShare · Waiting for GPS fix"
            snap.statusState == "permission_missing" -> "LocaShare · Location permission missing"
            snap.presenceMode == "at_home" && snap.smartHomeMode -> "LocaShare · At Home (Battery Saver)"
            snap.presenceMode == "at_place" && !snap.currentPlaceName.isNullOrBlank() ->
                "LocaShare · At ${snap.currentPlaceName}"
            snap.presenceMode == "away" -> "LocaShare · Away from Home (Live GPS)"
            else -> "LocaShare · Sharing location"
        }

        val content = if (snap.presenceMode == "at_home" && snap.smartHomeMode) {
            "Inside Home · Live GPS activates automatically when leaving."
        } else {
            val accText = snap.lastAccuracy?.let { "±${it.toInt()}m" } ?: "pending accuracy"
            val pendingNote = if (snap.hasPendingFix) " · 1 fix queued" else ""
            "Accuracy: $accText$pendingNote · Tap Stop sharing to pause."
        }

        val stopAction = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_pause),
            "Stop sharing",
            stopPending
        ).build()

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPending)
            .addAction(stopAction)
            .build()
    }

    private fun formatIsoUtc(epochMs: Long): String =
        DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC).format(Instant.ofEpochMilli(epochMs))
}
