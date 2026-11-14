<?php
/**
 * LocaShare - Environment Variable Loader
 *
 * Reads configuration from environment variables and an optional .env file
 * in backend/.env or repository root .env.
 */

class Env
{
    private static bool $loaded = false;
    private static array $values = [];

    /**
     * Load environment variables from .env files if present.
     */
    public static function load(?string $customEnvPath = null): void
    {
        if (self::$loaded && $customEnvPath === null) {
            return;
        }

        $candidates = [];
        if ($customEnvPath !== null) {
            $candidates[] = $customEnvPath;
        } else {
            $candidates[] = dirname(__DIR__) . DIRECTORY_SEPARATOR . '.env';
            $candidates[] = dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . '.env';
        }

        foreach ($candidates as $path) {
            if (is_file($path) && is_readable($path)) {
                self::parseFile($path);
                break;
            }
        }

        self::$loaded = true;
    }

    /**
     * Reset loaded state (used by automated tests).
     */
    public static function reset(): void
    {
        self::$loaded = false;
        self::$values = [];
    }

    /**
     * Get a string environment variable with optional default.
     */
    public static function get(string $key, mixed $default = null): mixed
    {
        self::load();

        if (array_key_exists($key, $_ENV)) {
            return $_ENV[$key];
        }
        if (array_key_exists($key, $_SERVER) && is_scalar($_SERVER[$key])) {
            return (string) $_SERVER[$key];
        }
        $envVal = getenv($key);
        if ($envVal !== false) {
            return $envVal;
        }
        if (array_key_exists($key, self::$values)) {
            return self::$values[$key];
        }

        return $default;
    }

    /**
     * Check whether an environment variable was explicitly provided.
     */
    public static function has(string $key): bool
    {
        self::load();

        return array_key_exists($key, $_ENV)
            || (array_key_exists($key, $_SERVER) && is_scalar($_SERVER[$key]))
            || getenv($key) !== false
            || array_key_exists($key, self::$values);
    }

    /**
     * Get an integer environment variable.
     */
    public static function int(string $key, int $default = 0): int
    {
        $val = self::get($key, null);
        if ($val === null || $val === '') {
            return $default;
        }
        if (is_numeric($val)) {
            return (int) $val;
        }
        return $default;
    }

    /**
     * Get a boolean environment variable.
     */
    public static function bool(string $key, bool $default = false): bool
    {
        $val = self::get($key, null);
        if ($val === null || $val === '') {
            return $default;
        }
        if (is_bool($val)) {
            return $val;
        }
        $normalized = strtolower(trim((string) $val));
        if (in_array($normalized, ['1', 'true', 'yes', 'on'], true)) {
            return true;
        }
        if (in_array($normalized, ['0', 'false', 'no', 'off'], true)) {
            return false;
        }
        return $default;
    }

    /**
     * Get a comma-separated environment variable as a list of non-empty strings.
     */
    public static function csv(string $key, array $default = []): array
    {
        $val = self::get($key, null);
        if ($val === null || trim((string) $val) === '') {
            return $default;
        }
        $parts = array_map('trim', explode(',', (string) $val));
        return array_values(array_filter($parts, static fn(string $item): bool => $item !== ''));
    }

    /**
     * Parse a simple KEY=VALUE .env file.
     */
    private static function parseFile(string $filePath): void
    {
        $lines = @file($filePath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!is_array($lines)) {
            return;
        }

        foreach ($lines as $line) {
            $trimmed = trim($line);
            if ($trimmed === '' || str_starts_with($trimmed, '#')) {
                continue;
            }
            if (str_starts_with($trimmed, 'export ')) {
                $trimmed = trim(substr($trimmed, 7));
            }
            $eqPos = strpos($trimmed, '=');
            if ($eqPos === false) {
                continue;
            }
            $name = trim(substr($trimmed, 0, $eqPos));
            $value = trim(substr($trimmed, $eqPos + 1));

            if ($name === '') {
                continue;
            }

            if (
                (str_starts_with($value, '"') && str_ends_with($value, '"')) ||
                (str_starts_with($value, "'") && str_ends_with($value, "'"))
            ) {
                $value = substr($value, 1, -1);
            } else {
                $commentPos = strpos($value, ' #');
                if ($commentPos !== false) {
                    $value = rtrim(substr($value, 0, $commentPos));
                }
            }

            self::$values[$name] = $value;
        }
    }
}
