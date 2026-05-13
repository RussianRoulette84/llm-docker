<?php
// Minimal entry point — the kind of dev server `php -S 0.0.0.0:8000 -t public`
// spins up via llm-docker's `/run` endpoint. Bind to 0.0.0.0 so the Docker
// container can reach the host via host.docker.internal:8000.

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?? '/';
header('Content-Type: application/json');

switch ($path) {
    case '/':
        echo json_encode(['hello' => 'from php-example', 'stack' => 'php-builtin']);
        break;
    case '/health':
        echo json_encode(['ok' => true]);
        break;
    default:
        http_response_code(404);
        echo json_encode(['error' => 'not_found', 'path' => $path]);
}
