<?php
/**
 * LocaShare Backend Root Entry Point
 *
 * Redirects visitors to the Laptop Web Dashboard with a trailing slash so
 * relative asset and API URLs resolve consistently on any deployment path.
 */

declare(strict_types=1);

header('Location: dashboard/', true, 302);
exit;
