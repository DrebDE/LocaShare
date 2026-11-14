package com.locashare.app.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.locashare.app.R
import com.locashare.app.model.LocationSample
import com.locashare.app.model.TrackingState
import com.locashare.app.model.TrackingStateResolver
import com.locashare.app.network.LocaShareApiClient
import com.locashare.app.storage.LocaSharePreferences
import com.locashare.app.storage.OfflineLocationStore
import com.locashare.app.ui.MainActivity
import java.util.concurrent.Executors

/**
 * Foreground location service that shares the phone's latest location while keeping
 * sharing visibly active with a persistent notification and an immediate Stop action.
 */
class LocationSharingService : Service(), LocationListener {

    private lateinit var prefs: LocaSharePreferences
    private lateinit var offlineStore: OfflineLocationStore
    private lateinit var locationManager: LocationManager
    private lateinit var connectivityManager: ConnectivityManager
    private lateinit var notificationManager: NotificationManager

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var isRunning = false
    private var networkCallbackRegistered = false

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            ioExecutor.execute {
                flushPendingOrSendHeartbeat()
            }
            mainHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (!isRunning) return
            ioExecutor.execute {
                flushPendingOfflineLocation()
                broadcastStateChanged()
            }
        }

        override fun onLost(network: Network) {
            if (!isRunning) return
            updateNotification("Offline — newest location fix will be sent when reconnected")
            broadcastStateChanged()
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = LocaSharePreferences(this)
        offlineStore = OfflineLocationStore(this)
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_SHARING -> {
                stopSharingAndService(notifyServerPaused = true)
                return START_NOT_STICKY
            }
            ACTION_START_SHARING, null -> {
                startSharingForeground()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        cleanupListeners()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun startSharingForeground() {
        if (!prefs.isRegistered) {
            stopSelf()
            return
        }

        if (!hasLocationPermission()) {
            prefs.sharingEnabled = false
            broadcastStateChanged()
            stopSelf()
            return
        }

        prefs.sharingEnabled = true
        prefs.hasSharedPreviously = true

        val initialNotification = buildPersistentNotification("Starting location sharing…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                initialNotification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            )
        } else {
            startForeground(NOTIFICATION_ID, initialNotification)
        }

        if (!isRunning) {
            isRunning = true
            registerLocationUpdates()
            registerConnectivityCallback()
            mainHandler.removeCallbacks(heartbeatRunnable)
            mainHandler.post(heartbeatRunnable)
        }

        broadcastStateChanged()
    }

    private fun stopSharingAndService(notifyServerPaused: Boolean) {
        isRunning = false
        prefs.sharingEnabled = false
        cleanupListeners()

        val deviceId = prefs.deviceId
        val deviceToken = prefs.deviceToken
        val serverUrl = prefs.serverUrl

        if (notifyServerPaused && !deviceId.isNullOrBlank() && !deviceToken.isNullOrBlank()) {
            Thread {
                val battery = readBatteryState()
                LocaShareApiClient.sendHeartbeat(
                    serverUrl = serverUrl,
                    deviceId = deviceId,
                    deviceToken = deviceToken,
                    sharingEnabled = false,
                    statusState = TrackingState.PAUSED.apiCode,
                    batteryPercent = battery.first,
                    isCharging = battery.second,
                    networkType = readNetworkType()
                )
            }.start()
        }

        broadcastStateChanged()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun registerLocationUpdates() {
        if (!hasLocationPermission()) return

        try {
            val providers = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                locationManager.isProviderEnabled(LocationManager.FUSED_PROVIDER)
            ) {
                providers.add(LocationManager.FUSED_PROVIDER)
            }
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                providers.add(LocationManager.GPS_PROVIDER)
            }
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                providers.add(LocationManager.NETWORK_PROVIDER)
            }

            var bestLastKnown: Location? = null
            for (provider in providers) {
                locationManager.requestLocationUpdates(
                    provider,
                    LOCATION_INTERVAL_MS,
                    LOCATION_MIN_DISTANCE_M,
                    this,
                    Looper.getMainLooper()
                )
                val candidate = locationManager.getLastKnownLocation(provider)
                if (candidate != null && (bestLastKnown == null || candidate.time > bestLastKnown.time)) {
                    bestLastKnown = candidate
                }
            }

            if (bestLastKnown != null) {
                onLocationChanged(bestLastKnown)
            } else {
                prefs.hasGpsFix = false
                updateNotification("Sharing active — waiting for GPS fix…")
                broadcastStateChanged()
            }
        } catch (_: SecurityException) {
            prefs.sharingEnabled = false
            broadcastStateChanged()
            stopSelf()
        }
    }

    private fun registerConnectivityCallback() {
        if (networkCallbackRegistered) return
        try {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            networkCallbackRegistered = true
        } catch (_: Exception) {
            networkCallbackRegistered = false
        }
    }

    private fun cleanupListeners() {
        mainHandler.removeCallbacks(heartbeatRunnable)
        try {
            locationManager.removeUpdates(this)
        } catch (_: Exception) {
        }
        if (networkCallbackRegistered) {
            try {
                connectivityManager.unregisterNetworkCallback(networkCallback)
            } catch (_: Exception) {
            }
            networkCallbackRegistered = false
        }
    }

    override fun onLocationChanged(location: Location) {
        if (!isRunning || !prefs.sharingEnabled) return

        val accuracy = if (location.hasAccuracy()) location.accuracy else null
        prefs.hasGpsFix = true
        if (accuracy != null) {
            prefs.lastAccuracyMeters = accuracy
        }

        val battery = readBatteryState()
        val netType = readNetworkType()
        val fixTimeMs = if (location.time > 0L) location.time else System.currentTimeMillis()

        val sample = LocationSample(
            latitude = location.latitude,
            longitude = location.longitude,
            accuracyMeters = accuracy,
            recordedAtEpochMs = fixTimeMs,
            batteryPercent = battery.first,
            isCharging = battery.second,
            networkType = netType
        )

        ioExecutor.execute {
            handleNewLocationSample(sample)
        }
    }

    private fun handleNewLocationSample(sample: LocationSample) {
        if (!sample.isValid()) return

        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return
        val serverUrl = prefs.serverUrl

        if (!isNetworkConnected()) {
            offlineStore.saveOrReplaceNewest(sample)
            updateNotification("Offline — newest fix saved for retry")
            broadcastStateChanged()
            return
        }

        val res = LocaShareApiClient.sendLocationUpdate(
            serverUrl = serverUrl,
            deviceId = deviceId,
            deviceToken = deviceToken,
            sample = sample
        )

        if (res.success) {
            offlineStore.clearPending(sample.recordedAtEpochMs)
            prefs.lastSuccessfulUploadEpochMs = System.currentTimeMillis()
            if (res.data != null) {
                prefs.hasActivePairing = res.data > 0
            }
            val accLabel = sample.accuracyMeters?.let { "±${it.toInt()}m" } ?: "fix sent"
            updateNotification("Sharing location ($accLabel)")
        } else if (res.isNetworkError) {
            // Save or replace the single pending offline point with this newest fix
            offlineStore.saveOrReplaceNewest(sample)
            updateNotification("Offline — newest fix queued for retry")
        }

        broadcastStateChanged()
    }

    private fun flushPendingOfflineLocation() {
        val pending = offlineStore.peekPending() ?: return
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return

        if (!isNetworkConnected()) return

        val res = LocaShareApiClient.sendLocationUpdate(
            serverUrl = prefs.serverUrl,
            deviceId = deviceId,
            deviceToken = deviceToken,
            sample = pending
        )
        if (res.success) {
            offlineStore.clearPending(pending.recordedAtEpochMs)
            prefs.lastSuccessfulUploadEpochMs = System.currentTimeMillis()
            if (res.data != null) {
                prefs.hasActivePairing = res.data > 0
            }
            updateNotification("Reconnected — newest queued location uploaded")
            broadcastStateChanged()
        }
    }

    private fun flushPendingOrSendHeartbeat() {
        if (!isNetworkConnected()) {
            broadcastStateChanged()
            return
        }

        // First flush any pending offline location fix (single newest point)
        val pending = offlineStore.peekPending()
        if (pending != null) {
            flushPendingOfflineLocation()
            return
        }

        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return
        val battery = readBatteryState()

        val resolvedState = TrackingStateResolver.resolve(
            isRegistered = prefs.isRegistered,
            hasLocationPermission = hasLocationPermission(),
            isSharingEnabled = prefs.sharingEnabled,
            hasActivePairing = prefs.hasActivePairing,
            isNetworkOnline = true,
            hasGpsFix = prefs.hasGpsFix,
            hasSharedPreviously = prefs.hasSharedPreviously
        )

        val hb = LocaShareApiClient.sendHeartbeat(
            serverUrl = prefs.serverUrl,
            deviceId = deviceId,
            deviceToken = deviceToken,
            sharingEnabled = prefs.sharingEnabled,
            statusState = resolvedState.apiCode,
            batteryPercent = battery.first,
            isCharging = battery.second,
            networkType = readNetworkType()
        )
        if (hb.success && hb.data != null) {
            prefs.hasActivePairing = hb.data.hasActivePairing
            broadcastStateChanged()
        }
    }

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun isNetworkConnected(): Boolean {
        val activeNet = connectivityManager.activeNetwork ?: return false
        val caps = connectivityManager.getNetworkCapabilities(activeNet) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun readNetworkType(): String {
        val activeNet = connectivityManager.activeNetwork ?: return "offline"
        val caps = connectivityManager.getNetworkCapabilities(activeNet) ?: return "offline"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "online"
        }
    }

    private fun readBatteryState(): Pair<Int?, Boolean?> {
        return try {
            val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (intent == null) return Pair(null, null)
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val pct = if (level >= 0 && scale > 0) ((level * 100) / scale) else null
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            Pair(pct, charging)
        } catch (_: Exception) {
            Pair(null, null)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.notification_channel_desc)
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun buildPersistentNotification(contentText: String): Notification {
        val openActivityIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            100,
            openActivityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, LocationSharingService::class.java).apply {
            action = ACTION_STOP_SHARING
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            101,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val stopAction = Notification.Action.Builder(
            android.R.drawable.ic_media_pause,
            getString(R.string.notification_stop_action),
            stopPendingIntent
        ).build()

        return builder
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPendingIntent)
            .addAction(stopAction)
            .build()
    }

    private fun updateNotification(contentText: String) {
        if (!isRunning) return
        notificationManager.notify(NOTIFICATION_ID, buildPersistentNotification(contentText))
    }

    private fun broadcastStateChanged() {
        val intent = Intent(ACTION_STATE_CHANGED).apply {
            setPackage(packageName)
        }
        sendBroadcast(intent)
    }

    companion object {
        const val CHANNEL_ID = "locashare_active_sharing_channel"
        const val NOTIFICATION_ID = 4102

        const val ACTION_START_SHARING = "com.locashare.app.action.START_SHARING"
        const val ACTION_STOP_SHARING = "com.locashare.app.action.STOP_SHARING"
        const val ACTION_STATE_CHANGED = "com.locashare.app.action.STATE_CHANGED"

        // Battery-conscious location interval (30 seconds / 15 meters minimum displacement)
        const val LOCATION_INTERVAL_MS = 30_000L
        const val LOCATION_MIN_DISTANCE_M = 15f
        const val HEARTBEAT_INTERVAL_MS = 30_000L
    }
}
