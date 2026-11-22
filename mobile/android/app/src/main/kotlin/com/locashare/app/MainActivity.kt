package com.locashare.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterActivity hosting LocaShare's MethodChannel & EventChannel bridge to
 * native Android permissions, foreground service lifecycle, and DeviceStore.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "com.locashare.app/location_service"
        private const val EVENT_CHANNEL = "com.locashare.app/location_events"
        private const val REQ_CODE_PERMISSIONS = 7001
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    LocationSharingService.setStateListener { payload ->
                        eventSink?.success(attachPermissionFields(payload))
                    }
                    events?.success(buildFullStatePayload())
                }

                override fun onCancel(arguments: Any?) {
                    LocationSharingService.setStateListener(null)
                    eventSink = null
                }
            })
    }

    override fun onResume() {
        super.onResume()
        eventSink?.success(buildFullStatePayload())
    }

    override fun onDestroy() {
        LocationSharingService.setStateListener(null)
        eventSink = null
        super.onDestroy()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> {
                result.success(buildFullStatePayload())
            }
            "checkPermissions" -> {
                result.success(permissionStatusMap())
            }
            "requestLocationPermissions" -> {
                requestPermissionsFlow(result)
            }
            "openAppSettings" -> {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null)
                )
                startActivity(intent)
                result.success(true)
            }
            "openLocationSettings" -> {
                startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                result.success(true)
            }
            "setServerUrl" -> {
                val serverUrl = call.argument<String>("serverUrl") ?: ""
                DeviceStore.setServerUrl(this, serverUrl)
                result.success(buildFullStatePayload())
            }
            "setBackendConfig" -> {
                val mode = call.argument<String>("backendMode") ?: "php"
                val serverUrl = call.argument<String>("serverUrl") ?: ""
                val supabaseUrl = call.argument<String>("supabaseUrl") ?: ""
                val supabaseAnonKey = call.argument<String>("supabaseAnonKey") ?: ""
                DeviceStore.setBackendConfig(this, mode, serverUrl, supabaseUrl, supabaseAnonKey)
                result.success(buildFullStatePayload())
            }
            "setSmartHomeMode" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                DeviceStore.setSmartHomeMode(this, enabled)
                if (DeviceStore.getSnapshot(this).isSharing) {
                    val reconf = Intent(this, LocationSharingService::class.java).apply {
                        action = LocationSharingService.ACTION_RECONFIGURE_MODE
                    }
                    runCatching { startService(reconf) }
                }
                result.success(buildFullStatePayload())
            }
            "setCircleInfo" -> {
                val circleId = call.argument<String>("circleId") ?: ""
                val circleName = call.argument<String>("circleName") ?: ""
                val memberName = call.argument<String>("memberName") ?: ""
                DeviceStore.setCircleInfo(this, circleId, circleName, memberName)
                result.success(buildFullStatePayload())
            }
            "setSavedPlaces" -> {
                val placesJson = call.argument<String>("placesJson") ?: "[]"
                DeviceStore.setSavedPlacesJson(this, placesJson)
                if (DeviceStore.getSnapshot(this).isSharing) {
                    val reconf = Intent(this, LocationSharingService::class.java).apply {
                        action = LocationSharingService.ACTION_RECONFIGURE_MODE
                    }
                    runCatching { startService(reconf) }
                }
                result.success(buildFullStatePayload())
            }
            "syncFamilyAlertsNow" -> {
                if (DeviceStore.getSnapshot(this).isSharing) {
                    val syncIntent = Intent(this, LocationSharingService::class.java).apply {
                        action = LocationSharingService.ACTION_SYNC_ALERTS
                    }
                    runCatching { startService(syncIntent) }
                }
                result.success(buildFullStatePayload())
            }
            "setIntervalMs" -> {
                val ms = call.argument<Number>("intervalMs")?.toLong() ?: 30_000L
                DeviceStore.setIntervalMs(this, ms)
                result.success(buildFullStatePayload())
            }
            "configureDevice" -> {
                val serverUrl = call.argument<String>("serverUrl") ?: ""
                val deviceId = call.argument<String>("deviceId") ?: ""
                val deviceToken = call.argument<String>("deviceToken") ?: ""
                val deviceName = call.argument<String>("deviceName") ?: DeviceStore.defaultDeviceModel()
                val statusState = call.argument<String>("statusState") ?: "waiting_for_pairing"
                val intervalMs = call.argument<Number>("updateIntervalMs")?.toLong() ?: 30_000L

                DeviceStore.configureDevice(
                    context = this,
                    serverUrl = serverUrl,
                    deviceId = deviceId,
                    deviceToken = deviceToken,
                    deviceName = deviceName,
                    statusState = statusState,
                    updateIntervalMs = intervalMs
                )
                result.success(buildFullStatePayload())
            }
            "startSharing" -> {
                if (!hasLocationPermission()) {
                    DeviceStore.setSharingState(
                        this,
                        isSharing = false,
                        statusState = "permission_missing",
                        errorMessage = "Location permission is required before sharing can start."
                    )
                    result.success(buildFullStatePayload())
                    return
                }
                val startIntent = Intent(this, LocationSharingService::class.java).apply {
                    action = LocationSharingService.ACTION_START_SHARING
                }
                startForegroundService(startIntent)
                result.success(buildFullStatePayload())
            }
            "stopSharing" -> {
                val stopIntent = Intent(this, LocationSharingService::class.java).apply {
                    action = LocationSharingService.ACTION_STOP_SHARING
                }
                runCatching { startService(stopIntent) }.onFailure {
                    DeviceStore.setSharingState(this, isSharing = false, statusState = "paused")
                }
                result.success(buildFullStatePayload())
            }
            "flushPendingNow" -> {
                val snap = DeviceStore.getSnapshot(this)
                if (snap.hasPendingFix && snap.isSharing) {
                    val flushIntent = Intent(this, LocationSharingService::class.java).apply {
                        action = LocationSharingService.ACTION_FLUSH_PENDING
                    }
                    runCatching { startService(flushIntent) }
                }
                result.success(buildFullStatePayload())
            }
            "clearLocationMetadata" -> {
                DeviceStore.clearLocationMetadata(this)
                result.success(buildFullStatePayload())
            }
            "unregisterReset" -> {
                runCatching { stopService(Intent(this, LocationSharingService::class.java)) }
                DeviceStore.clearRegistration(this)
                result.success(buildFullStatePayload())
            }
            "getCurrentLocation" -> {
                result.success(readBestCachedLocation())
            }
            else -> result.notImplemented()
        }
    }

    private fun readBestCachedLocation(): Map<String, Any?> {
        val snap = DeviceStore.getSnapshot(this)
        if (!hasLocationPermission()) {
            if (snap.lastLatitude != null && snap.lastLongitude != null) {
                return mapOf("latitude" to snap.lastLatitude, "longitude" to snap.lastLongitude)
            }
            return emptyMap()
        }
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        var best: Location? = null
        if (lm != null) {
            val providers = listOfNotNull(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) LocationManager.FUSED_PROVIDER else null,
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER
            )
            for (p in providers) {
                val loc = runCatching { lm.getLastKnownLocation(p) }.getOrNull() ?: continue
                if (best == null || loc.time > best.time) {
                    best = loc
                }
            }
        }
        return if (best != null) {
            mapOf(
                "latitude" to best.latitude,
                "longitude" to best.longitude,
                "accuracy" to best.accuracy.toDouble()
            )
        } else if (snap.lastLatitude != null && snap.lastLongitude != null) {
            mapOf("latitude" to snap.lastLatitude, "longitude" to snap.lastLongitude)
        } else {
            emptyMap()
        }
    }

    private fun requestPermissionsFlow(result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_IN_PROGRESS", "Permission request already pending.", null)
            return
        }

        val toRequest = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            toRequest.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            toRequest.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }

        if (toRequest.isEmpty()) {
            result.success(permissionStatusMap())
            return
        }

        pendingPermissionResult = result
        requestPermissions(toRequest.toTypedArray(), REQ_CODE_PERMISSIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CODE_PERMISSIONS) {
            val cb = pendingPermissionResult
            pendingPermissionResult = null
            val status = permissionStatusMap()
            val hasLoc = status["hasLocationPermission"] == true
            val snap = DeviceStore.getSnapshot(this)
            if (!hasLoc && snap.deviceId.isNotEmpty()) {
                DeviceStore.setSharingState(
                    this,
                    isSharing = false,
                    statusState = "permission_missing",
                    errorMessage = "Location permission denied by phone owner."
                )
            } else if (hasLoc && snap.statusState == "permission_missing") {
                val recovered = if (snap.deviceId.isNotEmpty()) "registered" else "unregistered"
                DeviceStore.setSharingState(this, isSharing = false, statusState = recovered)
            }
            eventSink?.success(buildFullStatePayload())
            cb?.success(status)
        }
    }

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun permissionStatusMap(): Map<String, Any> {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val gpsOrNetEnabled = if (lm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else if (lm != null) {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } else {
            true
        }

        return mapOf(
            "hasLocationPermission" to (fine || coarse),
            "hasFineLocation" to fine,
            "hasCoarseLocation" to coarse,
            "hasNotificationPermission" to false,
            "isLocationServiceEnabled" to gpsOrNetEnabled
        )
    }

    private fun attachPermissionFields(base: Map<String, Any?>): Map<String, Any?> {
        val merged = HashMap<String, Any?>(base)
        merged.putAll(permissionStatusMap())
        merged["defaultDeviceName"] = DeviceStore.defaultDeviceModel()
        merged["isNetworkConnected"] = ApiClient.isNetworkConnected(this)
        merged["networkType"] = ApiClient.getNetworkType(this)
        return merged
    }

    private fun buildFullStatePayload(): Map<String, Any?> =
        attachPermissionFields(DeviceStore.toMap(DeviceStore.getSnapshot(this)))
}
