# LocaShare

**LocaShare** is a privacy-first, owner-controlled Android phone location-sharing app with a responsive laptop web dashboard and PHP backend.

A phone owner can tap **“Register this device”** in the Android app—without creating an account, username, password, or email login—and pair the phone to a laptop browser using a short-lived, single-use pairing code or QR code. Once paired and after the owner explicitly grants location permission and taps **“Start sharing”**, the phone appears in the laptop dashboard's device list and interactive map over either Wi-Fi or mobile data.

---

## Architecture & Repository Layout

```text
locashare/
├── README.md
├── .gitignore
├── backend/
│   ├── .env.example                 # Environment variable template (no real credentials)
│   ├── .htaccess                    # Apache rewrite & directory protection rules
│   ├── index.php                    # Root entry point (loads dashboard)
│   ├── router.php                   # Built-in PHP server router
│   ├── config/
│   │   └── app.php                  # Environment-driven configuration
│   ├── database/
│   │   ├── schema.sql               # MySQL / MariaDB schema
│   │   ├── seed.sql                 # Schema initialization notes
│   │   └── setup.php                # CLI database initializer (SQLite & MySQL)
│   ├── includes/
│   │   ├── Env.php                  # .env & environment variable loader
│   │   ├── Database.php             # PDO connection manager (SQLite & MySQL)
│   │   ├── Security.php             # CSPRNG tokens/codes, validation & redacted logging
│   │   ├── Auth.php                 # Per-device Bearer auth & HttpOnly session/CSRF auth
│   │   ├── RateLimiter.php          # Bucketed rate limiter (api, register, pair)
│   │   ├── Response.php             # Standardized JSON responses & security headers
│   │   └── DeviceService.php        # Core registration, pairing, heartbeat & location logic
│   ├── api/
│   │   ├── device/
│   │   │   ├── register.php         # POST /api/device/register
│   │   │   ├── pairing-code.php     # POST /api/device/pairing-code
│   │   │   ├── heartbeat.php        # POST /api/device/heartbeat
│   │   │   ├── status.php           # GET  /api/device/status
│   │   │   ├── unpair.php           # POST /api/device/unpair
│   │   │   └── unregister.php       # POST /api/device/unregister
│   │   ├── location/
│   │   │   ├── update.php           # POST /api/location/update
│   │   │   ├── latest.php           # GET  /api/location/latest
│   │   │   └── delete.php           # POST /api/location/delete
│   │   └── dashboard/
│   │       ├── session.php          # GET  /api/dashboard/session
│   │       ├── pair.php             # POST /api/dashboard/pair
│   │       ├── devices.php          # GET  /api/dashboard/devices
│   │       └── unpair.php           # POST /api/dashboard/unpair
│   ├── dashboard/
│   │   ├── index.php                # Laptop web dashboard
│   │   └── assets/
│   │       ├── css/dashboard.css    # Responsive styles
│   │       └── js/
│   │           ├── map.js           # Interactive map controller (Privacy Grid + OSM tiles)
│   │           └── app.js           # Dashboard state, polling, pairing & QR scanner
│   └── tests/
│       └── run_tests.php            # Automated backend security & integration test suite
└── android/
    ├── build.gradle.kts
    ├── settings.gradle.kts
    └── app/
        ├── build.gradle.kts
        └── src/
            ├── main/
            │   ├── AndroidManifest.xml
            │   ├── java/com/locashare/app/
            │   │   ├── model/TrackingState.kt
            │   │   ├── storage/LocaSharePreferences.kt
            │   │   ├── storage/OfflineLocationStore.kt
            │   │   ├── util/PairingQrGenerator.kt
            │   │   ├── network/LocaShareApiClient.kt
            │   │   ├── service/LocationSharingService.kt
            │   │   └── ui/MainActivity.kt
            │   └── res/
            └── test/java/com/locashare/app/
                └── LocaShareUnitTest.kt
```

---

## Backend & Laptop Dashboard Setup

### Prerequisites
- **PHP 8.1+** with `pdo_sqlite` (zero-config default) or `pdo_mysql` (MySQL/MariaDB), `openssl`, `json`, and `mbstring`.

### 1. Configure Environment Variables
Copy `backend/.env.example` to `backend/.env` and customize as needed:
```powershell
Copy-Item backend\.env.example backend\.env
```
Key environment variables:
- `LOCASHARE_DB_DRIVER`: `sqlite` (default zero-config single-file DB at `backend/database/locashare.sqlite`) or `mysql` (MySQL/MariaDB).
- `LOCASHARE_DB_HOST`, `LOCASHARE_DB_PORT`, `LOCASHARE_DB_NAME`, `LOCASHARE_DB_USER`, `LOCASHARE_DB_PASSWORD`: Database connection settings when `LOCASHARE_DB_DRIVER=mysql`.
- `LOCASHARE_PAIRING_TTL_SECONDS`: One-time pairing code lifetime in seconds (default `300` = 5 minutes).
- `LOCASHARE_ONLINE_THRESHOLD_SECONDS`: Phone heartbeat freshness window in seconds (default `90`).
- `LOCASHARE_LOCATION_STALE_SECONDS`: Location-fix freshness window in seconds (default `180`).
- `LOCASHARE_COOKIE_SECURE`: `auto` (enables `Secure` cookie flag automatically over HTTPS), `true` (recommended in production HTTPS deployments), or `false`.

### 2. Initialize the Database
Run the CLI setup script (creates tables for SQLite or MySQL/MariaDB):
```powershell
php backend/database/setup.php
```
*(For MySQL/MariaDB, you can also import `backend/database/schema.sql` directly.)*

### 3. Run the Backend & Web Dashboard Locally
Using PHP’s built-in server:
```powershell
php -S 127.0.0.1:8080 -t backend backend/router.php
```
Then open `http://127.0.0.1:8080` in your laptop browser.

### 4. Run Backend Automated Tests
```powershell
php backend/tests/run_tests.php
```

---

## Android App Setup & Build

### Prerequisites
- **JDK 17+**
- **Android SDK** (API 35 / 36)

### Building the APK & Running Unit Tests
From the `locashare/android` directory:
```powershell
cd android
.\gradlew.bat testDebugUnitTest assembleDebug
```
The compiled debug APK is generated at `android/app/build/outputs/apk/debug/app-debug.apk`.

---

## Deployment for Tracking Away from the Laptop (Wi-Fi & Mobile Data)

> **Important Requirement for Remote Tracking:**
> Tracking a phone when it is away from the laptop’s local Wi-Fi network (for example, on mobile data or a different Wi-Fi network) **requires deploying the backend to a public HTTPS URL** reachable by both the Android phone and the laptop browser.

1. Deploy the `backend/` directory behind an HTTPS web server (Apache with `mod_rewrite` enabled or Nginx + PHP-FPM) with a valid TLS certificate (e.g., Let’s Encrypt, Cloudflare Tunnel, Tailscale Funnel, or a cloud VPS).
2. Set `LOCASHARE_COOKIE_SECURE=true` in `backend/.env` so dashboard session cookies are transmitted exclusively over HTTPS.
3. In the Android app’s **Backend Server Address** field, enter your public `https://...` URL and tap **Save Server URL**.
   - Note: The Android app enforces `https://` for all remote hosts (`network_security_config.xml` and `ServerUrlValidator`) so bearer tokens, pairing codes, and coordinates are never sent in cleartext over public networks. Cleartext `http://` is permitted only for `10.0.2.2` / `localhost` / `127.0.0.1` during local development.

---

## Pairing & Usage Flow

1. **Register on the Phone (No Login Required)**:
   - Open the **LocaShare** Android app.
   - Verify the **Backend Server Address** (`https://your-domain.example.com` or `http://10.0.2.2:8080` on the Android Emulator).
   - Enter an optional device label (e.g., `My Pixel 8`) and tap **“Register this device”**.
   - The phone displays an 8-character **one-time pairing code** (`XXXX-XXXX`), a **scannable QR code**, and a 5-minute countdown timer.
2. **Pair on the Laptop Dashboard**:
   - Open the laptop web dashboard and click **“+ Pair Phone”**.
   - Enter the 8-character pairing code or click **“Scan with Laptop Camera”** / **“Scan QR from Image”**.
   - The pairing code is single-use and immediately invalidated once consumed.
3. **Grant Location Permission & Start Sharing**:
   - On the phone, tap **“Grant Location Permission”** (or **“Start sharing”**) to review the permission explanation and grant Android location permission.
   - Tap **“Start sharing”**.
   - An Android **Foreground Location Service** starts and displays a persistent notification (`LocaShare: Sharing Location`) with an immediate **“Stop Sharing”** action button.
4. **View Live Location & Honest Status on the Dashboard**:
   - Select any paired phone in the left sidebar to inspect its telemetry and center the map on its position.
   - **Heartbeat vs. Location-Fix Separation**: The dashboard tracks `last_heartbeat_at` (whether the phone is online) separately from `location_recorded_at` (when the GPS/network coordinates were actually captured). If a phone checks in recently but its GPS fix is older than `LOCASHARE_LOCATION_STALE_SECONDS`, the dashboard badges the coordinates as **Stale Fix** rather than labeling an old fix as current.
   - **Offline Queue (Newest Point Only)**: If the phone loses connectivity while sharing, it stores or replaces a single pending location fix with the newest coordinates (`OfflineLocationStore`) and uploads that newest point as soon as connectivity returns—never flooding the server with old historical points.
5. **Stop Sharing, Revoke Pairing, or Delete Data**:
   - Tap **“Stop sharing”** in the app or in the persistent Android notification to pause location sharing immediately.
   - Tap **“Revoke dashboard pairing”** to invalidate laptop dashboard access immediately (the laptop dashboard displays a revocation notice and can no longer read the phone).
   - Tap **“Delete stored location”** (on either the phone or paired dashboard) to wipe the stored coordinates from the database.
   - Tap **“Unregister this device”** on the phone to revoke its device token, unpair all dashboards, and delete all stored location data.

---

## Privacy, Security & Map Data Flow

- **Owner Consent & Visibility**: Location is never shared on install or registration alone. Sharing starts only after the phone owner taps **“Start sharing”** and always shows a persistent Android foreground service notification with a **“Stop Sharing”** button.
- **No Stealth Tracking**: LocaShare does not hide its app icon, notification, permissions, or active sharing state, and never supports remote activation without the phone owner’s action.
- **Latest-Only Storage**: By default, the backend stores **only the latest location fix** per device in `device_status` and does not collect route history.
- **Secret Hashing & Access Control**:
  - Device bearer tokens, pairing codes, and dashboard session tokens are hashed with `SHA-256` before persistence; plaintext tokens and pairing codes are never stored in the database or written to logs.
  - Every location write requires the phone's valid per-device Bearer token (`Auth::requireDevice`).
  - Every dashboard read requires a valid `HttpOnly`, `SameSite`, `Secure` session cookie (`locashare_session`) paired to that specific device (`dashboard_device_pairings`), and state-changing dashboard requests require a matching `X-CSRF-Token`.
- **Map Provider Attribution & Coordinate Data Flow**:
  - By default, the laptop dashboard renders in **Local Privacy Grid Mode**, which plots device markers, accuracy circles (in meters), and coordinate graticules on an HTML5 Canvas in your browser with **zero external network requests**.
  - You can optionally toggle **“Load OpenStreetMap Street Tiles”** in the map footer. When enabled, your browser loads standard raster map tiles (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`) for the visible viewport from **OpenStreetMap** ([© OpenStreetMap contributors](https://www.openstreetmap.org/copyright), [OSM Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/)). Marker plotting and accuracy circles always stay local in your browser; exact device coordinates are never sent to any third-party geocoding or analytics service.

---

## Troubleshooting

| Symptom | Cause & Resolution |
| --- | --- |
| **“This pairing code has expired” (`CODE_EXPIRED`)** | Pairing codes expire after 5 minutes (`LOCASHARE_PAIRING_TTL_SECONDS`). Tap **“New pairing code”** in the Android app and enter the new code on the dashboard. |
| **“This pairing code has already been used” (`CODE_ALREADY_USED`)** | Each pairing code is single-use. To pair an additional browser or re-pair, tap **“New pairing code”** on the phone. |
| **Phone works on home Wi-Fi but shows “Offline” on mobile data** | Your backend URL is likely set to a local/private address (`10.0.2.2`, `127.0.0.1`, or `192.168.x.x`). Deploy the backend to a public `https://` domain reachable from mobile networks and update the **Backend Server Address** in the Android app. |
| **Dashboard shows “Phone Online” with “Stale Fix”** | The phone has network connectivity (sending heartbeats), but has not acquired a new GPS fix recently (e.g., indoors with weak satellite signal). Move to an area with a clearer view of the sky. |
| **Dashboard shows “Location Permission Missing”** | Location permission was denied or revoked in Android Settings. Open the LocaShare app on the phone, tap **“Grant Location Permission”**, and tap **“Start sharing”**. |
