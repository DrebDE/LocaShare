<?php
/**
 * LocaShare - Laptop Web Dashboard Shell
 *
 * Serves an unprivileged HTML shell with strict Content-Security-Policy and
 * framing headers. Location data is never embedded in HTML and is fetched only
 * via authenticated HttpOnly, SameSite=Strict session endpoints.
 */

declare(strict_types=1);

$reqPath = parse_url($_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH) ?: '';
if ($reqPath !== '') {
    if (!preg_match('#/dashboard/?$#', $reqPath)) {
        header('Location: ' . rtrim($reqPath, '/') . '/dashboard/', true, 302);
        exit;
    }
    if (str_ends_with($reqPath, '/dashboard')) {
        header('Location: ' . $reqPath . '/', true, 302);
        exit;
    }
}

$appConfig = require __DIR__ . '/../config/app.php';
$dashboardMapConfig = $appConfig['dashboard'] ?? [];
$googleMapsApiKey = trim((string) ($dashboardMapConfig['google_maps_api_key'] ?? ''));
$googleMapsEnabled = $googleMapsApiKey !== '';
$defaultMapProvider = (string) ($dashboardMapConfig['default_map_provider'] ?? 'esri_street');

$scriptSrc = "'self'" . ($googleMapsEnabled ? ' https://maps.googleapis.com https://*.googleapis.com' : '');
$styleSrc = "'self'" . ($googleMapsEnabled ? " 'unsafe-inline' https://fonts.googleapis.com" : '');
$imgSrc = "'self' data: blob: https://services.arcgisonline.com https://tile.openstreetmap.org"
    . ($googleMapsEnabled ? ' https://maps.googleapis.com https://maps.gstatic.com https://*.googleapis.com https://*.ggpht.com' : '');
$connectSrc = "'self'" . ($googleMapsEnabled ? ' https://maps.googleapis.com https://mapsresources-pa.googleapis.com https://*.googleapis.com' : '');
$fontSrcDirective = $googleMapsEnabled ? "font-src 'self' https://fonts.gstatic.com; " : '';

header('Content-Type: text/html; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: strict-origin-when-cross-origin');
header('Cache-Control: no-store, no-cache, must-revalidate, private');
header('Pragma: no-cache');
header(
    "Content-Security-Policy: "
    . "default-src 'self'; "
    . "script-src " . $scriptSrc . "; "
    . "style-src " . $styleSrc . "; "
    . "img-src " . $imgSrc . "; "
    . "connect-src " . $connectSrc . "; "
    . $fontSrcDirective
    . "media-src 'self' blob:; "
    . "frame-ancestors 'none'; "
    . "base-uri 'self'; "
    . "form-action 'self'"
);
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LocaShare &mdash; Private Device Map Dashboard</title>
    <link rel="stylesheet" href="assets/css/dashboard.css">
</head>
<body>
    <div class="app-shell">
        <header class="topbar">
            <div class="brand">
                <div class="brand-icon" aria-hidden="true">LS</div>
                <div>
                    <h1 class="brand-title">LocaShare</h1>
                    <p class="brand-subtitle">Consent-first phone tracker &middot; No login required</p>
                </div>
            </div>

            <div class="topbar-actions">
                <div id="server-status-pill" class="server-pill" role="status" aria-live="polite">
                    <span class="status-dot" aria-hidden="true"></span>
                    <span id="server-status-text">Connecting&hellip;</span>
                </div>
                <a href="assets/LocaShare.apk" download="LocaShare.apk" class="btn btn-secondary btn-sm">
                    Download Android APK
                </a>
                <a href="phone.php" target="_blank" class="btn btn-secondary btn-sm">
                    Phone Web App
                </a>
                <button id="btn-refresh-now" class="btn btn-secondary btn-sm" type="button">
                    Refresh Now
                </button>
                <button id="btn-open-circle-modal" class="btn btn-secondary btn-sm" type="button">
                    + Family Circle
                </button>
                <button id="btn-open-pair-modal" class="btn btn-primary btn-sm" type="button">
                    + Pair Phone
                </button>
            </div>
        </header>

        <div id="outage-banner" class="alert-banner alert-danger hidden" role="alert">
            <span>
                <strong>Backend unreachable:</strong>
                <span id="outage-message">Unable to contact the LocaShare server. Retrying automatically&hellip;</span>
            </span>
            <button id="btn-retry-outage" class="btn btn-sm btn-light" type="button">Retry</button>
        </div>

        <div id="revoked-container" class="revoked-stack" aria-live="polite"></div>

        <main class="workspace">
            <aside class="sidebar" aria-label="Paired phones">
                <div class="sidebar-header">
                    <div class="sidebar-title-row">
                        <h2>Paired Phones</h2>
                        <span id="paired-count-badge" class="badge badge-neutral">0</span>
                    </div>
                    <p class="sidebar-hint">
                        Click a device to center the map and inspect its latest fix vs. phone check-in time.
                    </p>
                </div>

                <div id="empty-devices-state" class="empty-state hidden">
                    <div class="empty-icon" aria-hidden="true">&#128241;</div>
                    <h3>No phones paired to this browser</h3>
                    <p>
                        Open LocaShare on your Android phone, tap <strong>Register this device</strong>,
                        then enter the one-time code or scan its QR code here.
                    </p>
                    <button id="btn-empty-pair" class="btn btn-primary" type="button">
                        Pair Your First Phone
                    </button>
                </div>

                <ul id="device-list" class="device-list" role="listbox" aria-label="Paired devices"></ul>

                <section id="device-detail-panel" class="device-detail hidden" aria-label="Selected device details">
                    <div class="detail-header">
                        <div>
                            <h3 id="detail-device-name">Phone</h3>
                            <code id="detail-device-id" class="device-id-code">dev_...</code>
                        </div>
                        <button id="btn-center-selected" class="btn btn-secondary btn-sm" type="button">
                            Center on Map
                        </button>
                    </div>

                    <div id="detail-alert-box" class="detail-state-notice hidden" role="status"></div>

                    <dl class="detail-grid">
                        <div class="detail-item">
                            <dt>Connection Status</dt>
                            <dd id="detail-connection">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Phone App State</dt>
                            <dd id="detail-sharing-state">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Fix Freshness</dt>
                            <dd id="detail-fix-freshness">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Location Fix Time</dt>
                            <dd id="detail-fix-time">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Phone Check-in Time</dt>
                            <dd id="detail-heartbeat-time">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Latest Coordinates</dt>
                            <dd id="detail-coordinates">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Accuracy</dt>
                            <dd id="detail-accuracy">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Network &amp; Battery</dt>
                            <dd id="detail-telemetry">&mdash;</dd>
                        </div>
                        <div class="detail-item">
                            <dt>Home / Place Mode</dt>
                            <dd id="detail-presence">&mdash;</dd>
                        </div>
                    </dl>

                    <div class="detail-actions">
                        <button id="btn-delete-location" class="btn btn-warning-outline btn-sm" type="button">
                            Delete Stored Location
                        </button>
                        <button id="btn-unpair-device" class="btn btn-danger-outline btn-sm" type="button">
                            Unpair Phone
                        </button>
                    </div>
                </section>

                <!-- Family Circle & Saved Places (Home, School, Work) -->
                <section id="family-circle-panel" class="family-panel" aria-label="Family Circle and Saved Places">
                    <div class="sidebar-title-row">
                        <h2 id="family-circle-title">Family Circle</h2>
                        <button id="btn-join-circle-inline" class="btn btn-secondary btn-sm" type="button">Join Code</button>
                    </div>
                    <p id="family-circle-subtitle" class="sidebar-hint">
                        Join your family&rsquo;s <code>FAM-XXXX-XXXX</code> invite code to view everyone&rsquo;s Home vs. Away status, Saved Places, and enter/exit alerts.
                    </p>

                    <div id="family-circle-active" class="hidden">
                        <div class="family-invite-bar">
                            <span>Invite: <strong id="family-invite-code">&mdash;</strong></span>
                            <div class="family-invite-actions">
                                <button id="btn-desktop-alerts" class="btn btn-secondary btn-sm" type="button">Alerts: Off</button>
                                <button id="btn-leave-circle" class="btn btn-danger-outline btn-sm" type="button">Leave</button>
                            </div>
                        </div>

                        <div class="family-subsection">
                            <div class="sidebar-title-row">
                                <h3>Saved Places</h3>
                                <button id="btn-add-place" class="btn btn-primary btn-sm" type="button">+ Add Place</button>
                            </div>
                            <ul id="saved-places-list" class="places-list"></ul>
                        </div>

                        <div class="family-subsection">
                            <h3>Recent Place Alerts</h3>
                            <ul id="place-events-list" class="events-list"></ul>
                        </div>
                    </div>
                </section>
            </aside>

            <section class="map-stage" aria-label="Interactive device map">
                <div id="map-viewport" class="map-viewport">
                    <canvas id="map-canvas" class="map-canvas"></canvas>
                    <div id="google-map-stage" class="google-map-stage hidden" aria-label="Google Maps viewport"></div>
                    <div id="map-markers-layer" class="map-markers-layer"></div>

                    <div class="map-controls" aria-label="Map zoom and framing controls">
                        <button id="btn-zoom-in" class="map-ctrl-btn" type="button" title="Zoom in" aria-label="Zoom in">+</button>
                        <button id="btn-zoom-out" class="map-ctrl-btn" type="button" title="Zoom out" aria-label="Zoom out">&minus;</button>
                        <button id="btn-fit-all" class="map-ctrl-btn map-ctrl-wide" type="button">Fit All</button>
                        <button id="btn-center-active" class="map-ctrl-btn map-ctrl-wide" type="button">Center</button>
                    </div>

                    <div id="map-overlay-message" class="map-overlay-card hidden" role="status"></div>
                </div>

                <footer class="map-footer">
                    <div class="map-privacy-toggle">
                        <label class="toggle-label" for="map-provider-select">
                            <span>Map style</span>
                            <select id="map-provider-select" class="map-provider-select" aria-label="Select map provider">
                                <option value="esri_street"<?php echo $defaultMapProvider === 'esri_street' ? ' selected' : ''; ?>>Street Map (Esri World Street)</option>
                                <option value="esri_hybrid"<?php echo $defaultMapProvider === 'esri_hybrid' ? ' selected' : ''; ?>>Satellite + Street Labels (Esri Hybrid)</option>
                                <option value="esri_satellite"<?php echo $defaultMapProvider === 'esri_satellite' ? ' selected' : ''; ?>>Satellite Imagery (Esri)</option>
                                <option value="osm"<?php echo $defaultMapProvider === 'osm' ? ' selected' : ''; ?>>OpenStreetMap Standard</option>
                                <option value="grid"<?php echo $defaultMapProvider === 'grid' ? ' selected' : ''; ?>>Local Privacy Grid (Offline / 0 external requests)</option>
<?php if ($googleMapsEnabled): ?>
                                <option value="google_roadmap"<?php echo $defaultMapProvider === 'google_roadmap' ? ' selected' : ''; ?>>Google Maps (Roadmap)</option>
                                <option value="google_hybrid"<?php echo $defaultMapProvider === 'google_hybrid' ? ' selected' : ''; ?>>Google Maps (Satellite + Labels)</option>
<?php endif; ?>
                            </select>
                        </label>
                        <span id="tile-mode-badge" class="badge badge-privacy">
                            Esri World Street Active (services.arcgisonline.com)
                        </span>
                    </div>
                    <div id="map-attribution" class="map-attribution">
                        Map data:
                        Tiles &copy; <a href="https://www.esri.com/" target="_blank" rel="noopener noreferrer">Esri</a>
                        &mdash; Esri, DeLorme, NAVTEQ, USGS, Intermap, iPC, NRCAN, METI, GIS User Community
                        &middot;
                        <strong>Privacy notice:</strong> Only visible map tile indices (<code>z/y/x</code>) are requested from
                        <code>services.arcgisonline.com</code>; exact device coordinates and tokens never leave your LocaShare server.
                        Select Local Privacy Grid for 0 external requests.
                    </div>
                </footer>
            </section>
        </main>
    </div>

    <!-- Pair Phone Modal -->
    <div id="pair-modal-backdrop" class="modal-backdrop hidden" role="dialog" aria-modal="true" aria-labelledby="pair-modal-title">
        <div class="modal-card">
            <div class="modal-header">
                <h2 id="pair-modal-title">Pair a Phone to This Dashboard</h2>
                <button id="btn-close-pair-modal" class="modal-close" type="button" aria-label="Close pairing dialog">&times;</button>
            </div>
            <div class="modal-body">
                <p class="modal-intro">
                    In LocaShare on your Android phone, tap <strong>Register this device</strong> (or
                    <strong>New Pairing Code</strong>) to obtain a single-use code valid for 5 minutes.
                </p>

                <div id="pair-error-box" class="alert-inline alert-danger hidden" role="alert"></div>
                <div id="pair-success-box" class="alert-inline alert-success hidden" role="status"></div>

                <form id="pair-form" novalidate>
                    <label class="field-label" for="pairing-code-input">One-Time Pairing Code</label>
                    <div class="code-input-row">
                        <input
                            id="pairing-code-input"
                            class="code-input"
                            type="text"
                            autocomplete="off"
                            autocapitalize="characters"
                            spellcheck="false"
                            maxlength="200"
                            placeholder="ABCD-2345"
                            required
                        >
                        <button id="btn-submit-pair" class="btn btn-primary" type="submit">Pair</button>
                    </div>
                    <p class="field-help">
                        Codes are single-use and expire automatically. Your browser receives an isolated HttpOnly session cookie.
                    </p>
                </form>

                <div class="qr-divider"><span>OR SCAN QR CODE</span></div>

                <div class="qr-actions-row">
                    <button id="btn-start-qr-camera" class="btn btn-secondary btn-sm" type="button">
                        Start Camera Scan
                    </button>
                    <button id="btn-stop-qr-camera" class="btn btn-secondary btn-sm hidden" type="button">
                        Stop Camera
                    </button>
                    <label class="btn btn-secondary btn-sm">
                        Upload QR Screenshot
                        <input id="qr-file-input" type="file" accept="image/*" class="hidden">
                    </label>
                </div>

                <div id="qr-video-wrap" class="qr-video-wrap hidden">
                    <video id="qr-video" autoplay playsinline muted></video>
                </div>
                <p id="qr-scan-status" class="qr-scan-status">
                    Camera and screenshot decoding run locally in your browser.
                </p>
            </div>
        </div>
    </div>

    <!-- Join Family Circle Modal -->
    <div id="circle-modal-backdrop" class="modal-backdrop hidden" role="dialog" aria-modal="true" aria-labelledby="circle-modal-title">
        <div class="modal-card">
            <div class="modal-header">
                <h2 id="circle-modal-title">Join a Family Circle</h2>
                <button id="btn-close-circle-modal" class="modal-close" type="button" aria-label="Close circle dialog">&times;</button>
            </div>
            <div class="modal-body">
                <p class="modal-intro">
                    Enter the Family Circle invite code shown in the <strong>LocaShare</strong> mobile app (e.g., <code>FAM-XXXX-XXXX</code>).
                </p>
                <div id="circle-error-box" class="alert-inline alert-danger hidden" role="alert"></div>
                <form id="circle-join-form" novalidate>
                    <label class="field-label" for="circle-invite-input">Family Invite Code</label>
                    <div class="code-input-row">
                        <input id="circle-invite-input" class="code-input" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="32" placeholder="FAM-ABCD-2345" required>
                        <button id="btn-submit-circle-join" class="btn btn-primary" type="submit">Join</button>
                    </div>
                </form>
            </div>
        </div>
    </div>

    <!-- Add / Edit Saved Place Modal -->
    <div id="place-modal-backdrop" class="modal-backdrop hidden" role="dialog" aria-modal="true" aria-labelledby="place-modal-title">
        <div class="modal-card">
            <div class="modal-header">
                <h2 id="place-modal-title">Add Saved Place</h2>
                <button id="btn-close-place-modal" class="modal-close" type="button" aria-label="Close place dialog">&times;</button>
            </div>
            <div class="modal-body">
                <div id="place-error-box" class="alert-inline alert-danger hidden" role="alert"></div>
                <form id="place-form" novalidate>
                    <input id="place-id-input" type="hidden" value="">
                    <label class="field-label" for="place-name-input">Place Name</label>
                    <input id="place-name-input" class="code-input" type="text" maxlength="64" placeholder="Home" required>

                    <label class="field-label" for="place-category-select">Category</label>
                    <select id="place-category-select" class="map-provider-select place-select-full">
                        <option value="home">Home (Enables At-Home Battery &amp; Privacy Mode)</option>
                        <option value="school">School</option>
                        <option value="work">Work</option>
                        <option value="custom">Custom Place</option>
                    </select>

                    <div class="code-input-row">
                        <div class="place-coord-col">
                            <label class="field-label" for="place-lat-input">Latitude</label>
                            <input id="place-lat-input" class="code-input" type="number" step="any" required>
                        </div>
                        <div class="place-coord-col">
                            <label class="field-label" for="place-lng-input">Longitude</label>
                            <input id="place-lng-input" class="code-input" type="number" step="any" required>
                        </div>
                    </div>

                    <div class="place-coord-actions">
                        <button id="btn-pick-place-on-map" class="btn btn-secondary btn-sm" type="button">Pick on Map</button>
                        <button id="btn-use-selected-device-coords" class="btn btn-secondary btn-sm" type="button">Use Selected Phone</button>
                    </div>

                    <label class="field-label" for="place-radius-input">Geofence Radius (meters): <span id="place-radius-label">150</span>m</label>
                    <input id="place-radius-input" class="place-radius-slider" type="range" min="50" max="1000" step="25" value="150">

                    <div class="place-notify-row">
                        <label><input id="place-notify-enter" type="checkbox" checked> Alert on Arrive</label>
                        <label><input id="place-notify-exit" type="checkbox" checked> Alert on Leave</label>
                    </div>

                    <button id="btn-save-place" class="btn btn-primary btn-full" type="submit">Save Place</button>
                </form>
            </div>
        </div>
    </div>

    <script src="assets/js/map.js"></script>
    <script src="assets/js/app.js"></script>
</body>
</html>
