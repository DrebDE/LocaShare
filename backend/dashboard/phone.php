<?php
/**
 * LocaShare - Mobile Phone Companion App (Installable Web App / PWA)
 *
 * Allows a phone owner to register their phone, display the one-time pairing code & QR code,
 * grant location permission, start/stop location sharing, revoke pairing, delete stored location,
 * and unregister their device directly from their mobile browser or home-screen web app,
 * using the exact same backend APIs as the native Android app.
 */

if (!headers_sent()) {
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: no-referrer');
    header('Cache-Control: no-store, no-cache, must-revalidate');
}

$requestPath = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$inDashboardSubdir = (bool) preg_match('#/dashboard(/phone\.php)?/?$#i', $requestPath);
$apiPrefix = $inDashboardSubdir ? '../api' : 'api';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="theme-color" content="#0f172a">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <title>LocaShare — Phone Tracker App</title>
    <style>
        :root {
            --bg-primary: #0f172a;
            --bg-card: #1e293b;
            --bg-input: #0b1325;
            --border-color: #334155;
            --text-primary: #f8fafc;
            --text-secondary: #cbd5e1;
            --text-muted: #94a3b8;
            --accent-blue: #0ea5e9;
            --accent-green: #10b981;
            --accent-amber: #f59e0b;
            --accent-red: #ef4444;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            padding: 16px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            max-width: 520px;
            margin-left: auto;
            margin-right: auto;
        }
        h1 { margin: 0; font-size: 1.45rem; }
        .subtitle { margin: 4px 0 14px; font-size: 0.82rem; color: var(--text-secondary); line-height: 1.4; }
        .card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 16px;
            margin-bottom: 14px;
        }
        .card h2 { margin: 0 0 8px; font-size: 0.98rem; }
        .label-xs { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); font-weight: 700; }
        .state-title { font-size: 1.2rem; font-weight: 700; color: var(--accent-blue); margin: 4px 0; }
        .meta-line { font-size: 0.82rem; color: var(--text-secondary); margin: 4px 0; }
        input[type="text"] {
            width: 100%;
            padding: 11px 12px;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background: var(--bg-input);
            color: var(--text-primary);
            font-size: 0.92rem;
            margin-top: 6px;
        }
        .btn {
            display: block;
            width: 100%;
            padding: 12px;
            border-radius: 8px;
            border: 1px solid transparent;
            font-size: 0.92rem;
            font-weight: 700;
            cursor: pointer;
            margin-top: 10px;
            text-align: center;
        }
        .btn:disabled { opacity: 0.45; cursor: not-allowed; }
        .btn-primary { background: var(--accent-blue); color: #fff; }
        .btn-success { background: var(--accent-green); color: #052e16; }
        .btn-secondary { background: var(--bg-input); border-color: var(--border-color); color: var(--text-primary); }
        .btn-danger { background: rgba(239, 68, 68, 0.16); border-color: rgba(239, 68, 68, 0.5); color: #fca5a5; }
        .pairing-box {
            margin-top: 12px;
            padding: 14px;
            background: var(--bg-input);
            border-radius: 10px;
            text-align: center;
            border: 1px solid var(--border-color);
        }
        .pairing-code {
            font-family: ui-monospace, monospace;
            font-size: 1.85rem;
            font-weight: 800;
            letter-spacing: 0.12em;
            color: var(--accent-green);
            margin: 6px 0;
        }
        .hidden { display: none !important; }
        .active-banner {
            background: rgba(16, 185, 129, 0.16);
            border: 1px solid var(--accent-green);
            color: #a7f3d0;
            padding: 10px 12px;
            border-radius: 10px;
            margin-bottom: 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
            font-size: 0.84rem;
        }
    </style>
</head>
<body>
    <h1>LocaShare Phone</h1>
    <p class="subtitle">Owner-controlled phone location sharing. No account or login required. Installable to your phone’s Home Screen via browser menu → “Add to Home Screen”.</p>

    <!-- Persistent Active Sharing Banner -->
    <div id="active-sharing-banner" class="active-banner hidden" role="status">
        <span><strong>Sharing Active:</strong> Sending live coordinates to your paired laptop dashboard.</span>
        <button type="button" id="btn-banner-stop" class="btn btn-danger" style="width:auto;margin:0;padding:6px 12px;">Stop</button>
    </div>

    <!-- Current State Card -->
    <div class="card">
        <div class="label-xs">Current Tracking State</div>
        <div id="tv-state-badge" class="state-title">Not registered</div>
        <div id="tv-state-detail" class="meta-line">Tap “Register this device” below to generate a one-time pairing code.</div>
        <div id="tv-accuracy" class="meta-line" style="margin-top:10px;">Location accuracy: —</div>
        <div id="tv-last-upload" class="meta-line">Last successful upload: Never</div>
        <div id="tv-network" class="meta-line">Network: Online</div>
        <div id="tv-offline-queue" class="meta-line">Offline queue: Empty (latest-only mode)</div>
    </div>

    <!-- Registration & Pairing Card -->
    <div class="card">
        <h2>1. Register &amp; Pair with Laptop Dashboard</h2>
        <label class="label-xs" for="et-device-name">Phone Label</label>
        <input type="text" id="et-device-name" value="My Android Phone" maxlength="64">
        <button type="button" id="btn-register" class="btn btn-primary">Register this device</button>
        <div id="tv-device-id" class="meta-line" style="margin-top:8px;">Device ID: Not registered</div>

        <div id="pairing-box" class="pairing-box hidden">
            <div class="label-xs">One-Time Pairing Code</div>
            <div id="tv-pairing-code" class="pairing-code">----</div>
            <div id="tv-pairing-expiry" class="meta-line">Single-use code expires in 5:00</div>
            <button type="button" id="btn-new-code" class="btn btn-secondary">New pairing code</button>
        </div>
    </div>

    <!-- Location Permission & Sharing Controls -->
    <div class="card">
        <h2>2. Location Permission &amp; Sharing Controls</h2>
        <p class="meta-line">LocaShare asks for location permission only when you choose to share, and starts sending coordinates only after you tap “Start sharing”.</p>
        <button type="button" id="btn-start-sharing" class="btn btn-success" disabled>Start sharing</button>
        <button type="button" id="btn-stop-sharing" class="btn btn-secondary" disabled>Stop sharing</button>
    </div>

    <!-- Privacy, Revocation & Deletion -->
    <div class="card">
        <h2>3. Privacy, Revocation &amp; Data Deletion</h2>
        <button type="button" id="btn-revoke" class="btn btn-secondary" disabled>Revoke dashboard pairing</button>
        <button type="button" id="btn-delete-loc" class="btn btn-secondary" disabled>Delete stored location</button>
        <button type="button" id="btn-unregister" class="btn btn-danger" disabled>Unregister this device</button>
    </div>

    <script>
    (function () {
        var API_BASE = <?= json_encode($apiPrefix) ?>;
        var STORAGE_KEY = 'locashare_phone_state_v2';

        var state = loadState();
        var watchId = null;
        var heartbeatTimer = null;

        function loadState() {
            try {
                var raw = localStorage.getItem(STORAGE_KEY);
                if (raw) return JSON.parse(raw);
            } catch (e) {}
            return {
                deviceId: null,
                deviceToken: null,
                deviceName: 'My Android Phone',
                pairingCode: null,
                pairingExpiresAtMs: 0,
                sharingEnabled: false,
                lastAccuracy: null,
                lastUploadMs: 0,
                pendingSample: null,
                permissionMissing: false,
                hasGpsFix: false
            };
        }

        function saveState() {
            try {
                localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
            } catch (e) {}
        }

        function apiCall(path, method, body) {
            var headers = { 'Accept': 'application/json', 'Content-Type': 'application/json' };
            if (state.deviceToken) {
                headers['Authorization'] = 'Bearer ' + state.deviceToken;
            }
            return fetch(API_BASE + path, {
                method: method || 'POST',
                headers: headers,
                body: body ? JSON.stringify(body) : null
            }).then(function (r) { return r.json(); });
        }

        function updateUi() {
            var registered = Boolean(state.deviceId && state.deviceToken);
            var online = navigator.onLine !== false;

            var badge = 'Not registered';
            var detail = 'Tap “Register this device” below to generate a one-time pairing code.';
            if (registered) {
                if (state.permissionMissing) {
                    badge = 'Location permission missing';
                    detail = 'Allow location access in your browser permissions and tap Start sharing.';
                } else if (!online) {
                    badge = 'Offline (newest point saved)';
                    detail = 'No network connection. The newest fix is saved and will upload automatically when online.';
                } else if (state.sharingEnabled) {
                    badge = state.hasGpsFix ? 'Sharing location' : 'No GPS fix yet';
                    detail = state.hasGpsFix
                        ? 'Actively sharing your latest coordinates with your paired laptop dashboard.'
                        : 'Sharing is enabled — waiting for GPS/location provider fix…';
                } else {
                    badge = state.pairingCode ? 'Waiting for pairing / Ready' : 'Sharing paused';
                    detail = 'Enter the one-time pairing code on your laptop dashboard, then tap Start sharing.';
                }
            }

            document.getElementById('tv-state-badge').textContent = badge;
            document.getElementById('tv-state-detail').textContent = detail;
            document.getElementById('tv-accuracy').textContent = state.lastAccuracy != null
                ? 'Location accuracy: ±' + Math.round(state.lastAccuracy) + ' meters'
                : 'Location accuracy: Not available yet';
            document.getElementById('tv-last-upload').textContent = state.lastUploadMs > 0
                ? 'Last successful upload: ' + new Date(state.lastUploadMs).toLocaleTimeString()
                : 'Last successful upload: Never';
            document.getElementById('tv-network').textContent = 'Network: ' + (online ? 'Online' : 'Offline');
            document.getElementById('tv-offline-queue').textContent = state.pendingSample
                ? 'Offline queue: 1 newest point saved — waiting for reconnection'
                : 'Offline queue: Empty (latest-only mode)';

            document.getElementById('tv-device-id').textContent = registered
                ? 'Device ID: ' + state.deviceId
                : 'Device ID: Not registered';

            var pairingBox = document.getElementById('pairing-box');
            if (registered && state.pairingCode) {
                pairingBox.classList.remove('hidden');
                document.getElementById('tv-pairing-code').textContent = state.pairingCode;
                var remSec = Math.max(0, Math.floor((state.pairingExpiresAtMs - Date.now()) / 1000));
                document.getElementById('tv-pairing-expiry').textContent = remSec > 0
                    ? 'Single-use code expires in ' + Math.floor(remSec / 60) + ':' + ('0' + (remSec % 60)).slice(-2)
                    : 'Pairing code expired — tap “New pairing code”';
            } else {
                pairingBox.classList.add('hidden');
            }

            var banner = document.getElementById('active-sharing-banner');
            if (registered && state.sharingEnabled) {
                banner.classList.remove('hidden');
            } else {
                banner.classList.add('hidden');
            }

            document.getElementById('btn-start-sharing').disabled = !registered || state.sharingEnabled;
            document.getElementById('btn-stop-sharing').disabled = !registered || !state.sharingEnabled;
            document.getElementById('btn-revoke').disabled = !registered;
            document.getElementById('btn-delete-loc').disabled = !registered;
            document.getElementById('btn-unregister').disabled = !registered;
        }

        function sendSampleOrQueue(sample) {
            if (!state.deviceId || !state.deviceToken) return;
            if (navigator.onLine === false) {
                if (!state.pendingSample || sample.recordedAtMs >= state.pendingSample.recordedAtMs) {
                    state.pendingSample = sample;
                    saveState();
                }
                updateUi();
                return;
            }

            apiCall('/location/update.php', 'POST', {
                device_id: state.deviceId,
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracy: sample.accuracy,
                timestamp: new Date(sample.recordedAtMs).toISOString(),
                network_type: 'wifi_or_mobile'
            }).then(function (res) {
                if (res && res.success) {
                    state.lastUploadMs = Date.now();
                    state.pendingSample = null;
                    saveState();
                } else {
                    if (!state.pendingSample || sample.recordedAtMs >= state.pendingSample.recordedAtMs) {
                        state.pendingSample = sample;
                        saveState();
                    }
                }
                updateUi();
            }).catch(function () {
                if (!state.pendingSample || sample.recordedAtMs >= state.pendingSample.recordedAtMs) {
                    state.pendingSample = sample;
                    saveState();
                }
                updateUi();
            });
        }

        function startSharing() {
            if (!navigator.geolocation) {
                alert('Geolocation API is not supported by this browser.');
                return;
            }
            state.sharingEnabled = true;
            state.permissionMissing = false;
            saveState();
            updateUi();

            watchId = navigator.geolocation.watchPosition(
                function (pos) {
                    state.permissionMissing = false;
                    state.hasGpsFix = true;
                    state.lastAccuracy = pos.coords.accuracy;
                    saveState();
                    sendSampleOrQueue({
                        latitude: pos.coords.latitude,
                        longitude: pos.coords.longitude,
                        accuracy: pos.coords.accuracy,
                        recordedAtMs: pos.timestamp || Date.now()
                    });
                },
                function (err) {
                    if (err && err.code === 1) {
                        state.permissionMissing = true;
                        state.sharingEnabled = false;
                        saveState();
                        apiCall('/device/heartbeat.php', 'POST', {
                            device_id: state.deviceId,
                            sharing_enabled: false,
                            status_state: 'permission_missing'
                        });
                    }
                    updateUi();
                },
                { enableHighAccuracy: true, maximumAge: 15000, timeout: 20000 }
            );

            if (heartbeatTimer) clearInterval(heartbeatTimer);
            heartbeatTimer = setInterval(function () {
                if (!state.sharingEnabled || !state.deviceId) return;
                if (state.pendingSample && navigator.onLine !== false) {
                    sendSampleOrQueue(state.pendingSample);
                    return;
                }
                apiCall('/device/heartbeat.php', 'POST', {
                    device_id: state.deviceId,
                    sharing_enabled: true,
                    status_state: state.hasGpsFix ? 'sharing' : 'no_gps_fix'
                });
            }, 25000);
        }

        function stopSharing() {
            state.sharingEnabled = false;
            if (watchId !== null && navigator.geolocation) {
                navigator.geolocation.clearWatch(watchId);
                watchId = null;
            }
            if (heartbeatTimer) {
                clearInterval(heartbeatTimer);
                heartbeatTimer = null;
            }
            saveState();
            updateUi();
            if (state.deviceId && state.deviceToken) {
                apiCall('/device/heartbeat.php', 'POST', {
                    device_id: state.deviceId,
                    sharing_enabled: false,
                    status_state: 'paused'
                });
            }
        }

        document.getElementById('btn-register').addEventListener('click', function () {
            var name = document.getElementById('et-device-name').value.trim() || 'My Android Phone';
            apiCall('/device/register.php', 'POST', { device_name: name }).then(function (res) {
                if (res && res.success) {
                    state.deviceId = res.device_id;
                    state.deviceToken = res.device_token;
                    state.deviceName = res.device_name;
                    state.pairingCode = res.pairing_code;
                    state.pairingExpiresAtMs = Date.now() + ((res.pairing_ttl_seconds || 300) * 1000);
                    state.sharingEnabled = false;
                    saveState();
                    updateUi();
                } else {
                    alert((res && res.error) || 'Failed to register device.');
                }
            });
        });

        document.getElementById('btn-new-code').addEventListener('click', function () {
            apiCall('/device/pairing-code.php', 'POST', { device_id: state.deviceId }).then(function (res) {
                if (res && res.success) {
                    state.pairingCode = res.pairing_code;
                    state.pairingExpiresAtMs = Date.now() + ((res.pairing_ttl_seconds || 300) * 1000);
                    saveState();
                    updateUi();
                }
            });
        });

        document.getElementById('btn-start-sharing').addEventListener('click', startSharing);
        document.getElementById('btn-stop-sharing').addEventListener('click', stopSharing);
        document.getElementById('btn-banner-stop').addEventListener('click', stopSharing);

        document.getElementById('btn-revoke').addEventListener('click', function () {
            stopSharing();
            apiCall('/device/unpair.php', 'POST', { device_id: state.deviceId, clear_location: true }).then(function () {
                state.lastAccuracy = null;
                state.hasGpsFix = false;
                saveState();
                updateUi();
                alert('Dashboard pairing revoked and stored location cleared.');
            });
        });

        document.getElementById('btn-delete-loc').addEventListener('click', function () {
            state.pendingSample = null;
            apiCall('/location/delete.php', 'POST', { device_id: state.deviceId }).then(function () {
                state.lastAccuracy = null;
                state.hasGpsFix = false;
                saveState();
                updateUi();
                alert('Stored location deleted from server.');
            });
        });

        document.getElementById('btn-unregister').addEventListener('click', function () {
            stopSharing();
            apiCall('/device/unregister.php', 'POST', { device_id: state.deviceId }).finally(function () {
                localStorage.removeItem(STORAGE_KEY);
                state = loadState();
                updateUi();
                alert('Device unregistered and stored location deleted.');
            });
        });

        window.addEventListener('online', function () {
            if (state.pendingSample && state.sharingEnabled) {
                sendSampleOrQueue(state.pendingSample);
            }
            updateUi();
        });
        window.addEventListener('offline', updateUi);

        setInterval(updateUi, 1000);
        updateUi();
    })();
    </script>
</body>
</html>
