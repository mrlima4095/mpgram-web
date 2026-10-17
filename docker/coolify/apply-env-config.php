<?php
/**
 * Gera api_values.php e config.php a partir de variáveis de ambiente.
 *
 * - api_values.php é criado apenas se não existir (usa API_ID / API_HASH).
 * - config.php é copiado de config.php.example e, em seguida, os define()
 *   listados abaixo são sobrescritos quando a variável de ambiente existir.
 *
 * Arquivos já existentes nunca são sobrescritos, então você também pode
 * versionar seu próprio config.php/api_values.php se preferir.
 */

$root = getenv('APP_ROOT') ?: '/var/www/html';

/* ----------------------------- api_values.php ----------------------------- */
$apiFile = $root . '/api_values.php';
if (!file_exists($apiFile)) {
    $id   = (int) (getenv('API_ID') ?: 0);
    $hash = (string) (getenv('API_HASH') ?: '');
    file_put_contents(
        $apiFile,
        "<?php\n"
        . "define('api_id', {$id});\n"
        . "define('api_hash', '" . addslashes($hash) . "');\n"
    );
    echo "[mpgram] api_values.php gerado (api_id={$id})\n";
    if ($id === 0 || $hash === '') {
        echo "[mpgram] AVISO: defina API_ID e API_HASH no Coolify, senão o login não funciona!\n";
    }
}

/* ------------------------------- config.php ------------------------------- */
$configFile = $root . '/config.php';
if (!file_exists($configFile)) {
    copy($root . '/config.php.example', $configFile);
    echo "[mpgram] config.php criado a partir do exemplo\n";
}

$bools = [
    'LOGIN_CAPTCHA', 'FORCE_HTTPS', 'CHROME_HTTPS', 'FILE_REWRITE',
    'CONVERT_VOICE_MESSAGES', 'CONVERT_TGS_STICKERS', 'LOTTIE_TO_GIF',
    'ENABLE_API', 'ENABLE_LOGIN_API', 'ENABLE_PEER_DB',
];
$ints = [
    'DOWNLOAD_SIZE_LIMIT', 'IMAGE_SIZE_LIMIT', 'UPLOAD_SIZE_LIMIT',
    'LOGIN_REQUESTS_BY_IP', 'LOGIN_TOTAL_DAILY_LIMIT',
];
$strings = ['sessionspath', 'VOICE_TMP_DIR', 'FFMPEG_DIR', 'LOTTIE_DIR', 'TGS_TMP_DIR'];

$replacements = [];

foreach ($bools as $key) {
    $v = getenv($key);
    if ($v === false || $v === '') {
        continue;
    }
    $replacements[$key] = filter_var($v, FILTER_VALIDATE_BOOLEAN) ? 'true' : 'false';
}

foreach ($ints as $key) {
    $v = getenv($key);
    if ($v === false || $v === '') {
        continue;
    }
    $replacements[$key] = (string) (int) $v;
}

foreach ($strings as $key) {
    $v = getenv($key);
    if ($v === false || $v === '') {
        continue;
    }
    $replacements[$key] = "'" . addslashes($v) . "'";
}

// INSTANCE_PASSWORD: vazio ou "null" desativa a senha da instância
$ip = getenv('INSTANCE_PASSWORD');
if ($ip !== false) {
    $replacements['INSTANCE_PASSWORD'] = ($ip === '' || strtolower($ip) === 'null')
        ? 'null'
        : "'" . addslashes($ip) . "'";
}

$contents = file_get_contents($configFile);

foreach ($replacements as $key => $value) {
    $pattern = "/^define\('" . preg_quote($key, '/') . "',.*\);\s*$/m";
    $line    = "define('{$key}', {$value});";
    if (preg_match($pattern, $contents)) {
        // callback evita que '$' ou '\' vindos das envs sejam interpretados como backreference
        $contents = preg_replace_callback($pattern, static fn () => $line, $contents, 1);
    } else {
        $contents = rtrim($contents) . "\n" . $line . "\n";
    }
}

// SERVER_NAME vem comentado no exemplo; ativa apenas se a variável existir
$sn = getenv('SERVER_NAME');
if ($sn !== false && $sn !== '') {
    $line = "define('SERVER_NAME', '" . addslashes($sn) . "');";
    if (preg_match("/^\/\/define\('SERVER_NAME'.*$/m", $contents)) {
        $contents = preg_replace_callback("/^\/\/define\('SERVER_NAME'.*$/m", static fn () => $line, $contents, 1);
    } elseif (preg_match("/^define\('SERVER_NAME'.*$/m", $contents)) {
        $contents = preg_replace_callback("/^define\('SERVER_NAME'.*$/m", static fn () => $line, $contents, 1);
    } else {
        $contents = rtrim($contents) . "\n" . $line . "\n";
    }
}

file_put_contents($configFile, $contents);
echo "[mpgram] config.php atualizado\n";
