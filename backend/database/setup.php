<?php
/**
 * LocaShare - Database Setup Utility
 *
 * Initializes the database schema for either SQLite or MySQL/MariaDB.
 * Usage:
 *   php backend/database/setup.php
 */

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    header('Content-Type: application/json');
    echo json_encode(['success' => false, 'error' => 'CLI execution only.']);
    exit(1);
}

require_once __DIR__ . '/../includes/Database.php';

try {
    $pdo = Database::getConnection();
    $driver = Database::getDriver();
    Database::initializeSchema($pdo);
    echo "[LocaShare] Database schema initialized successfully (driver: {$driver})." . PHP_EOL;
    exit(0);
} catch (Throwable $e) {
    fwrite(STDERR, "[LocaShare] Database setup error: " . $e->getMessage() . PHP_EOL);
    exit(1);
}
