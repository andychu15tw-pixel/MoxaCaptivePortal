<?php
/*
 * /etc/chilli/www/index.php — captive portal landing redirect.
 *
 * CoovaChilli redirects unauth clients to:
 *   http://uamlisten/?loginurl=<URL-encoded portal URL>
 * expecting its own internal miniweb to handle. Apache owns port 80 here,
 * so this tiny script decodes the loginurl param and 302-redirects.
 *
 * If no loginurl param present, send to default portal entry.
 */

$target = $_GET['loginurl'] ?? '/cgi-bin/hotspotlogin.cgi';

// Basic safety: only allow http(s) URLs to this host or relative paths.
if (preg_match('#^https?://#i', $target)) {
    $host = parse_url($target, PHP_URL_HOST);
    $allowed = ['192.168.182.1', $_SERVER['HTTP_HOST'] ?? ''];
    if (!in_array($host, $allowed, true)) {
        http_response_code(400);
        echo "Invalid loginurl host";
        exit;
    }
}

header('Cache-Control: no-store');
header('Location: ' . $target, true, 302);
exit;
