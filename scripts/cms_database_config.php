<?php

// Read Joomla configuration as data. Never include or evaluate a site's PHP code.
// Usage:
//   php cms_database_config.php inspect CONFIG
//   php cms_database_config.php update CONFIG HASH USER DB HOST < password-without-LF
// inspect writes: db<TAB>user<TAB>host<TAB>sha256. update is silent on success.

ini_set('display_errors', '0');
ini_set('log_errors', '0');
set_error_handler(function () {
    return true;
});

class RishConfigException extends RuntimeException
{
}

function rishConfigFail($message)
{
    throw new RishConfigException($message);
}

function rishConfigStat($path)
{
    clearstatcache(true, $path);
    return lstat($path);
}

function rishConfigSameStat($left, $right)
{
    if (!is_array($left) || !is_array($right)) {
        return false;
    }
    foreach (array('dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtime', 'ctime') as $key) {
        if ($left[$key] !== $right[$key]) {
            return false;
        }
    }
    return true;
}

function rishConfigRegularFile($stat)
{
    return is_array($stat) && ($stat['mode'] & 0170000) === 0100000 && $stat['nlink'] === 1;
}

function rishConfigPath($path)
{
    if (!is_string($path) || $path === '' || $path[0] !== '/' || preg_match('/[\x00-\x1f\x7f]/', $path)) {
        rishConfigFail('Недопустимый путь к конфигурации.');
    }
    $stat = rishConfigStat($path);
    if (!rishConfigRegularFile($stat) || realpath($path) !== $path) {
        rishConfigFail('Конфигурация должна быть обычным файлом без ссылок по каноническому пути.');
    }
    $directory = dirname($path);
    if (realpath($directory) !== $directory || !is_writable($directory)) {
        rishConfigFail('Каталог конфигурации недоступен для безопасной записи.');
    }
    return $stat;
}

function rishConfigStaging($sourceStat, $create)
{
    // Metadata operations must never follow a pathname in a site user's
    // writable directory. Keep both prepared files under a root-only parent
    // on the same filesystem, then rename them into the pinned target cwd.
    $parent = '/var/www';
    $current = '';
    foreach (array_merge(array(''), explode('/', trim($parent, '/'))) as $part) {
        $current = $part === '' ? '/' : rtrim($current, '/') . '/' . $part;
        $stat = rishConfigStat($current);
        if (!is_array($stat) || ($stat['mode'] & 0170000) !== 0040000 ||
            $stat['uid'] !== 0 || $stat['gid'] !== 0 || ($stat['mode'] & 0022) !== 0 || realpath($current) !== $current) {
            rishConfigFail('Нужен защищённый каталог /var/www root:root без ссылок и записи для группы или остальных.');
        }
    }
    if ($stat['dev'] !== $sourceStat['dev'] || !is_writable($parent)) {
        rishConfigFail('Безопасная атомарная запись требует доступного root каталога /var/www на той же файловой системе.');
    }
    $directory = $parent . '/.rish-db-config-root';
    $stat = rishConfigStat($directory);
    if ($stat === false && !$create) {
        return $directory;
    }
    if ($stat === false) {
        $oldMask = umask(0077);
        try {
            $created = mkdir($directory, 0700);
        } finally {
            umask($oldMask);
        }
        if (!$created) {
            rishConfigFail('Не удалось создать закрытый staging-каталог конфигураций.');
        }
        $stat = rishConfigStat($directory);
    }
    if (!is_array($stat) || ($stat['mode'] & 0170000) !== 0040000 ||
        $stat['uid'] !== 0 || $stat['gid'] !== 0 || ($stat['mode'] & 07777) !== 0700 ||
        $stat['dev'] !== $sourceStat['dev'] || realpath($directory) !== $directory) {
        rishConfigFail('Staging-каталог конфигураций должен принадлежать root:root и иметь права 700 без ссылок.');
    }
    return $directory;
}

function rishConfigRead($handle)
{
    if (!rewind($handle)) {
        rishConfigFail('Не удалось прочитать конфигурацию.');
    }
    $source = stream_get_contents($handle, 8388609);
    if ($source === false || strlen($source) > 8388608 || !feof($handle)) {
        rishConfigFail('Не удалось прочитать конфигурацию допустимого размера.');
    }
    return $source;
}

function rishConfigUnchanged($path, $handle, $stat, $source)
{
    if (realpath($path) !== $path || realpath(dirname($path)) !== dirname($path) ||
        !rishConfigSameStat($stat, rishConfigStat($path)) ||
        !rishConfigSameStat($stat, fstat($handle)) ||
        !hash_equals(hash('sha256', $source), hash('sha256', rishConfigRead($handle))) ||
        !rishConfigSameStat($stat, rishConfigStat($path)) ||
        !rishConfigSameStat($stat, fstat($handle))) {
        rishConfigFail('Конфигурация была изменена другим процессом; запись отменена.');
    }
}

function rishConfigTokens($source)
{
    if (strncmp($source, "\xef\xbb\xbf", 3) === 0 || preg_match('//u', $source) !== 1) {
        rishConfigFail('Конфигурация должна быть в UTF-8 без BOM.');
    }
    // TOKEN_PARSE omits compiler checks, such as incompatible typed defaults.
    // Lint the bytes through stdin with php.ini disabled; this executes no code
    // from the site, and both diagnostic streams are discarded to hide secrets.
    if (!function_exists('proc_open')) {
        rishConfigFail('Для проверки синтаксиса PHP требуется доступная функция proc_open.');
    }
    $pipes = array();
    $process = proc_open(array(PHP_BINARY, '-n', '-l'), array(
        0 => array('pipe', 'r'),
        1 => array('file', '/dev/null', 'w'),
        2 => array('file', '/dev/null', 'w')
    ), $pipes);
    if (!is_resource($process)) {
        rishConfigFail('Не удалось запустить проверку синтаксиса PHP.');
    }
    $offset = 0;
    while ($offset < strlen($source)) {
        $written = fwrite($pipes[0], substr($source, $offset));
        if ($written === false || $written === 0) {
            break;
        }
        $offset += $written;
    }
    fclose($pipes[0]);
    $status = proc_close($process);
    if ($status !== 0 || $offset !== strlen($source)) {
        rishConfigFail('В конфигурации обнаружена ошибка PHP.');
    }
    try {
        $raw = token_get_all($source, TOKEN_PARSE);
    } catch (Throwable $error) {
        rishConfigFail('В конфигурации обнаружена синтаксическая ошибка PHP.');
    }
    $tokens = array();
    $offset = 0;
    foreach ($raw as $token) {
        $id = is_array($token) ? $token[0] : null;
        $text = is_array($token) ? $token[1] : $token;
        if (!in_array($id, array(T_WHITESPACE, T_COMMENT, T_DOC_COMMENT), true)) {
            $tokens[] = array('id' => $id, 'text' => $text, 'offset' => $offset);
        }
        $offset += strlen($text);
    }
    return $tokens;
}

function rishConfigUnicode($number)
{
    if ($number > 0x10ffff || ($number >= 0xd800 && $number <= 0xdfff)) {
        rishConfigFail('Недопустимый строковый литерал в конфигурации.');
    }
    if ($number <= 0x7f) {
        return chr($number);
    }
    if ($number <= 0x7ff) {
        return chr(0xc0 | ($number >> 6)) . chr(0x80 | ($number & 0x3f));
    }
    if ($number <= 0xffff) {
        return chr(0xe0 | ($number >> 12)) . chr(0x80 | (($number >> 6) & 0x3f)) . chr(0x80 | ($number & 0x3f));
    }
    return chr(0xf0 | ($number >> 18)) . chr(0x80 | (($number >> 12) & 0x3f)) .
        chr(0x80 | (($number >> 6) & 0x3f)) . chr(0x80 | ($number & 0x3f));
}

function rishConfigString($literal)
{
    if ($literal[0] === 'b' || $literal[0] === 'B') {
        $literal = substr($literal, 1);
    }
    $quote = $literal[0];
    if (($quote !== "'" && $quote !== '"') || substr($literal, -1) !== $quote) {
        rishConfigFail('Недопустимый строковый литерал в конфигурации.');
    }
    $text = substr($literal, 1, -1);
    $value = '';
    $escapes = array('n' => "\n", 'r' => "\r", 't' => "\t", 'v' => "\v", 'e' => "\x1b", 'f' => "\f");
    for ($i = 0, $length = strlen($text); $i < $length; $i++) {
        if ($text[$i] !== '\\' || $i + 1 >= $length) {
            $value .= $text[$i];
            continue;
        }
        $next = $text[++$i];
        if ($next === '\\' || $next === $quote || ($quote === '"' && $next === '$')) {
            $value .= $next;
        } elseif ($quote === '"' && isset($escapes[$next])) {
            $value .= $escapes[$next];
        } elseif ($quote === '"' && $next >= '0' && $next <= '7') {
            $digits = $next;
            while (strlen($digits) < 3 && $i + 1 < $length && $text[$i + 1] >= '0' && $text[$i + 1] <= '7') {
                $digits .= $text[++$i];
            }
            $value .= chr(octdec($digits) & 255);
        } elseif ($quote === '"' && $next === 'x' && $i + 1 < $length && ctype_xdigit($text[$i + 1])) {
            $digits = $text[++$i];
            if ($i + 1 < $length && ctype_xdigit($text[$i + 1])) {
                $digits .= $text[++$i];
            }
            $value .= chr(hexdec($digits));
        } elseif ($quote === '"' && $next === 'u' && $i + 1 < $length && $text[$i + 1] === '{') {
            $end = strpos($text, '}', $i + 2);
            if ($end === false) {
                rishConfigFail('Недопустимый строковый литерал в конфигурации.');
            }
            $digits = substr($text, $i + 2, $end - $i - 2);
            if ($digits === '' || !ctype_xdigit($digits) || strlen(ltrim($digits, '0')) > 6) {
                rishConfigFail('Недопустимый строковый литерал в конфигурации.');
            }
            $value .= rishConfigUnicode(hexdec($digits));
            $i = $end;
        } else {
            $value .= '\\' . $next;
        }
    }
    if (preg_match('//u', $value) !== 1) {
        rishConfigFail('Строковые параметры конфигурации должны быть в UTF-8.');
    }
    return $value;
}

function rishConfigProperty($tokens, &$seen, &$fields)
{
    if (!$tokens || $tokens[0]['id'] !== T_VARIABLE) {
        rishConfigFail('Неподдерживаемое объявление свойства JConfig.');
    }
    $name = substr($tokens[0]['text'], 1);
    if (isset($seen[$name])) {
        rishConfigFail('В JConfig найдены повторяющиеся свойства.');
    }
    $seen[$name] = true;
    if (count($tokens) > 1) {
        $position = 2;
        if ($tokens[1]['text'] !== '=' || !rishConfigStaticValue($tokens, $position, 0) || $position !== count($tokens)) {
            rishConfigFail('Поддерживаются только статические строковые, числовые, логические значения, null и массивы JConfig.');
        }
    }
    if (!in_array($name, array('db', 'user', 'host', 'password'), true)) {
        return;
    }
    if (count($tokens) !== 3 || $tokens[1]['text'] !== '=' || $tokens[2]['id'] !== T_CONSTANT_ENCAPSED_STRING) {
        rishConfigFail('Параметры базы JConfig должны быть однозначными строковыми литералами.');
    }
    $fields[$name] = array('value' => rishConfigString($tokens[2]['text']), 'token' => $tokens[2]);
}

function rishConfigStaticValue($tokens, &$position, $depth)
{
    if ($depth > 64 || !isset($tokens[$position])) {
        return false;
    }
    $token = $tokens[$position++];
    if ($token['text'] === '+' || $token['text'] === '-') {
        if (!isset($tokens[$position]) || !in_array($tokens[$position]['id'], array(T_LNUMBER, T_DNUMBER), true)) {
            return false;
        }
        $position++;
        return true;
    }
    if (in_array($token['id'], array(T_LNUMBER, T_DNUMBER, T_CONSTANT_ENCAPSED_STRING), true) ||
        ($token['id'] === T_STRING && in_array(strtolower($token['text']), array('true', 'false', 'null'), true))) {
        return true;
    }
    if ($token['id'] === T_ARRAY) {
        if (!isset($tokens[$position]) || $tokens[$position++]['text'] !== '(') {
            return false;
        }
        $closing = ')';
    } elseif ($token['text'] === '[') {
        $closing = ']';
    } else {
        return false;
    }
    while (isset($tokens[$position]) && $tokens[$position]['text'] !== $closing) {
        if (!rishConfigStaticValue($tokens, $position, $depth + 1)) {
            return false;
        }
        if (isset($tokens[$position]) && $tokens[$position]['id'] === T_DOUBLE_ARROW) {
            $position++;
            if (!rishConfigStaticValue($tokens, $position, $depth + 1)) {
                return false;
            }
        }
        if (isset($tokens[$position]) && $tokens[$position]['text'] === ',') {
            $position++;
        } elseif (!isset($tokens[$position]) || $tokens[$position]['text'] !== $closing) {
            return false;
        }
    }
    if (!isset($tokens[$position]) || $tokens[$position++]['text'] !== $closing) {
        return false;
    }
    return true;
}

function rishConfigParse($source)
{
    $tokens = rishConfigTokens($source);
    $count = count($tokens);
    if ($count < 5 || $tokens[0]['id'] !== T_OPEN_TAG || $tokens[1]['id'] !== T_CLASS ||
        $tokens[2]['id'] !== T_STRING || strcasecmp($tokens[2]['text'], 'JConfig') !== 0 || $tokens[3]['text'] !== '{') {
        rishConfigFail('Поддерживается одна глобальная Joomla JConfig без исполнения кода.');
    }
    $seen = array();
    $fields = array();
    $i = 4;
    while ($i < $count && $tokens[$i]['text'] !== '}') {
        if ($tokens[$i]['id'] !== T_PUBLIC && $tokens[$i]['id'] !== T_VAR) {
            rishConfigFail('Поддерживаются только обычные открытые свойства JConfig без методов и traits.');
        }
        $i++;
        // A property type is syntax checked by TOKEN_PARSE. No static/readonly or methods.
        while ($i < $count && $tokens[$i]['id'] !== T_VARIABLE) {
            $id = $tokens[$i]['id'];
            $text = $tokens[$i]['text'];
            $typeIds = array(T_STRING, T_ARRAY, T_NS_SEPARATOR);
            foreach (array('T_NAME_FULLY_QUALIFIED', 'T_NAME_QUALIFIED', 'T_NAME_RELATIVE') as $typeId) {
                if (defined($typeId)) {
                    $typeIds[] = constant($typeId);
                }
            }
            if (!in_array($id, $typeIds, true) && !in_array($text, array('?', '|', '&', '(', ')'), true)) {
                rishConfigFail('Неподдерживаемое объявление свойства JConfig.');
            }
            $i++;
        }
        $property = array();
        $depth = 0;
        for (; $i < $count; $i++) {
            $token = $tokens[$i];
            $text = $token['text'];
            if ($depth === 0 && ($text === ',' || $text === ';')) {
                rishConfigProperty($property, $seen, $fields);
                $property = array();
                if ($text === ';') {
                    $i++;
                    break;
                }
                continue;
            }
            if (in_array($text, array('(', '[', '{'), true)) {
                $depth++;
            } elseif (in_array($text, array(')', ']', '}'), true)) {
                $depth--;
                if ($depth < 0) {
                    rishConfigFail('Неподдерживаемое объявление свойства JConfig.');
                }
            }
            $property[] = $token;
        }
    }
    if ($i >= $count || $tokens[$i]['text'] !== '}') {
        rishConfigFail('Не удалось определить границы JConfig.');
    }
    $i++;
    if ($i < $count && $tokens[$i]['id'] === T_CLOSE_TAG) {
        $i++;
        if ($i < $count && $tokens[$i]['id'] === T_INLINE_HTML && trim($tokens[$i]['text']) === '') {
            $i++;
        }
    }
    if ($i !== $count) {
        rishConfigFail('Исполняемый код вне JConfig не поддерживается.');
    }
    foreach (array('db', 'user', 'host', 'password') as $name) {
        if (!isset($fields[$name])) {
            rishConfigFail('Не найдены все строковые параметры базы JConfig.');
        }
        if ($name !== 'password' && ($fields[$name]['value'] === '' || preg_match('/[\x00-\x1f\x7f]/', $fields[$name]['value']))) {
            rishConfigFail('Параметры базы JConfig пусты или содержат управляющие символы.');
        }
    }
    return $fields;
}

function rishConfigTemp($directory, &$temporary)
{
    for ($attempt = 0; $attempt < 8; $attempt++) {
        $path = $directory . '/.rish-configuration-' . bin2hex(random_bytes(16)) . '.php';
        $oldMask = umask(0077);
        try {
            $handle = fopen($path, 'x+b');
        } finally {
            umask($oldMask);
        }
        if ($handle !== false) {
            $stat = fstat($handle);
            $temporary[$path] = $stat;
            if (!rishConfigRegularFile($stat) || ($stat['mode'] & 07777) !== 0600) {
                fclose($handle);
                rishConfigFail('Не удалось создать закрытый временный файл PHP.');
            }
            return array($path, $handle);
        }
    }
    rishConfigFail('Не удалось создать закрытый временный файл PHP.');
}

function rishConfigWrite($handle, $content)
{
    $offset = 0;
    $length = strlen($content);
    while ($offset < $length) {
        $written = fwrite($handle, substr($content, $offset));
        if ($written === false || $written === 0) {
            rishConfigFail('Не удалось записать временный файл.');
        }
        $offset += $written;
    }
    if (!fflush($handle) || (function_exists('fsync') && !fsync($handle))) {
        rishConfigFail('Не удалось сохранить временный файл.');
    }
}

function rishConfigOwnership($path, $uid, $gid, $mode)
{
    if (!chown($path, $uid) || !chgrp($path, $gid) || !chmod($path, $mode)) {
        rishConfigFail('Не удалось сохранить владельца и права конфигурации или закрыть резервную копию для root.');
    }
    $stat = rishConfigStat($path);
    if (!rishConfigRegularFile($stat) || $stat['uid'] !== $uid || $stat['gid'] !== $gid || ($stat['mode'] & 07777) !== $mode) {
        rishConfigFail('Не удалось проверить владельца и права временного файла.');
    }
}

function rishConfigSelinux($source, $temporary)
{
    if (PHP_OS_FAMILY !== 'Linux') {
        return;
    }
    $enabled = null;
    foreach (array('/usr/sbin/selinuxenabled', '/sbin/selinuxenabled', '/usr/bin/selinuxenabled') as $binary) {
        if (is_executable($binary)) {
            $enabled = $binary;
            break;
        }
    }
    if ($enabled === null) {
        if (is_dir('/sys/fs/selinux') && is_file('/sys/fs/selinux/enforce')) {
            rishConfigFail('Не удалось проверить SELinux; запись отменена.');
        }
        return;
    }
    if (!function_exists('exec')) {
        rishConfigFail('Не удалось проверить SELinux; запись отменена.');
    }
    $output = array();
    $status = -1;
    exec(escapeshellarg($enabled) . ' 2>/dev/null', $output, $status);
    if ($status === 1) {
        return;
    }
    if ($status !== 0 || !is_executable('/usr/bin/chcon')) {
        rishConfigFail('Не удалось проверить SELinux; запись отменена.');
    }
    if ($temporary === null) {
        return;
    }
    exec('/usr/bin/chcon --reference=' . escapeshellarg($source) . ' -- ' . escapeshellarg($temporary) . ' 2>/dev/null', $output, $status);
    if ($status !== 0) {
        rishConfigFail('Не удалось сохранить контекст SELinux; запись отменена.');
    }
}

$rishConfigHandle = null;
$rishConfigTemporary = array();
$rishConfigBackupWritten = false;
$rishConfigWritten = false;
$rishConfigExit = 0;

try {
    if (PHP_SAPI !== 'cli' || !isset($argv[1]) ||
        !(($argv[1] === 'inspect' && $argc === 3) || ($argv[1] === 'update' && $argc === 7))) {
        rishConfigFail('Использование: inspect CONFIG или update CONFIG HASH USER DB HOST; новый пароль передаётся через stdin без перевода строки.');
    }
    $rishConfigPath = $argv[2];
    $rishConfigStat = rishConfigPath($rishConfigPath);
    $rishConfigStaging = rishConfigStaging($rishConfigStat, false);
    $rishConfigParentStat = rishConfigStat(dirname($rishConfigPath));
    if (!chdir(dirname($rishConfigPath)) || getcwd() !== dirname($rishConfigPath) ||
        !rishConfigSameStat($rishConfigParentStat, rishConfigStat('.'))) {
        rishConfigFail('Каталог конфигурации был изменён; запись отменена.');
    }
    $rishConfigBasename = basename($rishConfigPath);
    $rishConfigHandle = fopen($rishConfigBasename, 'rb');
    if ($rishConfigHandle === false || !flock($rishConfigHandle, ($argv[1] === 'update' ? LOCK_EX : LOCK_SH) | LOCK_NB) ||
        !rishConfigSameStat($rishConfigStat, fstat($rishConfigHandle))) {
        rishConfigFail('Конфигурация недоступна или занята другим процессом.');
    }
    $rishConfigSource = rishConfigRead($rishConfigHandle);
    rishConfigUnchanged($rishConfigPath, $rishConfigHandle, $rishConfigStat, $rishConfigSource);
    $rishConfigFields = rishConfigParse($rishConfigSource);
    rishConfigSelinux($rishConfigPath, null);
    $rishConfigHash = hash('sha256', $rishConfigSource);
    if ($argv[1] === 'inspect') {
        echo $rishConfigFields['db']['value'] . "\t" . $rishConfigFields['user']['value'] . "\t" .
            $rishConfigFields['host']['value'] . "\t" . $rishConfigHash . "\n";
    } else {
        if (!preg_match('/\A[a-f0-9]{64}\z/', $argv[3]) || !hash_equals($rishConfigHash, $argv[3]) ||
            $rishConfigFields['user']['value'] !== $argv[4] || $rishConfigFields['db']['value'] !== $argv[5] ||
            $rishConfigFields['host']['value'] !== $argv[6]) {
            rishConfigFail('Конфигурация или параметры базы изменились после выбора сайта; запись отменена.');
        }
        $rishConfigPassword = stream_get_contents(STDIN, 65537);
        if ($rishConfigPassword === false || $rishConfigPassword === '' || strlen($rishConfigPassword) > 65536 || !feof(STDIN) ||
            preg_match('/[\x00-\x1f\x7f]/', $rishConfigPassword) || preg_match('//u', $rishConfigPassword) !== 1) {
            rishConfigFail('Новый пароль пуст, слишком длинный или содержит недопустимые символы; передайте его через stdin без перевода строки.');
        }
        $rishConfigToken = $rishConfigFields['password']['token'];
        $rishConfigLiteral = "'" . str_replace(array('\\', "'"), array('\\\\', "\\'"), $rishConfigPassword) . "'";
        $rishConfigNew = substr_replace($rishConfigSource, $rishConfigLiteral, $rishConfigToken['offset'], strlen($rishConfigToken['text']));
        $rishConfigVerified = rishConfigParse($rishConfigNew);
        if ($rishConfigVerified['password']['value'] !== $rishConfigPassword) {
            rishConfigFail('Не удалось проверить новый строковый литерал пароля.');
        }
        $rishConfigStaging = rishConfigStaging($rishConfigStat, true);
        list($rishConfigNewPath, $rishConfigNewHandle) = rishConfigTemp($rishConfigStaging, $rishConfigTemporary);
        try {
            rishConfigWrite($rishConfigNewHandle, $rishConfigNew);
        } finally {
            fclose($rishConfigNewHandle);
        }
        list($rishConfigBackupPath, $rishConfigBackupHandle) = rishConfigTemp($rishConfigStaging, $rishConfigTemporary);
        try {
            rishConfigWrite($rishConfigBackupHandle, $rishConfigSource);
        } finally {
            fclose($rishConfigBackupHandle);
        }
        rishConfigOwnership($rishConfigBackupPath, 0, 0, 0600);
        rishConfigSelinux($rishConfigPath, $rishConfigBackupPath);
        rishConfigSelinux($rishConfigPath, $rishConfigNewPath);
        // Temp files are created and written as 0600 with a .php suffix. Restore
        // the original config's metadata only when its complete copy is ready.
        rishConfigOwnership($rishConfigNewPath, $rishConfigStat['uid'], $rishConfigStat['gid'], $rishConfigStat['mode'] & 07777);
        rishConfigUnchanged($rishConfigPath, $rishConfigHandle, $rishConfigStat, $rishConfigSource);
        if (!rename($rishConfigBackupPath, $rishConfigBasename . '.bak.php')) {
            rishConfigFail('Не удалось сохранить резервную копию; конфигурация не изменена.');
        }
        unset($rishConfigTemporary[$rishConfigBackupPath]);
        $rishConfigBackupWritten = true;
        rishConfigUnchanged($rishConfigPath, $rishConfigHandle, $rishConfigStat, $rishConfigSource);
        if (!rename($rishConfigNewPath, $rishConfigBasename)) {
            rishConfigFail('Не удалось атомарно заменить конфигурацию.');
        }
        unset($rishConfigTemporary[$rishConfigNewPath]);
        $rishConfigWritten = true;
    }
} catch (Throwable $error) {
    $message = $error instanceof RishConfigException ? $error->getMessage() : 'Не удалось безопасно обработать конфигурацию.';
    if ($rishConfigBackupWritten && !$rishConfigWritten) {
        $message .= ' Резервная копия уже обновлена; configuration.php не изменён этой операцией.';
    }
    fwrite(STDERR, $message . "\n");
    $rishConfigExit = 1;
} finally {
    if (is_resource($rishConfigHandle)) {
        flock($rishConfigHandle, LOCK_UN);
        fclose($rishConfigHandle);
    }
    foreach ($rishConfigTemporary as $path => $stat) {
        $current = rishConfigStat($path);
        if (is_array($current) && $current['dev'] === $stat['dev'] && $current['ino'] === $stat['ino']) {
            unlink($path);
        }
    }
}

exit($rishConfigExit);
