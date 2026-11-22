package com.locashare.app.ui

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.locashare.app.R
import com.locashare.app.model.ServerUrlValidator
import com.locashare.app.model.TrackingState
import com.locashare.app.model.TrackingStateResolver
import com.locashare.app.network.LocaShareApiClient
import com.locashare.app.service.LocationSharingService
import com.locashare.app.storage.LocaSharePreferences
import com.locashare.app.storage.OfflineLocationStore
import com.locashare.app.util.PairingQrGenerator
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Main phone owner screen for LocaShare.
 *
 * Provides self-service device registration (no login/account), one-time pairing code + QR display,
 * explicit location permission explanation, Start/Stop sharing controls, dashboard pairing revocation,
 * stored location deletion, and device unregistration.
 */
class MainActivity : Activity() {

    private lateinit var prefs: LocaSharePreferences
    private lateinit var offlineStore: OfflineLocationStore
    private lateinit var connectivityManager: ConnectivityManager

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val uiHandler = Handler(Looper.getMainLooper())

    private lateinit var tvStateBadge: TextView
    private lateinit var tvStateDetail: TextView
    private lateinit var tvAccuracy: TextView
    private lateinit var tvLastUpload: TextView
    private lateinit var tvNetworkStatus: TextView
    private lateinit var tvPendingOffline: TextView

    private lateinit var etServerUrl: EditText
    private lateinit var btnSaveServer: Button

    private lateinit var etDeviceName: EditText
    private lateinit var btnRegisterDevice: Button
    private lateinit var tvDeviceId: TextView
    private lateinit var layoutPairingBox: LinearLayout
    private lateinit var tvPairingCode: TextView
    private lateinit var ivPairingQr: ImageView
    private lateinit var tvPairingExpiry: TextView
    private lateinit var btnNewPairingCode: Button

    private lateinit var btnRequestPermission: Button
    private lateinit var btnStartSharing: Button
    private lateinit var btnStopSharing: Button

    private lateinit var btnRevokePairing: Button
    private lateinit var btnDeleteLocation: Button
    private lateinit var btnUnregisterDevice: Button

    private var pendingStartSharingAfterPermission = false

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            refreshUiState()
        }
    }

    private val tickerRunnable = object : Runnable {
        override fun run() {
            refreshUiState()
            uiHandler.postDelayed(this, 1_000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        prefs = LocaSharePreferences(this)
        offlineStore = OfflineLocationStore(this)
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        bindViews()
        etServerUrl.setText(prefs.serverUrl)
        etDeviceName.setText(prefs.deviceName)

        refreshUiState()
        syncStatusFromBackend()
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(LocationSharingService.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(stateReceiver, filter)
        }
        uiHandler.post(tickerRunnable)
    }

    override fun onStop() {
        uiHandler.removeCallbacks(tickerRunnable)
        try {
            unregisterReceiver(stateReceiver)
        } catch (_: Exception) {
        }
        super.onStop()
    }

    override fun onDestroy() {
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun bindViews() {
        tvStateBadge = findViewById(R.id.tv_state_badge)
        tvStateDetail = findViewById(R.id.tv_state_detail)
        tvAccuracy = findViewById(R.id.tv_accuracy)
        tvLastUpload = findViewById(R.id.tv_last_upload)
        tvNetworkStatus = findViewById(R.id.tv_network_status)
        tvPendingOffline = findViewById(R.id.tv_pending_offline)

        etServerUrl = findViewById(R.id.et_server_url)
        btnSaveServer = findViewById(R.id.btn_save_server)

        etDeviceName = findViewById(R.id.et_device_name)
        btnRegisterDevice = findViewById(R.id.btn_register_device)
        tvDeviceId = findViewById(R.id.tv_device_id)
        layoutPairingBox = findViewById(R.id.layout_pairing_box)
        tvPairingCode = findViewById(R.id.tv_pairing_code)
        ivPairingQr = findViewById(R.id.iv_pairing_qr)
        tvPairingExpiry = findViewById(R.id.tv_pairing_expiry)
        btnNewPairingCode = findViewById(R.id.btn_new_pairing_code)

        btnRequestPermission = findViewById(R.id.btn_request_permission)
        btnStartSharing = findViewById(R.id.btn_start_sharing)
        btnStopSharing = findViewById(R.id.btn_stop_sharing)

        btnRevokePairing = findViewById(R.id.btn_revoke_pairing)
        btnDeleteLocation = findViewById(R.id.btn_delete_location)
        btnUnregisterDevice = findViewById(R.id.btn_unregister_device)

        btnSaveServer.setOnClickListener { handleSaveServerUrl() }
        btnRegisterDevice.setOnClickListener { handleRegisterDevice() }
        btnNewPairingCode.setOnClickListener { handleGeneratePairingCode() }

        btnRequestPermission.setOnClickListener {
            pendingStartSharingAfterPermission = false
            showPermissionExplanationAndRequest()
        }
        btnStartSharing.setOnClickListener { handleStartSharingClicked() }
        btnStopSharing.setOnClickListener { handleStopSharingClicked() }

        btnRevokePairing.setOnClickListener { handleRevokePairingClicked() }
        btnDeleteLocation.setOnClickListener { handleDeleteLocationClicked() }
        btnUnregisterDevice.setOnClickListener { handleUnregisterDeviceClicked() }
    }

    private fun handleSaveServerUrl(): Boolean {
        val raw = etServerUrl.text.toString()
        val validation = ServerUrlValidator.validate(raw)
        if (!validation.isValid) {
            Toast.makeText(this, validation.errorMessage ?: "Invalid Server URL", Toast.LENGTH_LONG).show()
            return false
        }
        prefs.serverUrl = validation.normalizedUrl
        etServerUrl.setText(validation.normalizedUrl)
        Toast.makeText(this, "Server URL saved.", Toast.LENGTH_SHORT).show()
        return true
    }

    private fun handleRegisterDevice() {
        if (!handleSaveServerUrl()) return

        val deviceName = etDeviceName.text.toString().trim().ifEmpty { prefs.deviceName }
        prefs.deviceName = deviceName
        btnRegisterDevice.isEnabled = false

        ioExecutor.execute {
            val res = LocaShareApiClient.registerDevice(prefs.serverUrl, deviceName)
            uiHandler.post {
                btnRegisterDevice.isEnabled = true
                if (!res.success || res.data == null) {
                    Toast.makeText(
                        this,
                        res.errorMessage ?: "Failed to register device.",
                        Toast.LENGTH_LONG
                    ).show()
                    return@post
                }

                val data = res.data
                prefs.deviceId = data.deviceId
                prefs.deviceName = data.deviceName
                prefs.deviceToken = data.deviceToken
                prefs.pairingCode = data.pairingCode
                prefs.pairingQrPayload = data.pairingQrPayload
                prefs.pairingExpiresAtEpochMs = data.pairingExpiresAtEpochMs
                prefs.hasActivePairing = false
                prefs.sharingEnabled = false

                renderPairingQr(data.pairingQrPayload.ifBlank { data.pairingCode })
                refreshUiState()
                Toast.makeText(
                    this,
                    "Device registered! Enter or scan the one-time pairing code on your laptop dashboard.",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun handleGeneratePairingCode() {
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return
        btnNewPairingCode.isEnabled = false

        ioExecutor.execute {
            val res = LocaShareApiClient.generateNewPairingCode(prefs.serverUrl, deviceId, deviceToken)
            uiHandler.post {
                btnNewPairingCode.isEnabled = true
                if (!res.success || res.data == null) {
                    Toast.makeText(
                        this,
                        res.errorMessage ?: "Failed to generate new pairing code.",
                        Toast.LENGTH_LONG
                    ).show()
                    return@post
                }

                prefs.pairingCode = res.data.pairingCode
                prefs.pairingQrPayload = res.data.pairingQrPayload
                prefs.pairingExpiresAtEpochMs = res.data.pairingExpiresAtEpochMs
                prefs.hasActivePairing = res.data.pairedDashboardsCount > 0

                renderPairingQr(res.data.pairingQrPayload.ifBlank { res.data.pairingCode })
                refreshUiState()
            }
        }
    }

    private fun handleStartSharingClicked() {
        if (!prefs.isRegistered) {
            Toast.makeText(this, "Please register this device first.", Toast.LENGTH_SHORT).show()
            return
        }

        if (!hasLocationPermission()) {
            pendingStartSharingAfterPermission = true
            showPermissionExplanationAndRequest()
            return
        }

        startForegroundSharingService()
    }

    private fun handleStopSharingClicked() {
        val stopIntent = Intent(this, LocationSharingService::class.java).apply {
            action = LocationSharingService.ACTION_STOP_SHARING
        }
        startService(stopIntent)
        prefs.sharingEnabled = false
        refreshUiState()
        Toast.makeText(this, "Location sharing stopped.", Toast.LENGTH_SHORT).show()
    }

    private fun handleRevokePairingClicked() {
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return

        AlertDialog.Builder(this)
            .setTitle("Revoke Dashboard Pairing?")
            .setMessage("This immediately revokes laptop dashboard access to your phone and clears your stored location on the server.")
            .setPositiveButton("Revoke Pairing") { _, _ ->
                if (prefs.sharingEnabled) {
                    handleStopSharingClicked()
                }
                ioExecutor.execute {
                    val res = LocaShareApiClient.unpairDashboards(prefs.serverUrl, deviceId, deviceToken, clearLocation = true)
                    uiHandler.post {
                        if (res.success) {
                            prefs.hasActivePairing = false
                            prefs.clearStoredLocationMetadata()
                            refreshUiState()
                            Toast.makeText(this, "Dashboard pairing revoked.", Toast.LENGTH_SHORT).show()
                        } else {
                            Toast.makeText(this, res.errorMessage ?: "Failed to revoke pairing.", Toast.LENGTH_LONG).show()
                        }
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun handleDeleteLocationClicked() {
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return

        AlertDialog.Builder(this)
            .setTitle("Delete Stored Location?")
            .setMessage("This deletes your phone’s latest coordinates from the backend database and clears any queued offline point.")
            .setPositiveButton("Delete Location") { _, _ ->
                offlineStore.clearPending()
                ioExecutor.execute {
                    val res = LocaShareApiClient.deleteStoredLocation(prefs.serverUrl, deviceId, deviceToken)
                    uiHandler.post {
                        if (res.success) {
                            prefs.clearStoredLocationMetadata()
                            refreshUiState()
                            Toast.makeText(this, "Stored location deleted.", Toast.LENGTH_SHORT).show()
                        } else {
                            Toast.makeText(this, res.errorMessage ?: "Failed to delete stored location.", Toast.LENGTH_LONG).show()
                        }
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun handleUnregisterDeviceClicked() {
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return

        AlertDialog.Builder(this)
            .setTitle("Unregister This Device?")
            .setMessage("This stops location sharing, revokes all laptop pairings, deletes stored coordinates on the server, and removes this phone’s registration.")
            .setPositiveButton("Unregister") { _, _ ->
                if (prefs.sharingEnabled) {
                    handleStopSharingClicked()
                }
                offlineStore.clearPending()
                ioExecutor.execute {
                    LocaShareApiClient.unregisterDevice(prefs.serverUrl, deviceId, deviceToken)
                    uiHandler.post {
                        prefs.clearRegistrationAndTelemetry()
                        ivPairingQr.setImageBitmap(null)
                        refreshUiState()
                        Toast.makeText(this, "Device unregistered and location data deleted.", Toast.LENGTH_LONG).show()
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showPermissionExplanationAndRequest() {
        AlertDialog.Builder(this)
            .setTitle("Location Permission Required")
            .setMessage(getString(R.string.permission_explanation))
            .setPositiveButton("Continue") { _, _ ->
                val permissions = mutableListOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                )
                requestPermissions(permissions.toTypedArray(), REQ_LOCATION_PERMISSIONS)
            }
            .setNegativeButton("Not Now") { _, _ ->
                pendingStartSharingAfterPermission = false
                refreshUiState()
            }
            .show()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_LOCATION_PERMISSIONS) {
            refreshUiState()
            if (hasLocationPermission() && pendingStartSharingAfterPermission) {
                pendingStartSharingAfterPermission = false
                startForegroundSharingService()
            } else {
                pendingStartSharingAfterPermission = false
            }
        }
    }

    private fun startForegroundSharingService() {
        val startIntent = Intent(this, LocationSharingService::class.java).apply {
            action = LocationSharingService.ACTION_START_SHARING
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(startIntent)
        } else {
            startService(startIntent)
        }
        prefs.sharingEnabled = true
        refreshUiState()
    }

    private fun syncStatusFromBackend() {
        val deviceId = prefs.deviceId ?: return
        val deviceToken = prefs.deviceToken ?: return

        ioExecutor.execute {
            val res = LocaShareApiClient.fetchDeviceStatus(prefs.serverUrl, deviceId, deviceToken)
            if (res.success && res.data != null) {
                prefs.hasActivePairing = res.data.hasActivePairing
                uiHandler.post { refreshUiState() }
            }
        }
    }

    private fun renderPairingQr(payload: String) {
        if (payload.isBlank()) return
        try {
            val bmp = PairingQrGenerator.createQrBitmap(payload, sizePx = 360)
            ivPairingQr.setImageBitmap(bmp)
        } catch (_: Exception) {
        }
    }

    private fun refreshUiState() {
        val registered = prefs.isRegistered
        val hasPerm = hasLocationPermission()
        val netConnected = isNetworkConnected()

        val state = TrackingStateResolver.resolve(
            isRegistered = registered,
            hasLocationPermission = hasPerm,
            isSharingEnabled = prefs.sharingEnabled,
            hasActivePairing = prefs.hasActivePairing,
            isNetworkOnline = netConnected,
            hasGpsFix = prefs.hasGpsFix,
            hasSharedPreviously = prefs.hasSharedPreviously
        )

        tvStateBadge.text = state.displayTitle
        tvStateDetail.text = state.detailDescription

        val acc = prefs.lastAccuracyMeters
        tvAccuracy.text = if (acc >= 0f) {
            String.format(Locale.US, "Location accuracy: ±%.0f meters", acc)
        } else {
            "Location accuracy: Not available yet"
        }

        val lastUpload = prefs.lastSuccessfulUploadEpochMs
        tvLastUpload.text = if (lastUpload > 0L) {
            val fmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
            val secAgo = maxOf(0L, (System.currentTimeMillis() - lastUpload) / 1000L)
            "Last successful upload: ${fmt.format(Date(lastUpload))} (${secAgo}s ago)"
        } else {
            "Last successful upload: Never"
        }

        tvNetworkStatus.text = "Network: ${describeNetwork()}"

        val pendingSample = offlineStore.peekPending()
        tvPendingOffline.text = if (pendingSample != null) {
            val fmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
            "Offline queue: 1 newest point saved (${fmt.format(Date(pendingSample.recordedAtEpochMs))}) — waiting for connection"
        } else {
            "Offline queue: Empty (latest-only mode)"
        }

        if (registered) {
            tvDeviceId.text = "Device ID: ${prefs.deviceId}"
            layoutPairingBox.visibility = View.VISIBLE
            val code = prefs.pairingCode ?: "----"
            tvPairingCode.text = code

            val remainingMs = prefs.pairingExpiresAtEpochMs - System.currentTimeMillis()
            if (remainingMs > 0L) {
                val totalSec = remainingMs / 1000L
                val mins = totalSec / 60L
                val secs = totalSec % 60L
                tvPairingExpiry.text = String.format(Locale.US, "Single-use code expires in %d:%02d", mins, secs)
            } else {
                tvPairingExpiry.text = "Pairing code expired — tap “New pairing code” to pair a laptop"
            }

            if (ivPairingQr.drawable == null && !prefs.pairingCode.isNullOrBlank()) {
                renderPairingQr(prefs.pairingQrPayload ?: prefs.pairingCode!!)
            }
        } else {
            tvDeviceId.text = "Device ID: Not registered"
            layoutPairingBox.visibility = View.GONE
        }

        btnRequestPermission.visibility = if (hasPerm) View.GONE else View.VISIBLE
        btnStartSharing.isEnabled = registered && !prefs.sharingEnabled
        btnStopSharing.isEnabled = registered && prefs.sharingEnabled

        btnRevokePairing.isEnabled = registered
        btnDeleteLocation.isEnabled = registered
        btnUnregisterDevice.isEnabled = registered
    }

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun isNetworkConnected(): Boolean {
        val net = connectivityManager.activeNetwork ?: return false
        val caps = connectivityManager.getNetworkCapabilities(net) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun describeNetwork(): String {
        val net = connectivityManager.activeNetwork ?: return "Offline"
        val caps = connectivityManager.getNetworkCapabilities(net) ?: return "Offline"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi (Online)"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile Data (Online)"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet (Online)"
            else -> "Online"
        }
    }

    companion object {
        private const val REQ_LOCATION_PERMISSIONS = 2001
    }
}
