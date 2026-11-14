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

header('Content-Type: text/html; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: no-referrer');
header('Cache-Control: no-store, no-cache, must-revalidate, private');
header('Pragma: no-cache');
header(
    "Content-Security-Policy: "
    . "default-src 'self'; "
    . "script-src 'self'; "
    . "style-src 'self'; "
    . "img-src 'self' data: blob: https://tile.openstreetmap.org; "
    . "connect-src 'self'; "
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
                <button id="btn-refresh-now" class="btn btn-secondary btn-sm" type="button">
                    Refresh Now
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
            </aside>

            <section class="map-stage" aria-label="Interactive device map">
                <div id="map-viewport" class="map-viewport">
                    <div id="map-canvas" class="map-canvas"></div>
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
                        <label class="toggle-label">
                            <input id="chk-osm-tiles" type="checkbox" checked>
                            <span>Load OpenStreetMap background tiles</span>
                        </label>
                        <span id="tile-mode-badge" class="badge badge-privacy">
                            OpenStreetMap Tiles Active (tile.openstreetmap.org)
                        </span>
                    </div>
                    <div class="map-attribution">
                        Map data:
                        <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">
                            &copy; OpenStreetMap contributors
                        </a>
                        &middot;
                        <strong>Privacy notice:</strong> Only visible map tile indices (<code>z/x/y</code>) are requested from
                        <code>tile.openstreetmap.org</code>; exact coordinates and tokens never leave your LocaShare server.
                        Uncheck above for Local Privacy Grid mode (0 external requests).
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

    <script src="assets/js/map.js"></script>
    <script src="assets/js/app.js"></script>
</body>
</html>
