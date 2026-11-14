/**
 * LocaShare Laptop Dashboard Application
 *
 * Manages paired devices, polling, pairing via one-time code or QR code,
 * revocation notices, server outage states, and map synchronization.
 */
(function () {
    'use strict';

    var state = {
        csrfToken: '',
        pollIntervalMs: 10000,
        apiBase: '../api',
        thresholds: { online_threshold_seconds: 90, location_stale_seconds: 180 },
        devices: [],
        revokedPairings: [],
        selectedDeviceId: null,
        serverOutage: false,
        hasCenteredInitially: false,
        pollTimer: null,
        qrStream: null,
        qrScanActive: false
    };

    // DOM Elements
    var els = {
        serverPill: document.getElementById('server-status-pill'),
        serverText: document.getElementById('server-status-text'),
        outageBanner: document.getElementById('outage-banner'),
        outageMessage: document.getElementById('outage-message'),
        btnRetryOutage: document.getElementById('btn-retry-outage'),
        revokedContainer: document.getElementById('revoked-container'),
        pairedCountBadge: document.getElementById('paired-count-badge'),
        emptyDevicesState: document.getElementById('empty-devices-state'),
        deviceList: document.getElementById('device-list'),
        detailPanel: document.getElementById('device-detail-panel'),
        detailName: document.getElementById('detail-device-name'),
        detailId: document.getElementById('detail-device-id'),
        detailAlertBox: document.getElementById('detail-alert-box'),
        detailConnection: document.getElementById('detail-connection'),
        detailSharingState: document.getElementById('detail-sharing-state'),
        detailFixFreshness: document.getElementById('detail-fix-freshness'),
        detailFixTime: document.getElementById('detail-fix-time'),
        detailHeartbeatTime: document.getElementById('detail-heartbeat-time'),
        detailCoordinates: document.getElementById('detail-coordinates'),
        detailAccuracy: document.getElementById('detail-accuracy'),
        detailTelemetry: document.getElementById('detail-telemetry'),
        btnCenterSelected: document.getElementById('btn-center-selected'),
        btnDeleteLocation: document.getElementById('btn-delete-location'),
        btnUnpairDevice: document.getElementById('btn-unpair-device'),
        btnRefreshNow: document.getElementById('btn-refresh-now'),
        btnOpenPairModal: document.getElementById('btn-open-pair-modal'),
        btnEmptyPair: document.getElementById('btn-empty-pair'),
        pairModalBackdrop: document.getElementById('pair-modal-backdrop'),
        btnClosePairModal: document.getElementById('btn-close-pair-modal'),
        pairForm: document.getElementById('pair-form'),
        pairingCodeInput: document.getElementById('pairing-code-input'),
        btnSubmitPair: document.getElementById('btn-submit-pair'),
        pairErrorBox: document.getElementById('pair-error-box'),
        pairSuccessBox: document.getElementById('pair-success-box'),
        btnStartQrCamera: document.getElementById('btn-start-qr-camera'),
        btnStopQrCamera: document.getElementById('btn-stop-qr-camera'),
        qrFileInput: document.getElementById('qr-file-input'),
        qrVideoWrap: document.getElementById('qr-video-wrap'),
        qrVideo: document.getElementById('qr-video'),
        qrScanStatus: document.getElementById('qr-scan-status'),
        mapViewport: document.getElementById('map-viewport'),
        mapCanvas: document.getElementById('map-canvas'),
        mapMarkersLayer: document.getElementById('map-markers-layer'),
        mapOverlayMessage: document.getElementById('map-overlay-message'),
        btnZoomIn: document.getElementById('btn-zoom-in'),
        btnZoomOut: document.getElementById('btn-zoom-out'),
        btnFitAll: document.getElementById('btn-fit-all'),
        btnCenterActive: document.getElementById('btn-center-active'),
        chkOsmTiles: document.getElementById('chk-osm-tiles'),
        tileModeBadge: document.getElementById('tile-mode-badge')
    };

    var map = new window.LocaShareMap({
        viewport: els.mapViewport,
        canvas: els.mapCanvas,
        markersLayer: els.mapMarkersLayer,
        onSelectDevice: function (deviceId, shouldCenter) {
            selectDevice(deviceId, shouldCenter);
        }
    });

    function formatRelativeSeconds(seconds) {
        if (typeof seconds !== 'number' || isNaN(seconds) || seconds < 0) {
            return 'never';
        }
        if (seconds < 5) return 'just now';
        if (seconds < 60) return Math.round(seconds) + 's ago';
        var mins = Math.floor(seconds / 60);
        if (mins < 60) return mins + 'm ' + (seconds % 60) + 's ago';
        var hours = Math.floor(mins / 60);
        if (hours < 24) return hours + 'h ' + (mins % 60) + 'm ago';
        var days = Math.floor(hours / 24);
        return days + 'd ago';
    }

    function formatTimestampWithAge(isoString, ageSeconds) {
        if (!isoString) {
            return 'Never';
        }
        var dt = new Date(isoString);
        var timeStr = isNaN(dt.getTime()) ? isoString : dt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        return timeStr + ' (' + formatRelativeSeconds(ageSeconds) + ')';
    }

    function humanizeState(stateCode, sharingEnabled) {
        switch (stateCode) {
            case 'sharing': return 'Sharing Active';
            case 'paused': return 'Paused by Owner';
            case 'waiting_for_pairing': return 'Waiting for Pairing';
            case 'registered': return sharingEnabled ? 'Sharing Active' : 'Registered (Not Sharing)';
            case 'no_gps_fix': return 'Sharing (Waiting for GPS Fix)';
            case 'offline': return 'Phone Offline';
            case 'permission_missing': return 'Location Permission Missing';
            default: return stateCode || 'Registered';
        }
    }

    function extractPairingCode(rawText) {
        if (!rawText) return '';
        var str = String(rawText).trim();
        var match = str.match(/[?&]code=([A-Za-z0-9\-]+)/i);
        if (match && match[1]) {
            str = decodeURIComponent(match[1]);
        }
        var clean = str.replace(/[^A-Za-z0-9]/g, '').toUpperCase();
        if (clean.length >= 8) {
            var half = Math.floor(clean.length / 2);
            return clean.slice(0, half) + '-' + clean.slice(half);
        }
        return clean;
    }

    function apiRequest(path, options) {
        options = options || {};
        var method = options.method || 'GET';
        var headers = {
            'Accept': 'application/json'
        };
        if (state.csrfToken) {
            headers['X-CSRF-Token'] = state.csrfToken;
        }
        var fetchOpts = {
            method: method,
            credentials: 'same-origin',
            headers: headers
        };
        if (options.body) {
            headers['Content-Type'] = 'application/json';
            fetchOpts.body = JSON.stringify(options.body);
        }

        return fetch(state.apiBase + path, fetchOpts).then(function (res) {
            return res.json().catch(function () {
                return { success: false, error: 'Invalid response from server.' };
            }).then(function (data) {
                return { status: res.status, ok: res.ok && data.success !== false, data: data };
            });
        });
    }

    function setServerOutage(isOutage, customMessage) {
        state.serverOutage = Boolean(isOutage);
        if (state.serverOutage) {
            els.serverPill.classList.remove('server-ok');
            els.serverPill.classList.add('server-error');
            els.serverText.textContent = 'Server Unreachable';
            els.outageBanner.classList.remove('hidden');
            if (customMessage) {
                els.outageMessage.textContent = customMessage;
            }
        } else {
            els.serverPill.classList.remove('server-error');
            els.serverPill.classList.add('server-ok');
            els.serverText.textContent = 'Backend Connected';
            els.outageBanner.classList.add('hidden');
        }
    }

    function selectDevice(deviceId, centerMap) {
        state.selectedDeviceId = deviceId;
        renderAll();
        if (centerMap) {
            map.centerOnDevice(deviceId);
        }
    }

    function renderRevokedBanners() {
        els.revokedContainer.textContent = '';
        state.revokedPairings.forEach(function (rev) {
            var banner = document.createElement('div');
            banner.className = 'revoked-banner';
            var reasonText = rev.revoked_by === 'unregister'
                ? ' was unregistered by the phone owner and its stored location was deleted.'
                : ' had its dashboard pairing revoked by the phone owner.';

            var textSpan = document.createElement('span');
            var strongEl = document.createElement('strong');
            strongEl.textContent = 'Pairing Revoked: ';
            textSpan.appendChild(strongEl);
            textSpan.appendChild(document.createTextNode((rev.device_name || 'Device') + ' ('));
            var codeEl = document.createElement('code');
            codeEl.textContent = rev.device_id || '';
            textSpan.appendChild(codeEl);
            textSpan.appendChild(document.createTextNode(')' + reasonText));

            var dismissBtn = document.createElement('button');
            dismissBtn.type = 'button';
            dismissBtn.className = 'btn btn-sm btn-light';
            dismissBtn.textContent = 'Dismiss';
            dismissBtn.addEventListener('click', function () {
                acknowledgeRevokedPairing(rev.device_id);
            });

            banner.appendChild(textSpan);
            banner.appendChild(dismissBtn);
            els.revokedContainer.appendChild(banner);
        });
    }

    function createLabeledSpan(label, valueText) {
        var span = document.createElement('span');
        var strong = document.createElement('strong');
        strong.textContent = label + ' ';
        span.appendChild(strong);
        span.appendChild(document.createTextNode(valueText));
        return span;
    }

    function renderDeviceList() {
        var devices = state.devices;
        els.pairedCountBadge.textContent = String(devices.length);

        if (devices.length === 0) {
            els.emptyDevicesState.classList.remove('hidden');
            els.deviceList.textContent = '';
            els.detailPanel.classList.add('hidden');
            els.mapOverlayMessage.classList.remove('hidden');
            els.mapOverlayMessage.textContent = 'No paired phones yet. Click "+ Pair Phone" to link your Android phone with a one-time code or QR scan.';
            return;
        }

        els.emptyDevicesState.classList.add('hidden');

        // Ensure selectedDeviceId points to an existing device
        var selectedExists = devices.some(function (d) { return d.device_id === state.selectedDeviceId; });
        if (!selectedExists) {
            state.selectedDeviceId = devices[0].device_id;
        }

        els.deviceList.textContent = '';

        devices.forEach(function (dev) {
            var li = document.createElement('li');
            li.className = 'device-card' + (dev.device_id === state.selectedDeviceId ? ' selected' : '');
            li.setAttribute('role', 'option');
            li.setAttribute('aria-selected', dev.device_id === state.selectedDeviceId ? 'true' : 'false');

            var connBadgeClass = dev.is_online ? 'badge-online' : 'badge-offline';
            var connLabel = dev.is_online ? 'Phone Online' : 'Phone Offline';

            var locBadgeClass = 'badge-offline';
            var locLabel = 'No Location Fix';
            if (dev.has_location) {
                if (dev.is_location_fresh) {
                    locBadgeClass = 'badge-online';
                    locLabel = 'Current Fix';
                } else {
                    locBadgeClass = 'badge-stale';
                    locLabel = 'Stale Fix (' + formatRelativeSeconds(dev.location_age_seconds) + ')';
                }
            }

            var stateBadgeClass = 'badge-neutral';
            if (dev.status_state === 'permission_missing') stateBadgeClass = 'badge-danger';
            else if (dev.status_state === 'no_gps_fix') stateBadgeClass = 'badge-stale';

            var cardTop = document.createElement('div');
            cardTop.className = 'device-card-top';
            var titleEl = document.createElement('h3');
            titleEl.className = 'device-card-title';
            titleEl.textContent = dev.device_name || 'Android Phone';
            var connBadge = document.createElement('span');
            connBadge.className = 'badge ' + connBadgeClass;
            connBadge.textContent = connLabel;
            cardTop.appendChild(titleEl);
            cardTop.appendChild(connBadge);

            var badgesRow = document.createElement('div');
            badgesRow.className = 'device-badges';
            var locBadge = document.createElement('span');
            locBadge.className = 'badge ' + locBadgeClass;
            locBadge.textContent = locLabel;
            var appStateBadge = document.createElement('span');
            appStateBadge.className = 'badge ' + stateBadgeClass;
            appStateBadge.textContent = humanizeState(dev.status_state, dev.sharing_enabled);
            badgesRow.appendChild(locBadge);
            badgesRow.appendChild(appStateBadge);

            var metaLines = document.createElement('div');
            metaLines.className = 'device-meta-lines';
            var coordText = dev.has_location && dev.location
                ? dev.location.latitude.toFixed(5) + ', ' + dev.location.longitude.toFixed(5) +
                  (typeof dev.location.accuracy === 'number' ? ' (±' + Math.round(dev.location.accuracy) + 'm)' : '')
                : 'Waiting for phone to share GPS coordinates';
            var fixTimeStr = dev.has_location && dev.location
                ? formatTimestampWithAge(dev.location.recorded_at, dev.location_age_seconds)
                : '—';
            var checkInStr = formatRelativeSeconds(dev.heartbeat_seconds_ago);

            metaLines.appendChild(createLabeledSpan('Fix:', coordText));
            metaLines.appendChild(createLabeledSpan('Captured:', fixTimeStr + ' · Check-in: ' + checkInStr));

            li.appendChild(cardTop);
            li.appendChild(badgesRow);
            li.appendChild(metaLines);

            li.addEventListener('click', function () {
                selectDevice(dev.device_id, true);
            });

            els.deviceList.appendChild(li);
        });
    }

    function renderSelectedDeviceDetails() {
        var selected = null;
        for (var i = 0; i < state.devices.length; i++) {
            if (state.devices[i].device_id === state.selectedDeviceId) {
                selected = state.devices[i];
                break;
            }
        }

        if (!selected) {
            els.detailPanel.classList.add('hidden');
            return;
        }

        els.detailPanel.classList.remove('hidden');
        els.detailName.textContent = selected.device_name;
        els.detailId.textContent = selected.device_id;

        // Honest State Notice Banner inside Inspector
        var noticeMsg = '';
        if (selected.status_state === 'permission_missing') {
            noticeMsg = 'Location permission is missing on this phone. Grant location permission in the LocaShare Android app and tap "Start sharing".';
        } else if (!selected.is_online) {
            noticeMsg = 'This phone is currently offline (last check-in ' + formatRelativeSeconds(selected.heartbeat_seconds_ago) + '). Any displayed coordinates reflect its last uploaded fix.';
        } else if (selected.has_location && selected.is_location_stale) {
            noticeMsg = 'Note: The phone checked in recently (' + formatRelativeSeconds(selected.heartbeat_seconds_ago) + '), but the displayed GPS coordinates are STALE (captured ' + formatRelativeSeconds(selected.location_age_seconds) + ').';
        } else if (selected.status_state === 'no_gps_fix') {
            noticeMsg = 'Sharing is active on the phone, but it has not acquired a GPS/network location fix yet.';
        } else if (!selected.sharing_enabled) {
            noticeMsg = 'Location sharing is currently paused on the phone. Tap "Start sharing" in the Android app to begin live updates.';
        }

        if (noticeMsg) {
            els.detailAlertBox.textContent = noticeMsg;
            els.detailAlertBox.classList.remove('hidden');
        } else {
            els.detailAlertBox.classList.add('hidden');
        }

        els.detailConnection.textContent = selected.is_online
            ? 'Online (checked in ' + formatRelativeSeconds(selected.heartbeat_seconds_ago) + ')'
            : 'Offline (last seen ' + formatRelativeSeconds(selected.heartbeat_seconds_ago) + ')';

        els.detailSharingState.textContent = humanizeState(selected.status_state, selected.sharing_enabled);

        if (!selected.has_location || !selected.location) {
            els.detailFixFreshness.textContent = 'No Fix Stored';
            els.detailFixTime.textContent = '—';
            els.detailCoordinates.textContent = 'No coordinates stored';
            els.detailAccuracy.textContent = '—';
            els.btnCenterSelected.disabled = true;
            els.btnDeleteLocation.disabled = true;
        } else {
            els.detailFixFreshness.textContent = selected.is_location_fresh
                ? 'Current Fix (' + formatRelativeSeconds(selected.location_age_seconds) + ')'
                : 'Stale Fix (captured ' + formatRelativeSeconds(selected.location_age_seconds) + ')';
            els.detailFixTime.textContent = formatTimestampWithAge(selected.location.recorded_at, selected.location_age_seconds);
            els.detailCoordinates.textContent = selected.location.latitude.toFixed(6) + ', ' + selected.location.longitude.toFixed(6);
            els.detailAccuracy.textContent = typeof selected.location.accuracy === 'number'
                ? '±' + Math.round(selected.location.accuracy) + ' meters'
                : 'Not reported';
            els.btnCenterSelected.disabled = false;
            els.btnDeleteLocation.disabled = false;
        }

        els.detailHeartbeatTime.textContent = formatTimestampWithAge(selected.last_heartbeat_at, selected.heartbeat_seconds_ago);

        var netParts = [];
        if (selected.network_status && selected.network_status !== 'unknown') {
            netParts.push(selected.network_status.toUpperCase());
        }
        if (typeof selected.battery === 'number') {
            netParts.push(selected.battery + '%' + (selected.is_charging ? ' (Charging)' : ''));
        }
        els.detailTelemetry.textContent = netParts.length > 0 ? netParts.join(' · ') : 'Not reported';

        // Map overlay message if selected device has no location fix yet
        var anyWithLocation = state.devices.some(function (d) { return d.has_location; });
        if (!anyWithLocation) {
            els.mapOverlayMessage.classList.remove('hidden');
            els.mapOverlayMessage.textContent = 'Phone paired! Tap "Start sharing" in the LocaShare Android app on your phone to send its live location to this map.';
        } else {
            els.mapOverlayMessage.classList.add('hidden');
        }
    }

    function renderAll() {
        renderRevokedBanners();
        renderDeviceList();
        renderSelectedDeviceDetails();
        map.setDevices(state.devices, state.selectedDeviceId);
    }

    function applySessionData(data) {
        if (data.csrf_token) {
            state.csrfToken = data.csrf_token;
        }
        if (typeof data.poll_interval_ms === 'number' && data.poll_interval_ms >= 2000) {
            state.pollIntervalMs = data.poll_interval_ms;
        }
        if (data.thresholds) {
            state.thresholds = data.thresholds;
        }
        state.devices = Array.isArray(data.devices) ? data.devices : [];
        state.revokedPairings = Array.isArray(data.revoked_pairings) ? data.revoked_pairings : [];

        renderAll();

        if (!state.hasCenteredInitially && state.devices.some(function (d) { return d.has_location; })) {
            state.hasCenteredInitially = true;
            map.fitAll();
        }
    }

    function initSession() {
        return apiRequest('/dashboard/session.php').then(function (res) {
            if (!res.ok) {
                setServerOutage(true, res.data.error || 'Unable to establish dashboard session.');
                return;
            }
            setServerOutage(false);
            applySessionData(res.data);
        }).catch(function () {
            setServerOutage(true, 'Unable to reach the LocaShare backend. Check your network or server status.');
        });
    }

    function pollDevices() {
        return apiRequest('/dashboard/devices.php').then(function (res) {
            if (!res.ok) {
                if (res.status === 401) {
                    return initSession();
                }
                setServerOutage(true, res.data.error || 'Backend returned an error.');
                return;
            }
            setServerOutage(false);
            applySessionData(res.data);
        }).catch(function () {
            setServerOutage(true, 'Unable to reach the LocaShare backend. Check your network or server status.');
        });
    }

    function openPairModal() {
        els.pairErrorBox.classList.add('hidden');
        els.pairSuccessBox.classList.add('hidden');
        els.pairingCodeInput.value = '';
        els.pairModalBackdrop.classList.remove('hidden');
        els.pairingCodeInput.focus();
    }

    function closePairModal() {
        stopQrCamera();
        els.pairModalBackdrop.classList.add('hidden');
    }

    function submitPairingCode(rawCode) {
        var code = extractPairingCode(rawCode);
        if (!code || code.replace(/[^A-Z0-9]/g, '').length < 6) {
            els.pairErrorBox.textContent = 'Please enter the 8-character one-time pairing code displayed on your phone.';
            els.pairErrorBox.classList.remove('hidden');
            return;
        }

        els.pairErrorBox.classList.add('hidden');
        els.pairSuccessBox.classList.add('hidden');
        els.btnSubmitPair.disabled = true;

        apiRequest('/dashboard/pair.php', {
            method: 'POST',
            body: {
                pairing_code: code,
                csrf_token: state.csrfToken
            }
        }).then(function (res) {
            els.btnSubmitPair.disabled = false;
            if (!res.ok) {
                var codeErr = res.data.error_code || '';
                var msg = res.data.error || 'Failed to pair phone.';
                if (codeErr === 'CODE_EXPIRED') {
                    msg = 'That pairing code expired. Tap "New Code" on the phone and try again.';
                } else if (codeErr === 'CODE_ALREADY_USED') {
                    msg = 'That one-time pairing code was already used. Generate a fresh code on the phone.';
                } else if (codeErr === 'CODE_REVOKED') {
                    msg = 'That pairing code was replaced by a newer code on the phone.';
                } else if (codeErr === 'DEVICE_UNREGISTERED') {
                    msg = 'That phone was unregistered. Register the device again on the phone.';
                } else if (codeErr === 'RATE_LIMIT_EXCEEDED') {
                    msg = 'Too many pairing attempts. Wait briefly before trying again.';
                }
                els.pairErrorBox.textContent = msg;
                els.pairErrorBox.classList.remove('hidden');
                return;
            }

            if (res.data.csrf_token) {
                state.csrfToken = res.data.csrf_token;
            }
            els.pairSuccessBox.textContent = res.data.message || 'Phone paired!';
            els.pairSuccessBox.classList.remove('hidden');

            if (res.data.device && res.data.device.device_id) {
                state.selectedDeviceId = res.data.device.device_id;
            }

            pollDevices().then(function () {
                setTimeout(function () {
                    closePairModal();
                }, 650);
            });
        }).catch(function () {
            els.btnSubmitPair.disabled = false;
            els.pairErrorBox.textContent = 'Network error while contacting backend. Verify the server is running.';
            els.pairErrorBox.classList.remove('hidden');
        });
    }

    function acknowledgeRevokedPairing(deviceId) {
        apiRequest('/dashboard/unpair.php', {
            method: 'POST',
            body: {
                device_id: deviceId,
                acknowledge_only: true,
                csrf_token: state.csrfToken
            }
        }).then(function () {
            pollDevices();
        });
    }

    function handleUnpairSelected() {
        if (!state.selectedDeviceId) return;
        if (!window.confirm('Unpair this phone from your laptop dashboard? You will need a new one-time pairing code from the phone to view it again.')) {
            return;
        }
        apiRequest('/dashboard/unpair.php', {
            method: 'POST',
            body: {
                device_id: state.selectedDeviceId,
                csrf_token: state.csrfToken
            }
        }).then(function (res) {
            if (res.ok) {
                state.selectedDeviceId = null;
                pollDevices();
            }
        });
    }

    function handleDeleteLocationSelected() {
        if (!state.selectedDeviceId) return;
        if (!window.confirm('Delete the stored location coordinates for this phone from the server?')) {
            return;
        }
        apiRequest('/location/delete.php', {
            method: 'POST',
            body: {
                device_id: state.selectedDeviceId,
                csrf_token: state.csrfToken
            }
        }).then(function (res) {
            if (res.ok) {
                pollDevices();
            }
        });
    }

    // QR Code Camera & Image Scanner
    function startQrCamera() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            els.pairErrorBox.textContent = 'Camera access is not available in this browser. Enter the one-time code manually or upload a screenshot of the QR code.';
            els.pairErrorBox.classList.remove('hidden');
            return;
        }

        els.pairErrorBox.classList.add('hidden');
        navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } })
            .then(function (stream) {
                state.qrStream = stream;
                state.qrScanActive = true;
                els.qrVideo.srcObject = stream;
                els.qrVideo.play();
                els.qrVideoWrap.classList.remove('hidden');
                els.btnStartQrCamera.classList.add('hidden');
                els.btnStopQrCamera.classList.remove('hidden');
                scanQrVideoFrame();
            })
            .catch(function () {
                els.pairErrorBox.textContent = 'Could not access camera. You can type the 8-character pairing code directly above.';
                els.pairErrorBox.classList.remove('hidden');
            });
    }

    function stopQrCamera() {
        state.qrScanActive = false;
        if (state.qrStream) {
            state.qrStream.getTracks().forEach(function (t) { t.stop(); });
            state.qrStream = null;
        }
        if (els.qrVideo) {
            els.qrVideo.srcObject = null;
        }
        els.qrVideoWrap.classList.add('hidden');
        els.btnStartQrCamera.classList.remove('hidden');
        els.btnStopQrCamera.classList.add('hidden');
    }

    function scanQrVideoFrame() {
        if (!state.qrScanActive || !els.qrVideo) {
            return;
        }
        if ('BarcodeDetector' in window) {
            try {
                var detector = new window.BarcodeDetector({ formats: ['qr_code'] });
                detector.detect(els.qrVideo).then(function (barcodes) {
                    if (barcodes && barcodes.length > 0 && barcodes[0].rawValue) {
                        var extracted = extractPairingCode(barcodes[0].rawValue);
                        if (extracted) {
                            els.pairingCodeInput.value = extracted;
                            stopQrCamera();
                            submitPairingCode(extracted);
                            return;
                        }
                    }
                    if (state.qrScanActive) {
                        setTimeout(scanQrVideoFrame, 300);
                    }
                }).catch(function () {
                    if (state.qrScanActive) {
                        setTimeout(scanQrVideoFrame, 400);
                    }
                });
                return;
            } catch (e) {
                // Fall through
            }
        }
        els.qrScanStatus.textContent = 'Camera preview active — if automatic QR detection is unsupported by this browser, enter the 8-character code shown below the QR on your phone.';
    }

    function handleQrFileUpload(file) {
        if (!file) return;
        if ('BarcodeDetector' in window) {
            createImageBitmap(file).then(function (bitmap) {
                var detector = new window.BarcodeDetector({ formats: ['qr_code'] });
                return detector.detect(bitmap);
            }).then(function (barcodes) {
                if (barcodes && barcodes.length > 0 && barcodes[0].rawValue) {
                    var extracted = extractPairingCode(barcodes[0].rawValue);
                    els.pairingCodeInput.value = extracted;
                    submitPairingCode(extracted);
                } else {
                    els.pairErrorBox.textContent = 'No QR code detected in the selected image. Please enter the 8-character pairing code manually.';
                    els.pairErrorBox.classList.remove('hidden');
                }
            }).catch(function () {
                els.pairErrorBox.textContent = 'Could not decode QR image in this browser. Please enter the 8-character pairing code manually.';
                els.pairErrorBox.classList.remove('hidden');
            });
        } else {
            els.pairErrorBox.textContent = 'Browser BarcodeDetector API is unavailable for image decoding. Please enter the 8-character pairing code shown on your phone.';
            els.pairErrorBox.classList.remove('hidden');
        }
    }

    // Event Listeners
    els.btnOpenPairModal.addEventListener('click', openPairModal);
    els.btnEmptyPair.addEventListener('click', openPairModal);
    els.btnClosePairModal.addEventListener('click', closePairModal);
    els.pairModalBackdrop.addEventListener('click', function (e) {
        if (e.target === els.pairModalBackdrop) {
            closePairModal();
        }
    });

    els.pairingCodeInput.addEventListener('input', function () {
        var raw = els.pairingCodeInput.value.replace(/[^A-Za-z0-9]/g, '').toUpperCase();
        if (raw.length > 4) {
            els.pairingCodeInput.value = raw.slice(0, 4) + '-' + raw.slice(4, 12);
        } else {
            els.pairingCodeInput.value = raw;
        }
    });

    els.pairForm.addEventListener('submit', function (e) {
        e.preventDefault();
        submitPairingCode(els.pairingCodeInput.value);
    });

    els.btnStartQrCamera.addEventListener('click', startQrCamera);
    els.btnStopQrCamera.addEventListener('click', stopQrCamera);
    els.qrFileInput.addEventListener('change', function (e) {
        if (e.target.files && e.target.files[0]) {
            handleQrFileUpload(e.target.files[0]);
            e.target.value = '';
        }
    });

    els.btnRefreshNow.addEventListener('click', function () {
        pollDevices();
    });
    els.btnRetryOutage.addEventListener('click', function () {
        pollDevices();
    });

    els.btnCenterSelected.addEventListener('click', function () {
        if (state.selectedDeviceId) {
            map.centerOnDevice(state.selectedDeviceId, 16);
        }
    });
    els.btnDeleteLocation.addEventListener('click', handleDeleteLocationSelected);
    els.btnUnpairDevice.addEventListener('click', handleUnpairSelected);

    els.btnZoomIn.addEventListener('click', function () {
        map.setZoom(map.zoom + 1);
    });
    els.btnZoomOut.addEventListener('click', function () {
        map.setZoom(map.zoom - 1);
    });
    els.btnFitAll.addEventListener('click', function () {
        map.fitAll();
    });
    els.btnCenterActive.addEventListener('click', function () {
        if (state.selectedDeviceId) {
            map.centerOnDevice(state.selectedDeviceId, 15);
        }
    });

    els.chkOsmTiles.addEventListener('change', function () {
        var enabled = els.chkOsmTiles.checked;
        map.setOsmTilesEnabled(enabled);
        if (enabled) {
            els.tileModeBadge.textContent = 'OpenStreetMap Tiles Active (tile.openstreetmap.org)';
        } else {
            els.tileModeBadge.textContent = 'Local Privacy Grid (0 external requests)';
        }
    });

    // Initial Session Load & Polling Loop
    initSession().then(function () {
        state.pollTimer = setInterval(pollDevices, Math.max(3000, state.pollIntervalMs));
    });
})();
