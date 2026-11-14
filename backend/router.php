<?php
/**
 * LocaShare - Built-in PHP Server Router
 *
 * Usage:
 *   php -S 127.0.0.1:8080 -t backend backend/router.php
 */

$uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$backendRoot = __DIR__;

// Block direct HTTP access to internal directories and sensitive files
if (preg_match('#^/(config|database|includes|logs|tests)(/|$)#i', $uri) || str_starts_with(basename($uri), '.')) {
    http_response_code(403);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => false, 'error' => 'Forbidden']);
    return true;
}

// Root or /dashboard -> dashboard/index.php
if ($uri === '/' || $uri === '/dashboard' || $uri === '/dashboard/') {
    require $backendRoot . '/dashboard/index.php';
    return true;
}

// Serve static files in dashboard/assets or direct existing files
$candidatePath = realpath($backendRoot . $uri);
if ($candidatePath !== false && str_starts_with($candidatePath, realpath($backendRoot)) && is_file($candidatePath)) {
    if (str_ends_with(strtolower($candidatePath), '.php')) {
        require $candidatePath;
        return true;
    }
    return false; // Let PHP built-in server serve static asset
}

// Support extensionless API endpoints (e.g., /api/device/register -> /api/device/register.php)
$phpCandidate = $backendRoot . rtrim($uri, '/') . '.php';
if (is_file($phpCandidate)) {
    require $phpCandidate;
    return true;
}

http_response_code(404);
header('Content-Type: application/json; charset=utf-8');
echo json_encode(['success' => false, 'error' => 'Endpoint not found.']);
return true;
