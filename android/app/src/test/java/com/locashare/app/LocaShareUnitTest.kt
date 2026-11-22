package com.locashare.app

import com.locashare.app.model.LocationSample
import com.locashare.app.model.ServerUrlValidator
import com.locashare.app.model.TrackingState
import com.locashare.app.model.TrackingStateResolver
import com.locashare.app.storage.InMemoryKeyValueStore
import com.locashare.app.storage.OfflineLocationStore
import com.locashare.app.util.PairingQrGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocaShareUnitTest {

    @Test
    fun offlineStore_replacesOlderPointWithNewestAndIgnoresStaleOutOfOrderFix() {
        val store = OfflineLocationStore(InMemoryKeyValueStore())

        val olderPoint = LocationSample(
            latitude = 37.7700,
            longitude = -122.4100,
            accuracyMeters = 18f,
            recordedAtEpochMs = 1_700_000_000_000L,
            batteryPercent = 85,
            isCharging = false,
            networkType = "offline"
        )
        val newestPoint = LocationSample(
            latitude = 37.7850,
            longitude = -122.4000,
            accuracyMeters = 9f,
            recordedAtEpochMs = 1_700_000_060_000L,
            batteryPercent = 84,
            isCharging = false,
            networkType = "wifi"
        )
        val outOfOrderOlder = LocationSample(
            latitude = 37.7600,
            longitude = -122.4200,
            accuracyMeters = 25f,
            recordedAtEpochMs = 1_700_000_030_000L
        )

        assertTrue(store.saveOrReplaceNewest(olderPoint))
        assertEquals(37.7700, store.peekPending()?.latitude ?: 0.0, 0.0001)

        // Newer point replaces the pending point (no multi-point flood backlog)
        assertTrue(store.saveOrReplaceNewest(newestPoint))
        assertEquals(37.7850, store.peekPending()?.latitude ?: 0.0, 0.0001)

        // Out-of-order older point is rejected
        assertFalse(store.saveOrReplaceNewest(outOfOrderOlder))
        assertEquals(37.7850, store.peekPending()?.latitude ?: 0.0, 0.0001)

        store.clearPending()
        assertNull(store.peekPending())
    }

    @Test
    fun locationSample_validatesCoordinateAndAccuracyRanges() {
        val store = OfflineLocationStore(InMemoryKeyValueStore())

        val invalidLat = LocationSample(95.0, -122.0, 10f, 1_700_000_000_000L)
        val invalidLng = LocationSample(37.0, -190.0, 10f, 1_700_000_000_000L)
        val invalidAcc = LocationSample(37.0, -122.0, -3f, 1_700_000_000_000L)

        assertFalse(invalidLat.isValid())
        assertFalse(invalidLng.isValid())
        assertFalse(invalidAcc.isValid())
        assertFalse(store.saveOrReplaceNewest(invalidLat))
    }

    @Test
    fun trackingStateResolver_reportsHonestStates() {
        assertEquals(
            TrackingState.UNREGISTERED,
            TrackingStateResolver.resolve(
                isRegistered = false,
                hasLocationPermission = true,
                isSharingEnabled = false,
                hasActivePairing = false,
                isNetworkOnline = true,
                hasGpsFix = false
            )
        )

        assertEquals(
            TrackingState.PERMISSION_MISSING,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = false,
                isSharingEnabled = true,
                hasActivePairing = true,
                isNetworkOnline = true,
                hasGpsFix = true
            )
        )

        assertEquals(
            TrackingState.WAITING_FOR_PAIRING,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = true,
                isSharingEnabled = false,
                hasActivePairing = false,
                isNetworkOnline = true,
                hasGpsFix = false
            )
        )

        assertEquals(
            TrackingState.NO_GPS_FIX,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = true,
                isSharingEnabled = true,
                hasActivePairing = true,
                isNetworkOnline = true,
                hasGpsFix = false
            )
        )

        assertEquals(
            TrackingState.OFFLINE,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = true,
                isSharingEnabled = true,
                hasActivePairing = true,
                isNetworkOnline = false,
                hasGpsFix = true
            )
        )

        assertEquals(
            TrackingState.SHARING,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = true,
                isSharingEnabled = true,
                hasActivePairing = true,
                isNetworkOnline = true,
                hasGpsFix = true
            )
        )

        assertEquals(
            TrackingState.PAUSED,
            TrackingStateResolver.resolve(
                isRegistered = true,
                hasLocationPermission = true,
                isSharingEnabled = false,
                hasActivePairing = true,
                isNetworkOnline = true,
                hasGpsFix = true,
                hasSharedPreviously = true
            )
        )
    }

    @Test
    fun serverUrlValidator_enforcesHttpsForRemoteHosts() {
        val remoteHttps = ServerUrlValidator.validate("https://locashare.example.com/")
        assertTrue(remoteHttps.isValid)
        assertEquals("https://locashare.example.com", remoteHttps.normalizedUrl)
        assertTrue(remoteHttps.isRemoteHttps)

        val remoteCleartext = ServerUrlValidator.validate("http://locashare.example.com")
        assertFalse(remoteCleartext.isValid)

        val localEmulator = ServerUrlValidator.validate("http://10.0.2.2:8080/")
        assertTrue(localEmulator.isValid)
        assertEquals("http://10.0.2.2:8080", localEmulator.normalizedUrl)
    }

    @Test
    fun pairingQrGenerator_encodesPairingUriMatrix() {
        val matrix = PairingQrGenerator.encodeMatrix("locashare://pair?code=ABCD-2345")
        assertNotNull(matrix)
        assertEquals(25, matrix.size)
        // Top-left finder corner must be dark
        assertTrue(matrix[0][0])
        assertTrue(matrix[6][6])
    }

    companion object {
        @JvmStatic
        fun main(args: Array<String>) {
            val suite = LocaShareUnitTest()
            suite.offlineStore_replacesOlderPointWithNewestAndIgnoresStaleOutOfOrderFix()
            println("  [PASS] offlineStore_replacesOlderPointWithNewestAndIgnoresStaleOutOfOrderFix")
            suite.locationSample_validatesCoordinateAndAccuracyRanges()
            println("  [PASS] locationSample_validatesCoordinateAndAccuracyRanges")
            suite.trackingStateResolver_reportsHonestStates()
            println("  [PASS] trackingStateResolver_reportsHonestStates")
            suite.serverUrlValidator_enforcesHttpsForRemoteHosts()
            println("  [PASS] serverUrlValidator_enforcesHttpsForRemoteHosts")
            suite.pairingQrGenerator_encodesPairingUriMatrix()
            println("  [PASS] pairingQrGenerator_encodesPairingUriMatrix")
            println("All Android JVM unit tests passed!")
        }
    }
}
