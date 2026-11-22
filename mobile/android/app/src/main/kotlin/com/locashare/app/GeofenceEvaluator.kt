package com.locashare.app

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure, deterministic geofence & Smart Home privacy evaluator.
 *
 * Uses Haversine distance + hysteresis + 2-fix exit streak confirmation so
 * indoor GPS jitter never spams false "left Home" alerts or leaks indoor drift.
 */
object GeofenceEvaluator {

    data class SavedPlace(
        val placeId: String,
        val name: String,
        val category: String,
        val latitude: Double,
        val longitude: Double,
        val radiusMeters: Int,
        val isHome: Boolean,
        val notifyOnEnter: Boolean,
        val notifyOnExit: Boolean
    )

    data class PlaceTrackState(
        val isInside: Boolean = false,
        val outsideStreak: Int = 0,
        val insideStreak: Int = 0
    )

    data class PlaceTransition(
        val place: SavedPlace,
        val eventType: String // "entered" or "exited"
    )

    data class EvaluationResult(
        val presenceMode: String, // "at_home", "at_place", "away", "unknown"
        val currentPlaceId: String?,
        val currentPlaceName: String?,
        val homePrivacyMasked: Boolean,
        val uploadLatitude: Double,
        val uploadLongitude: Double,
        val transitions: List<PlaceTransition>,
        val updatedStates: Map<String, PlaceTrackState>,
        val shouldProbeGps: Boolean
    )

    fun haversineMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val earthRadiusM = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLng = Math.toRadians(lng2 - lng1)
        val a = sin(dLat / 2.0) * sin(dLat / 2.0) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
            sin(dLng / 2.0) * sin(dLng / 2.0)
        val c = 2.0 * atan2(sqrt(a), sqrt(max(0.0, 1.0 - a)))
        return earthRadiusM * c
    }

    fun parsePlacesJson(rawJson: String?): List<SavedPlace> {
        if (rawJson.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(rawJson)
            val list = ArrayList<SavedPlace>(arr.length())
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val id = obj.optString("place_id", "").trim()
                val name = obj.optString("name", "").trim()
                if (id.isEmpty() || name.isEmpty()) continue
                list.add(
                    SavedPlace(
                        placeId = id,
                        name = name,
                        category = obj.optString("category", "custom").ifBlank { "custom" },
                        latitude = obj.optDouble("latitude", 0.0),
                        longitude = obj.optDouble("longitude", 0.0),
                        radiusMeters = obj.optInt("radius_meters", 150).coerceIn(50, 5000),
                        isHome = obj.optBoolean("is_home", false),
                        notifyOnEnter = obj.optBoolean("notify_on_enter", true),
                        notifyOnExit = obj.optBoolean("notify_on_exit", true)
                    )
                )
            }
            list
        }.getOrDefault(emptyList())
    }

    fun parseStatesJson(rawJson: String?): Map<String, PlaceTrackState> {
        if (rawJson.isNullOrBlank()) return emptyMap()
        return runCatching {
            val obj = JSONObject(rawJson)
            val map = LinkedHashMap<String, PlaceTrackState>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val item = obj.optJSONObject(k) ?: continue
                map[k] = PlaceTrackState(
                    isInside = item.optBoolean("isInside", false),
                    outsideStreak = item.optInt("outsideStreak", 0),
                    insideStreak = item.optInt("insideStreak", 0)
                )
            }
            map
        }.getOrDefault(emptyMap())
    }

    fun encodeStatesJson(states: Map<String, PlaceTrackState>): String {
        val obj = JSONObject()
        for ((k, st) in states) {
            obj.put(
                k,
                JSONObject().apply {
                    put("isInside", st.isInside)
                    put("outsideStreak", st.outsideStreak)
                    put("insideStreak", st.insideStreak)
                }
            )
        }
        return obj.toString()
    }

    fun evaluate(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Float?,
        places: List<SavedPlace>,
        previousStates: Map<String, PlaceTrackState>,
        smartHomeMode: Boolean
    ): EvaluationResult {
        if (places.isEmpty()) {
            return EvaluationResult(
                presenceMode = "away",
                currentPlaceId = null,
                currentPlaceName = null,
                homePrivacyMasked = false,
                uploadLatitude = latitude,
                uploadLongitude = longitude,
                transitions = emptyList(),
                updatedStates = emptyMap(),
                shouldProbeGps = false
            )
        }

        val acc = accuracyMeters?.toDouble()?.coerceIn(5.0, 200.0) ?: 20.0
        val exitBuffer = max(25.0, min(60.0, acc * 0.5))
        val updatedStates = LinkedHashMap<String, PlaceTrackState>()
        val transitions = ArrayList<PlaceTransition>()
        var shouldProbeGps = false

        var activeHome: SavedPlace? = null
        var activeOtherPlace: SavedPlace? = null

        for (place in places) {
            val prev = previousStates[place.placeId]
            val dist = haversineMeters(latitude, longitude, place.latitude, place.longitude)
            val radius = place.radiusMeters.toDouble()

            val nextState: PlaceTrackState = if (prev == null) {
                // First observation: seed state honestly without emitting bogus initial transitions
                val initiallyInside = dist <= radius
                PlaceTrackState(
                    isInside = initiallyInside,
                    outsideStreak = 0,
                    insideStreak = if (initiallyInside) 1 else 0
                )
            } else if (prev.isInside) {
                if (dist <= radius) {
                    if (place.isHome && dist > radius * 0.85) {
                        shouldProbeGps = true
                    }
                    PlaceTrackState(isInside = true, outsideStreak = 0, insideStreak = prev.insideStreak + 1)
                } else if (dist > radius + exitBuffer || prev.outsideStreak + 1 >= 2) {
                    transitions.add(PlaceTransition(place, "exited"))
                    PlaceTrackState(isInside = false, outsideStreak = 0, insideStreak = 0)
                } else {
                    if (place.isHome) {
                        shouldProbeGps = true
                    }
                    PlaceTrackState(isInside = true, outsideStreak = prev.outsideStreak + 1, insideStreak = 0)
                }
            } else {
                // Currently outside
                if (dist <= radius) {
                    val quickEntry = dist <= radius * 0.85 || acc <= radius * 0.5
                    if (quickEntry || prev.insideStreak + 1 >= 2) {
                        transitions.add(PlaceTransition(place, "entered"))
                        PlaceTrackState(isInside = true, outsideStreak = 0, insideStreak = 1)
                    } else {
                        PlaceTrackState(isInside = false, outsideStreak = 0, insideStreak = prev.insideStreak + 1)
                    }
                } else {
                    PlaceTrackState(isInside = false, outsideStreak = 0, insideStreak = 0)
                }
            }

            updatedStates[place.placeId] = nextState
            if (nextState.isInside) {
                if (place.isHome) {
                    activeHome = place
                } else if (activeOtherPlace == null) {
                    activeOtherPlace = place
                }
            }
        }

        return if (activeHome != null) {
            val mask = smartHomeMode
            EvaluationResult(
                presenceMode = "at_home",
                currentPlaceId = activeHome.placeId,
                currentPlaceName = activeHome.name,
                homePrivacyMasked = mask,
                uploadLatitude = if (mask) activeHome.latitude else latitude,
                uploadLongitude = if (mask) activeHome.longitude else longitude,
                transitions = transitions,
                updatedStates = updatedStates,
                shouldProbeGps = shouldProbeGps
            )
        } else if (activeOtherPlace != null) {
            EvaluationResult(
                presenceMode = "at_place",
                currentPlaceId = activeOtherPlace.placeId,
                currentPlaceName = activeOtherPlace.name,
                homePrivacyMasked = false,
                uploadLatitude = latitude,
                uploadLongitude = longitude,
                transitions = transitions,
                updatedStates = updatedStates,
                shouldProbeGps = shouldProbeGps
            )
        } else {
            EvaluationResult(
                presenceMode = "away",
                currentPlaceId = null,
                currentPlaceName = null,
                homePrivacyMasked = false,
                uploadLatitude = latitude,
                uploadLongitude = longitude,
                transitions = transitions,
                updatedStates = updatedStates,
                shouldProbeGps = shouldProbeGps
            )
        }
    }
}
