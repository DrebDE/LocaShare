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
        pairedDevices: [],
        familyCircles: [],
        activeCircle: null,
        places: [],
        events: [],
        lastSeenEventId: null,
        desktopAlertsEnabled: false,
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
        detailPresence: document.getElementById('detail-presence'),
        btnCenterSelected: document.getElementById('btn-center-selected'),
        btnDeleteLocation: document.getElementById('btn-delete-location'),
        btnUnpairDevice: document.getElementById('btn-unpair-device'),
        btnRefreshNow: document.getElementById('btn-refresh-now'),
        btnOpenCircleModal: document.getElementById('btn-open-circle-modal'),
        btnJoinCircleInline: document.getElementById('btn-join-circle-inline'),
        btnOpenPairModal: document.getElementById('btn-open-pair-modal'),
        btnEmptyPair: document.getElementById('btn-empty-pair'),
        familyCircleTitle: document.getElementById('family-circle-title'),
        familyCircleSubtitle: document.getElementById('family-circle-subtitle'),
        familyCircleActive: document.getElementById('family-circle-active'),
        familyInviteCode: document.getElementById('family-invite-code'),
        btnDesktopAlerts: document.getElementById('btn-desktop-alerts'),
        btnLeaveCircle: document.getElementById('btn-leave-circle'),
        btnAddPlace: document.getElementById('btn-add-place'),
        savedPlacesList: document.getElementById('saved-places-list'),
        placeEventsList: document.getElementById('place-events-list'),
        circleModalBackdrop: document.getElementById('circle-modal-backdrop'),
        btnCloseCircleModal: document.getElementById('btn-close-circle-modal'),
        circleJoinForm: document.getElementById('circle-join-form'),
        circleInviteInput: document.getElementById('circle-invite-input'),
        circleErrorBox: document.getElementById('circle-error-box'),
        btnSubmitCircleJoin: document.getElementById('btn-submit-circle-join'),
        placeModalBackdrop: document.getElementById('place-modal-backdrop'),
        placeModalTitle: document.getElementById('place-modal-title'),
        btnClosePlaceModal: document.getElementById('btn-close-place-modal'),
        placeForm: document.getElementById('place-form'),
        placeIdInput: document.getElementById('place-id-input'),
        placeNameInput: document.getElementById('place-name-input'),
        placeCategorySelect: document.getElementById('place-category-select'),
        placeLatInput: document.getElementById('place-lat-input'),
        placeLngInput: document.getElementById('place-lng-input'),
        placeRadiusInput: document.getElementById('place-radius-input'),
        placeRadiusLabel: document.getElementById('place-radius-label'),
        placeNotifyEnter: document.getElementById('place-notify-enter'),
        placeNotifyExit: document.getElementById('place-notify-exit'),
        placeErrorBox: document.getElementById('place-error-box'),
        btnPickPlaceOnMap: document.getElementById('btn-pick-place-on-map'),
        btnUseSelectedDeviceCoords: document.getElementById('btn-use-selected-device-coords'),
        btnSavePlace: document.getElementById('btn-save-place'),
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
        googleMapStage: document.getElementById('google-map-stage'),
        mapProviderSelect: document.getElementById('map-provider-select'),
        tileModeBadge: document.getElementById('tile-mode-badge'),
        mapAttribution: document.getElementById('map-attribution')
    };

    var map = new window.LocaShareMap({
        viewport: els.mapViewport,
        canvas: els.mapCanvas,
        markersLayer: els.mapMarkersLayer,
        onSelectDevice: function (deviceId, shouldCenter) {
            selectDevice(deviceId, shouldCenter);
        }
    });
    var MAP_PROVIDERS_META = {
        esri_street: {
            badge: 'Esri World Street Active (services.arcgisonline.com)',
            linkText: 'Tiles © Esri',
            linkHref: 'https://www.esri.com/',
            sourceDetail: ' — Esri, DeLorme, NAVTEQ, USGS, Intermap, iPC, NRCAN, METI, GIS User Community',
            notice: 'Only visible map tile indices (z/y/x) are requested from services.arcgisonline.com; exact device coordinates and tokens stay on your LocaShare server. Select Local Privacy Grid for 0 external requests.'
        },
        esri_hybrid: {
            badge: 'Esri Satellite + Labels Active (services.arcgisonline.com)',
            linkText: 'Sources: Esri, Maxar, Earthstar Geographics',
            linkHref: 'https://www.esri.com/',
            sourceDetail: ', and the GIS User Community',
            notice: 'Only visible map tile indices (z/y/x) are requested from services.arcgisonline.com; exact device coordinates and tokens stay on your LocaShare server. Select Local Privacy Grid for 0 external requests.'
        },
        esri_satellite: {
            badge: 'Esri Satellite Active (services.arcgisonline.com)',
            linkText: 'Sources: Esri, Maxar, Earthstar Geographics',
            linkHref: 'https://www.esri.com/',
            sourceDetail: ', and the GIS User Community',
            notice: 'Only visible map tile indices (z/y/x) are requested from services.arcgisonline.com; exact device coordinates and tokens stay on your LocaShare server. Select Local Privacy Grid for 0 external requests.'
        },
        osm: {
            badge: 'OpenStreetMap Tiles Active (tile.openstreetmap.org)',
            linkText: '© OpenStreetMap contributors',
            linkHref: 'https://www.openstreetmap.org/copyright',
            sourceDetail: '',
            notice: 'Only visible map tile indices (z/x/y) are requested from tile.openstreetmap.org; exact device coordinates and tokens stay on your LocaShare server. Select Local Privacy Grid for 0 external requests.'
        },
        grid: {
            badge: 'Local Privacy Grid (0 external requests)',
            linkText: '',
            linkHref: '',
            sourceDetail: '',
            notice: 'Local Privacy Grid active: all map graticules, accuracy circles, and device pins render locally in your browser with zero external requests.'
        },
        google_roadmap: {
            badge: 'Google Maps Roadmap Active (maps.googleapis.com)',
            linkText: 'Google Maps',
            linkHref: 'https://maps.google.com/',
            sourceDetail: ' (built-in Google attribution shown on map)',
            notice: 'Google Maps JS SDK loads tiles and renders viewport/marker coordinates in your browser via maps.googleapis.com. Switch to Esri or Local Privacy Grid to keep exact coordinates off third-party map providers.'
        },
        google_hybrid: {
            badge: 'Google Maps Satellite + Labels Active (maps.googleapis.com)',
            linkText: 'Google Maps',
            linkHref: 'https://maps.google.com/',
            sourceDetail: ' (built-in Google attribution shown on map)',
            notice: 'Google Maps JS SDK loads tiles and renders viewport/marker coordinates in your browser via maps.googleapis.com. Switch to Esri or Local Privacy Grid to keep exact coordinates off third-party map providers.'
        }
    };

    function hasSelectOption(selectEl, val) {
        if (!selectEl || !selectEl.options) {
            return false;
        }
        for (var i = 0; i < selectEl.options.length; i++) {
            if (selectEl.options[i].value === val) {
                return true;
            }
        }
        return false;
    }

    function renderMapAttribution(providerId) {
        var meta = MAP_PROVIDERS_META[providerId] || MAP_PROVIDERS_META.esri_street;
        if (els.tileModeBadge) {
            els.tileModeBadge.textContent = meta.badge;
        }
        if (!els.mapAttribution) {
            return;
        }
        els.mapAttribution.textContent = '';
        if (meta.linkText) {
            els.mapAttribution.appendChild(document.createTextNode('Map data: '));
            var link = document.createElement('a');
            link.href = meta.linkHref;
            link.target = '_blank';
            link.rel = 'noopener noreferrer';
            link.textContent = meta.linkText;
            els.mapAttribution.appendChild(link);
            if (meta.sourceDetail) {
                els.mapAttribution.appendChild(document.createTextNode(meta.sourceDetail));
            }
            els.mapAttribution.appendChild(document.createTextNode(' · '));
        }
        var strong = document.createElement('strong');
        strong.textContent = 'Privacy notice: ';
        els.mapAttribution.appendChild(strong);
        els.mapAttribution.appendChild(document.createTextNode(meta.notice));
    }

    function applyMapProvider(providerId, persistChoice) {
        var resolved = MAP_PROVIDERS_META[providerId] ? providerId : 'esri_street';
        if (els.mapProviderSelect && els.mapProviderSelect.options && !hasSelectOption(els.mapProviderSelect, resolved)) {
            resolved = 'esri_street';
        }
        if (els.mapProviderSelect) {
            els.mapProviderSelect.value = resolved;
        }
        map.setProvider(resolved);
        renderMapAttribution(resolved);
        if (persistChoice) {
            try {
                if (window.localStorage) {
                    window.localStorage.setItem('locashare_map_provider', resolved);
                }
            } catch (e) {
                // Ignore restricted storage mode
            }
        }
    }

    if (els.googleMapStage) {
        map.googleStage = els.googleMapStage;
    }
    map.onMapAuthError = function (errorMsg) {
        applyMapProvider('esri_street', false);
        if (els.tileModeBadge) {
            els.tileModeBadge.textContent = (errorMsg || 'Google Maps unavailable') + ' — switched to Esri Street';
        }
    };

    var savedProvider = '';
    try {
        savedProvider = window.localStorage ? (window.localStorage.getItem('locashare_map_provider') || '') : '';
    } catch (e) {
        savedProvider = '';
    }
    var initialProvider = savedProvider || (els.mapProviderSelect && els.mapProviderSelect.value) || 'esri_street';
    applyMapProvider(initialProvider, false);

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

            if (dev.presence_mode && dev.presence_mode !== 'unknown') {
                var presBadge = document.createElement('span');
                if (dev.presence_mode === 'at_home') {
                    presBadge.className = 'badge badge-at-home';
                    presBadge.textContent = dev.home_privacy_masked ? 'At Home (Privacy Saver)' : 'At Home';
                } else if (dev.presence_mode === 'at_place' && dev.current_place_name) {
                    presBadge.className = 'badge badge-at-place';
                    presBadge.textContent = 'At ' + dev.current_place_name;
                } else {
                    presBadge.className = 'badge badge-away';
                    presBadge.textContent = 'Out of House · Live';
                }
                badgesRow.appendChild(presBadge);
            }

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

        if (els.detailPresence) {
            if (selected.presence_mode === 'at_home') {
                els.detailPresence.textContent = selected.home_privacy_masked
                    ? 'At Home (Privacy & Battery Saver)'
                    : 'At Home';
            } else if (selected.presence_mode === 'at_place' && selected.current_place_name) {
                els.detailPresence.textContent = 'At ' + selected.current_place_name;
            } else if (selected.presence_mode === 'away') {
                els.detailPresence.textContent = 'Away from Home (Live GPS)';
            } else {
                els.detailPresence.textContent = '—';
            }
        }
        var isCircleOnly = Boolean(selected._circleOnly);
        els.btnDeleteLocation.classList.toggle('hidden', isCircleOnly);
        els.btnUnpairDevice.classList.toggle('hidden', isCircleOnly);

        // Map overlay message if selected device has no location fix yet
        var anyWithLocation = state.devices.some(function (d) { return d.has_location; });
        if (!anyWithLocation) {
            els.mapOverlayMessage.classList.remove('hidden');
            els.mapOverlayMessage.textContent = 'Phone paired! Tap "Start sharing" in the LocaShare Android app on your phone to send its live location to this map.';
        } else {
            els.mapOverlayMessage.classList.add('hidden');
        }
    }

    function mergeAllVisibleDevices() {
        var byId = {};
        var merged = [];
        (state.pairedDevices || []).forEach(function (d) {
            byId[d.device_id] = d;
            merged.push(d);
        });
        (state.familyCircles || []).forEach(function (c) {
            (c.members || []).forEach(function (m) {
                if (byId[m.device_id]) {
                    byId[m.device_id].member_name = m.member_name;
                    byId[m.device_id].avatar_color = m.avatar_color;
                } else {
                    var copy = Object.assign({}, m, { _circleOnly: true });
                    byId[m.device_id] = copy;
                    merged.push(copy);
                }
            });
        });
        state.devices = merged;
    }

    function renderFamilyPanel() {
        if (!els.familyCircleActive) return;
        var circleBundle = state.activeCircle;
        if (!circleBundle || !circleBundle.circle) {
            els.familyCircleTitle.textContent = 'Family Circle';
            els.familyCircleSubtitle.classList.remove('hidden');
            els.familyCircleActive.classList.add('hidden');
            return;
        }

        els.familyCircleTitle.textContent = circleBundle.circle.name || 'Family Circle';
        els.familyCircleSubtitle.classList.add('hidden');
        els.familyCircleActive.classList.remove('hidden');
        els.familyInviteCode.textContent = circleBundle.circle.invite_code || '—';
        if (els.btnDesktopAlerts) {
            els.btnDesktopAlerts.textContent = state.desktopAlertsEnabled ? 'Alerts: On' : 'Alerts: Off';
        }

        // Saved Places list
        els.savedPlacesList.textContent = '';
        var places = state.places || [];
        if (places.length === 0) {
            var emptyPl = document.createElement('li');
            emptyPl.className = 'place-item';
            var emptySub = document.createElement('span');
            emptySub.className = 'place-item-sub';
            emptySub.textContent = 'No places yet. Add Home first so At-Home privacy & out-of-house alerts work automatically.';
            emptyPl.appendChild(emptySub);
            els.savedPlacesList.appendChild(emptyPl);
        } else {
            places.forEach(function (pl) {
                var li = document.createElement('li');
                li.className = 'place-item';

                var meta = document.createElement('div');
                meta.className = 'place-item-meta';
                var title = document.createElement('span');
                title.className = 'place-item-title';
                title.textContent = (pl.is_home ? '🏠 ' : '') + pl.name;
                var sub = document.createElement('span');
                sub.className = 'place-item-sub';
                sub.textContent = (pl.category || 'custom').toUpperCase() + ' · ' + pl.radius_meters + 'm';
                meta.appendChild(title);
                meta.appendChild(sub);

                var acts = document.createElement('div');
                acts.className = 'place-item-actions';

                var focusBtn = document.createElement('button');
                focusBtn.type = 'button';
                focusBtn.className = 'btn btn-secondary btn-sm';
                focusBtn.textContent = 'Map';
                focusBtn.addEventListener('click', function () {
                    map.centerOnCoords(pl.latitude, pl.longitude, 16);
                });

                var editBtn = document.createElement('button');
                editBtn.type = 'button';
                editBtn.className = 'btn btn-secondary btn-sm';
                editBtn.textContent = 'Edit';
                editBtn.addEventListener('click', function () {
                    openPlaceModal(pl);
                });

                var delBtn = document.createElement('button');
                delBtn.type = 'button';
                delBtn.className = 'btn btn-danger-outline btn-sm';
                delBtn.textContent = '×';
                delBtn.addEventListener('click', function () {
                    deleteSavedPlace(pl.place_id);
                });

                acts.appendChild(focusBtn);
                acts.appendChild(editBtn);
                acts.appendChild(delBtn);

                li.appendChild(meta);
                li.appendChild(acts);
                els.savedPlacesList.appendChild(li);
            });
        }

        // Place Events feed
        els.placeEventsList.textContent = '';
        var events = state.events || [];
        if (events.length === 0) {
            var emptyEv = document.createElement('li');
            emptyEv.className = 'event-item';
            var evSub = document.createElement('span');
            evSub.className = 'event-item-time';
            evSub.textContent = 'No arrive/leave events recorded yet.';
            emptyEv.appendChild(evSub);
            els.placeEventsList.appendChild(emptyEv);
        } else {
            events.slice(0, 12).forEach(function (ev) {
                var li = document.createElement('li');
                li.className = 'event-item';
                var verb = ev.event_type === 'exited' ? 'left' : 'arrived at';
                var msg = document.createElement('span');
                msg.textContent = (ev.member_name || 'Member') + ' ' + verb + ' ' + (ev.place_name || 'Place');
                var tm = document.createElement('span');
                tm.className = 'event-item-time';
                tm.textContent = ev.occurred_at ? new Date(ev.occurred_at).toLocaleTimeString() : '';
                li.appendChild(msg);
                li.appendChild(tm);
                els.placeEventsList.appendChild(li);
            });
        }
    }

    function renderAll() {
        mergeAllVisibleDevices();
        renderRevokedBanners();
        renderDeviceList();
        renderSelectedDeviceDetails();
        renderFamilyPanel();
        map.setPlaces(state.places);
        map.setDevices(state.devices, state.selectedDeviceId);
    }

    function applyFamilyStateData(data) {
        var circles = Array.isArray(data.circles) ? data.circles : [];
        state.familyCircles = circles;
        state.activeCircle = circles.length > 0 ? circles[0] : null;
        state.places = state.activeCircle && Array.isArray(state.activeCircle.places)
            ? state.activeCircle.places
            : [];
        var incomingEvents = state.activeCircle && Array.isArray(state.activeCircle.events)
            ? state.activeCircle.events
            : [];

        if (incomingEvents.length > 0) {
            var newest = incomingEvents[0];
            if (state.lastSeenEventId && newest.event_id !== state.lastSeenEventId && state.desktopAlertsEnabled && 'Notification' in window && window.Notification.permission === 'granted') {
                var verb = newest.event_type === 'exited' ? 'left' : 'arrived at';
                new window.Notification('LocaShare Family Alert', {
                    body: (newest.member_name || 'Family member') + ' ' + verb + ' ' + (newest.place_name || 'Place')
                });
            }
            state.lastSeenEventId = newest.event_id;
        }
        state.events = incomingEvents;
        renderAll();
    }

    function applySessionData(data) {
        if (data.csrf_token) {
            state.csrfToken = data.csrf_token;
        }
        if (data.map_config) {
            map.setGoogleMapsApiKey(data.map_config.google_maps_api_key || '');
            var stored = '';
            try {
                stored = window.localStorage ? (window.localStorage.getItem('locashare_map_provider') || '') : '';
            } catch (e) {
                stored = '';
            }
            if (!stored && data.map_config.default_provider) {
                applyMapProvider(data.map_config.default_provider, false);
            } else {
                applyMapProvider((els.mapProviderSelect && els.mapProviderSelect.value) || 'esri_street', false);
            }
        }
        if (typeof data.poll_interval_ms === 'number' && data.poll_interval_ms >= 2000) {
            state.pollIntervalMs = data.poll_interval_ms;
        }
        if (data.thresholds) {
            state.thresholds = data.thresholds;
        }
        state.pairedDevices = Array.isArray(data.devices) ? data.devices : [];
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
            return pollFamilyState();
        }).catch(function () {
            setServerOutage(true, 'Unable to reach the LocaShare backend. Check your network or server status.');
        });
    }

    function pollFamilyState() {
        return apiRequest('/dashboard/family-state.php').then(function (res) {
            if (res.ok && res.data) {
                applyFamilyStateData(res.data);
            }
        }).catch(function () {
            // Keep existing family state on transient error
        });
    }

    function pollDevices() {
        return Promise.all([
            apiRequest('/dashboard/devices.php'),
            apiRequest('/dashboard/family-state.php').catch(function () { return { ok: false }; })
        ]).then(function (results) {
            var res = results[0];
            var famRes = results[1];
            if (!res.ok) {
                if (res.status === 401) {
                    return initSession();
                }
                setServerOutage(true, res.data.error || 'Backend returned an error.');
                return;
            }
            setServerOutage(false);
            if (famRes && famRes.ok && famRes.data) {
                applyFamilyStateData(famRes.data);
            }
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

    if (els.mapProviderSelect) {
        els.mapProviderSelect.addEventListener('change', function () {
            applyMapProvider(els.mapProviderSelect.value, true);
        });
    }

    // ── Family Circle & Saved Places Controls ────────────────────
    function openCircleModal() {
        if (!els.circleModalBackdrop) return;
        els.circleErrorBox.classList.add('hidden');
        els.circleInviteInput.value = '';
        els.circleModalBackdrop.classList.remove('hidden');
        els.circleInviteInput.focus();
    }

    function closeCircleModal() {
        if (els.circleModalBackdrop) {
            els.circleModalBackdrop.classList.add('hidden');
        }
    }

    function openPlaceModal(existingPlace) {
        if (!els.placeModalBackdrop || !state.activeCircle || !state.activeCircle.circle) return;
        els.placeErrorBox.classList.add('hidden');
        if (existingPlace) {
            els.placeModalTitle.textContent = 'Edit Saved Place';
            els.placeIdInput.value = existingPlace.place_id || '';
            els.placeNameInput.value = existingPlace.name || '';
            els.placeCategorySelect.value = existingPlace.category || 'custom';
            els.placeLatInput.value = String(existingPlace.latitude);
            els.placeLngInput.value = String(existingPlace.longitude);
            els.placeRadiusInput.value = String(existingPlace.radius_meters || 150);
            els.placeRadiusLabel.textContent = String(existingPlace.radius_meters || 150);
            els.placeNotifyEnter.checked = existingPlace.notify_on_enter !== false;
            els.placeNotifyExit.checked = existingPlace.notify_on_exit !== false;
        } else {
            els.placeModalTitle.textContent = 'Add Saved Place';
            els.placeIdInput.value = '';
            els.placeNameInput.value = state.places.some(function (p) { return p.is_home; }) ? 'School' : 'Home';
            els.placeCategorySelect.value = state.places.some(function (p) { return p.is_home; }) ? 'school' : 'home';
            els.placeLatInput.value = map.centerLat.toFixed(6);
            els.placeLngInput.value = map.centerLng.toFixed(6);
            els.placeRadiusInput.value = '150';
            els.placeRadiusLabel.textContent = '150';
            els.placeNotifyEnter.checked = true;
            els.placeNotifyExit.checked = true;
        }
        els.placeModalBackdrop.classList.remove('hidden');
    }

    function closePlaceModal() {
        if (els.placeModalBackdrop) {
            els.placeModalBackdrop.classList.add('hidden');
        }
    }

    function deleteSavedPlace(placeId) {
        if (!state.activeCircle || !state.activeCircle.circle) return;
        if (!window.confirm('Delete this saved place?')) return;
        apiRequest('/dashboard/place-delete.php', {
            method: 'POST',
            body: {
                circle_id: state.activeCircle.circle.circle_id,
                place_id: placeId,
                csrf_token: state.csrfToken
            }
        }).then(function (res) {
            if (res.ok && res.data) {
                applyFamilyStateData(res.data);
            }
        });
    }

    if (els.btnOpenCircleModal) els.btnOpenCircleModal.addEventListener('click', openCircleModal);
    if (els.btnJoinCircleInline) els.btnJoinCircleInline.addEventListener('click', openCircleModal);
    if (els.btnCloseCircleModal) els.btnCloseCircleModal.addEventListener('click', closeCircleModal);

    if (els.circleJoinForm) {
        els.circleJoinForm.addEventListener('submit', function (e) {
            e.preventDefault();
            var code = els.circleInviteInput.value.trim();
            if (!code) {
                els.circleErrorBox.textContent = 'Enter a family invite code.';
                els.circleErrorBox.classList.remove('hidden');
                return;
            }
            els.btnSubmitCircleJoin.disabled = true;
            apiRequest('/dashboard/family-join.php', {
                method: 'POST',
                body: { invite_code: code, csrf_token: state.csrfToken }
            }).then(function (res) {
                els.btnSubmitCircleJoin.disabled = false;
                if (!res.ok) {
                    els.circleErrorBox.textContent = res.data.error || 'Invite code not found.';
                    els.circleErrorBox.classList.remove('hidden');
                    return;
                }
                if (res.data.csrf_token) {
                    state.csrfToken = res.data.csrf_token;
                }
                applyFamilyStateData(res.data);
                closeCircleModal();
                map.fitAll();
            }).catch(function () {
                els.btnSubmitCircleJoin.disabled = false;
                els.circleErrorBox.textContent = 'Network error while joining family circle.';
                els.circleErrorBox.classList.remove('hidden');
            });
        });
    }

    if (els.btnLeaveCircle) {
        els.btnLeaveCircle.addEventListener('click', function () {
            if (!state.activeCircle || !state.activeCircle.circle) return;
            if (!window.confirm('Disconnect this dashboard from the family circle?')) return;
            apiRequest('/dashboard/family-leave.php', {
                method: 'POST',
                body: {
                    circle_id: state.activeCircle.circle.circle_id,
                    csrf_token: state.csrfToken
                }
            }).then(function (res) {
                if (res.ok && res.data) {
                    applyFamilyStateData(res.data);
                }
            });
        });
    }

    if (els.btnDesktopAlerts) {
        els.btnDesktopAlerts.addEventListener('click', function () {
            if (!('Notification' in window)) {
                state.desktopAlertsEnabled = !state.desktopAlertsEnabled;
                renderFamilyPanel();
                return;
            }
            if (state.desktopAlertsEnabled) {
                state.desktopAlertsEnabled = false;
                renderFamilyPanel();
                return;
            }
            window.Notification.requestPermission().then(function (perm) {
                state.desktopAlertsEnabled = (perm === 'granted');
                renderFamilyPanel();
            });
        });
    }

    if (els.btnAddPlace) {
        els.btnAddPlace.addEventListener('click', function () { openPlaceModal(null); });
    }
    if (els.btnClosePlaceModal) {
        els.btnClosePlaceModal.addEventListener('click', closePlaceModal);
    }
    if (els.placeRadiusInput) {
        els.placeRadiusInput.addEventListener('input', function () {
            els.placeRadiusLabel.textContent = els.placeRadiusInput.value;
        });
    }
    if (els.btnUseSelectedDeviceCoords) {
        els.btnUseSelectedDeviceCoords.addEventListener('click', function () {
            var dev = state.devices.find(function (d) { return d.device_id === state.selectedDeviceId && d.has_location && d.location; });
            if (dev) {
                els.placeLatInput.value = dev.location.latitude.toFixed(6);
                els.placeLngInput.value = dev.location.longitude.toFixed(6);
            }
        });
    }
    if (els.btnPickPlaceOnMap) {
        els.btnPickPlaceOnMap.addEventListener('click', function () {
            closePlaceModal();
            els.mapOverlayMessage.classList.remove('hidden');
            els.mapOverlayMessage.textContent = 'Click anywhere on the map to set coordinates for this Saved Place.';
            map.enableLocationPick(function (lat, lng) {
                els.mapOverlayMessage.classList.add('hidden');
                els.placeModalBackdrop.classList.remove('hidden');
                els.placeLatInput.value = lat.toFixed(6);
                els.placeLngInput.value = lng.toFixed(6);
            });
        });
    }
    if (els.placeForm) {
        els.placeForm.addEventListener('submit', function (e) {
            e.preventDefault();
            if (!state.activeCircle || !state.activeCircle.circle) return;
            els.placeErrorBox.classList.add('hidden');
            var category = els.placeCategorySelect.value;
            apiRequest('/dashboard/place-upsert.php', {
                method: 'POST',
                body: {
                    circle_id: state.activeCircle.circle.circle_id,
                    place_id: els.placeIdInput.value || undefined,
                    name: els.placeNameInput.value.trim(),
                    category: category,
                    is_home: category === 'home',
                    latitude: parseFloat(els.placeLatInput.value),
                    longitude: parseFloat(els.placeLngInput.value),
                    radius_meters: parseInt(els.placeRadiusInput.value, 10) || 150,
                    notify_on_enter: Boolean(els.placeNotifyEnter.checked),
                    notify_on_exit: Boolean(els.placeNotifyExit.checked),
                    csrf_token: state.csrfToken
                }
            }).then(function (res) {
                if (!res.ok) {
                    els.placeErrorBox.textContent = res.data.error || 'Failed to save place.';
                    els.placeErrorBox.classList.remove('hidden');
                    return;
                }
                applyFamilyStateData(res.data);
                closePlaceModal();
            });
        });
    }

    // Initial Session Load & Polling Loop
    initSession().then(function () {
        state.pollTimer = setInterval(pollDevices, Math.max(3000, state.pollIntervalMs));
    });
})();
