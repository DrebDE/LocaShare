package com.locashare.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Invoked when the user taps "Stop sharing" on the persistent foreground notification.
 */
class StopSharingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val stopIntent = Intent(context, LocationSharingService::class.java).apply {
            action = LocationSharingService.ACTION_STOP_SHARING
        }
        try {
            context.startService(stopIntent)
        } catch (_: Exception) {
            DeviceStore.setSharingState(context, isSharing = false, statusState = "paused")
            LocationSharingService.notifyStateChanged(context)
        }
    }
}
