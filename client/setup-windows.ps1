<#
.SYNOPSIS
    Установка VLESS-Reality VPN на Windows одной командой (sing-box + TUN).
    Полностью поддерживает UDP — нужен для League of Legends и других игр.

.DESCRIPTION
    Скрипт сам скачивает sing-box, ставит драйвер wintun, генерирует конфиг из
    строки vless://, проверяет его, регистрирует службу (задача планировщика
    с автозапуском от SYSTEM) и поднимает туннель.

    Требуются права администратора (для TUN-режима).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-windows.ps1 -Link "vless://uuid@1.2.3.4:443?..."
.EXAMPLE
    # проверить работу без TUN (не нужен админ, SOCKS5 на 127.0.0.1:2080)
    powershell -ExecutionPolicy Bypass -File setup-windows.ps1 -Link "vless://..." -Mode socks
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Link,                                  # vless://... (или путь к файлу со ссылкой)
    [ValidateSet('tun','socks')][string]$Mode = 'tun',
    [string]$InstallDir = "$env:ProgramFiles\sing-box",
    [string]$DataDir = "$env:ProgramData\sing-box",
    [string]$Version = '1.14.2',
    [int]$SocksPort = 2080,
    [int]$Mtu = 1500,
    [string]$WintunPath,                            # свой путь к wintun.dll (если есть локально)
    [switch]$UdpOverTcp,                            # для Shadowsocks: UDP внутри TCP (если провайдер режет UDP)
    [switch]$OnlyGames,                             # проксировать только процессы Riot/LoL
    [switch]$NoStrictRoute,
    [switch]$NoAutoStart,
    [switch]$Uninstall,
    [switch]$Restart,
    [switch]$ShowLog,
    [switch]$CheckOnly                              # только собрать и проверить конфиг, без запуска
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TaskName = 'sing-box VPN'
$ConfigPath = Join-Path $DataDir 'config.json'
$LogPath    = Join-Path $DataDir 'sing-box.log'
$ExePath    = Join-Path $InstallDir 'sing-box.exe'

function Say  ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn2($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- самоподъём прав для TUN-режима -----------------------------------------
if (-not $Uninstall -and -not $CheckOnly -and $Mode -eq 'tun' -and -not (Test-Admin)) {
    Say 'Нужны права администратора — перезапускаю с UAC...'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Mode') { continue }
        if ($PSBoundParameters[$k] -is [switch]) { if ($PSBoundParameters[$k]) { $argList += "-$k" } }
        else { $argList += @("-$k", "`"$($PSBoundParameters[$k])`"") }
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Get-SingBox {
    if (Test-Path $ExePath) { Good "sing-box уже установлен: $ExePath"; return }

    Say "Скачиваю sing-box v$Version..."
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $zipName = "sing-box-$Version-windows-$arch.zip"
    $url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/$zipName"
    $tmp = Join-Path $env:TEMP $zipName
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

    $tmpDir = Join-Path $env:TEMP "singbox-extract-$([guid]::NewGuid().ToString('N'))"
    Expand-Archive -Path $tmp -DestinationPath $tmpDir -Force
    $inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
    Copy-Item (Join-Path $inner.FullName 'sing-box.exe') $ExePath -Force
    if (Test-Path (Join-Path $inner.FullName 'wintun.dll')) {
        Copy-Item (Join-Path $inner.FullName 'wintun.dll') (Join-Path $InstallDir 'wintun.dll') -Force
    }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Good "sing-box установлен: $((& $ExePath version))"
}

function Get-Wintun {
    if ($Mode -ne 'tun' -or $CheckOnly) { return }
    $dll = if ($WintunPath) { $WintunPath } else { Join-Path $InstallDir 'wintun.dll' }
    $target = Join-Path $InstallDir 'wintun.dll'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

    # 1. уже есть (в т.ч. установленный другими клиентами — v2rayN, Hiddify, WireGuard)
    if (Test-Path $dll) {
        if ($dll -ne $target) { Copy-Item $dll $target -Force }
        Good 'wintun.dll найден'
        return
    }
    $known = @(
        "$env:ProgramFiles\v2rayN\bin\xray\wintun.dll",
        "$env:ProgramFiles\v2rayN\bin\sing_box\wintun.dll",
        "$env:USERPROFILE\v2rayN\bin\xray\wintun.dll",
        "$env:ProgramFiles\WireGuard\wintun.dll",
        "$env:ProgramFiles\Hiddify\wintun.dll"
    )
    foreach ($k in $known) { if (Test-Path $k) { Copy-Item $k $target -Force; Good "wintun.dll взят из $k"; return } }

    # 2. официальный источник
    Say 'Скачиваю драйвер wintun (wintun.net)...'
    $tmp = Join-Path $env:TEMP 'wintun-dl'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'wintun.zip'
    $ok = $false
    try {
        curl.exe -sSL --max-time 90 -o $zip 'https://www.wintun.net/builds/wintun-0.14.1.zip'
        if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100000) { $ok = $true }
    } catch { }
    if ($ok) {
        try {
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $src = Join-Path $tmp "wintun\bin\$arch\wintun.dll"
            if (Test-Path $src) { Copy-Item $src $target -Force; Good 'wintun.dll установлен (wintun.net)'; return }
        } catch { }
    }

    # 3. зеркало на GitHub (релиз v2rayN) — работает из РФ, когда wintun.net недоступен
    Warn2 'wintun.net недоступен (типичная блокировка в РФ). Беру драйвер из зеркала на GitHub (~170 МБ, один раз).'
    $mirror = 'https://github.com/2dust/v2rayN/releases/download/7.25.2/v2rayN-windows-64.zip'
    $mzip = Join-Path $tmp 'v2rayn.zip'
    curl.exe -sSL --max-time 1200 --retry 3 -o $mzip $mirror
    if ((Test-Path $mzip) -and (Get-Item $mzip).Length -gt 10000000) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($mzip)
        $entry = $za.Entries | Where-Object { $_.FullName -match 'wintun\.dll$' } | Select-Object -First 1
        if ($entry) {
            $out = Join-Path $tmp 'wintun.dll'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
            Copy-Item $out $target -Force
            $za.Dispose()
            Remove-Item $mzip -Force -ErrorAction SilentlyContinue
            Good 'wintun.dll установлен (зеркало GitHub)'
            return
        }
        $za.Dispose()
    }
    throw "Не удалось получить wintun.dll. Скачайте вручную с https://www.wintun.net/ (x64) и положите в $InstallDir\wintun.dll, затем запустите скрипт снова."
}

function ConvertFrom-VlessLink {
    param([string]$Url)
    $u = $Url.Trim()
    if ($u -notmatch '^vless://') { throw 'Ожидается ссылка вида vless://...' }
    $body, $frag = ($u -replace '^vless://','') -split '#', 2
    $main, $query = $body -split '\?', 2
    $userAt = $main.LastIndexOf('@')
    if ($userAt -lt 0) { throw 'Неверная ссылка: не найден UUID' }
    $uuid = $main.Substring(0, $userAt)
    $hostPort = $main.Substring($userAt + 1)
    $lastColon = $hostPort.LastIndexOf(':')
    if ($lastColon -lt 0) { throw 'Неверная ссылка: не найден порт' }
    $server = $hostPort.Substring(0, $lastColon).Trim('[',']')
    $port   = [int]$hostPort.Substring($lastColon + 1)

    $q = @{}
    foreach ($pair in ($query -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $q[[uri]::UnescapeDataString($kv[0]).ToLower()] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
    }
    $security = if ($q.ContainsKey('security') -and $q['security']) { $q['security'] } else { 'reality' }
    [pscustomobject]@{
        Kind       = 'vless'
        Name       = if ($frag) { [uri]::UnescapeDataString($frag) } else { 'VLESS' }
        Server     = $server
        Port       = $port
        Uuid       = $uuid
        Sni        = $q['sni']
        Security   = $security
        Insecure   = ($q.ContainsKey('allowinsecure') -and ($q['allowinsecure'] -eq '1' -or $q['allowinsecure'] -eq 'true'))
        PublicKey  = $q['pbk']
        ShortId    = if ($q.ContainsKey('sid')) { $q['sid'] } else { '' }
        # vision нужен только для REALITY; для обычного TLS — только если явно указан в ссылке
        Flow       = if ($q.ContainsKey('flow') -and $q['flow']) { $q['flow'] } elseif ($security -eq 'reality') { 'xtls-rprx-vision' } else { '' }
        Fingerprint= if ($q.ContainsKey('fp')) { $q['fp'] } else { 'chrome' }
        Type       = if ($q.ContainsKey('type')) { $q['type'] } else { 'tcp' }
    }
}

function Repair-Base64 {
    param([string]$S)
    $t = $S.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return $t
}

function ConvertFrom-SsLink {
    param([string]$Url)
    $u = $Url.Trim()
    if ($u -notmatch '^ss://') { throw 'Ожидается ссылка вида ss://...' }
    $body = ($u -replace '^ss://', '')
    $frag = ''
    if ($body.Contains('#')) { $p = $body -split '#', 2; $body = $p[0]; $frag = $p[1] }

    $userInfo = ''
    $hostPort = ''
    if ($body.Contains('@')) {
        $idx = $body.LastIndexOf('@')
        $userInfo = $body.Substring(0, $idx)
        $hostPort = $body.Substring($idx + 1)
        if (-not $userInfo.Contains(':')) {
            try { $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Repair-Base64 $userInfo))) } catch { $dec = $userInfo }
            if ($dec.Contains(':')) { $userInfo = $dec }
        } else {
            $userInfo = [uri]::UnescapeDataString($userInfo)
        }
    } else {
        $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Repair-Base64 $body)))
        $idx = $dec.LastIndexOf('@')
        $userInfo = $dec.Substring(0, $idx)
        $hostPort = $dec.Substring($idx + 1)
    }

    $ci = $userInfo.IndexOf(':')
    if ($ci -lt 0) { throw 'Неверная ss-ссылка: нет method:password' }
    $method = $userInfo.Substring(0, $ci)
    $password = $userInfo.Substring($ci + 1)

    # если порт/хост содержат query (?plugin=...) — отбрасываем
    if ($hostPort.Contains('/')) { $hostPort = $hostPort.Split('/')[0] }
    $lc = $hostPort.LastIndexOf(':')
    if ($lc -lt 0) { throw 'Неверная ss-ссылка: нет порта' }
    [pscustomobject]@{
        Kind     = 'ss'
        Name     = if ($frag) { [uri]::UnescapeDataString($frag) } else { 'SS' }
        Server   = $hostPort.Substring(0, $lc).Trim('[', ']')
        Port     = [int]$hostPort.Substring($lc + 1)
        Method   = $method
        Password = $password
    }
}

function New-Config {
    param($P)

    if ($P.Kind -eq 'ss') {
        $proxy = [ordered]@{
            type         = 'shadowsocks'
            tag          = 'proxy'
            server       = $P.Server
            server_port  = $P.Port
            method       = $P.Method
            password     = $P.Password
            udp_over_tcp = [bool]$UdpOverTcp
        }
    } elseif ($P.Security -eq 'tls') {
        # VLESS поверх обычного TLS (маскируется под обычный HTTPS, обходит DPI,
        # который ломает Reality и Shadowsocks)
        $tls = @{
            enabled     = $true
            server_name = $P.Sni
            insecure    = $true
            utls        = @{ enabled = $true; fingerprint = $P.Fingerprint }
        }
        $proxy = [ordered]@{
            type            = 'vless'
            tag             = 'proxy'
            server          = $P.Server
            server_port     = $P.Port
            uuid            = $P.Uuid
            packet_encoding = 'xudp'     # <-- обязательно для UDP (LoL и другие игры)
            tls             = $tls
        }
        if ($P.Flow) { $proxy['flow'] = $P.Flow }
    } else {
        $reality = @{
            enabled    = $true
            public_key = $P.PublicKey
            short_id   = $P.ShortId
        }
        $tls = @{
            enabled     = $true
            server_name = $P.Sni
            utls        = @{ enabled = $true; fingerprint = $P.Fingerprint }
            reality     = $reality
        }
        $proxy = [ordered]@{
            type            = 'vless'
            tag             = 'proxy'
            server          = $P.Server
            server_port     = $P.Port
            uuid            = $P.Uuid
            flow            = $P.Flow
            packet_encoding = 'xudp'     # <-- обязательно для UDP (LoL и другие игры)
            tls             = $tls
        }
    }

    $inbounds = @()
    if ($Mode -eq 'tun') {
        $inbounds += @{
            type                  = 'tun'
            tag                   = 'tun-in'
            interface_name        = 'sing-box-tun'
            address               = @('172.19.0.1/30')
            mtu                   = $Mtu
            auto_route            = $true
            strict_route          = (-not $NoStrictRoute)
            stack                 = 'mixed'
            route_exclude_address = @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','224.0.0.0/4')
        }
    }
    $inbounds += @{
        type        = 'mixed'
        tag         = 'local-in'
        listen      = '127.0.0.1'
        listen_port = $SocksPort
    }

    $rules = @(
        @{ action = 'sniff' }
        @{ protocol = 'dns'; action = 'hijack-dns' }
        @{ ip_is_private = $true; outbound = 'direct' }
    )
    if ($OnlyGames) {
        $rules += @{ process_name = @(
            'League of Legends.exe','LeagueClient.exe','LeagueClientUx.exe',
            'LeagueClientUxRender.exe','RiotClientServices.exe'
        ); outbound = 'proxy' }
    }
    $rules += @{ protocol = 'quic'; outbound = if ($Mode -eq 'tun') { 'proxy' } else { 'direct' } }

    $config = [ordered]@{
        log = @{ level = 'warn'; timestamp = $true; output = $LogPath }
        dns = @{
            # новый формат DNS-серверов sing-box 1.12+ (legacy удалён в 1.14)
            servers  = @(
                @{ type = 'https'; tag = 'dns-proxy'; server = '1.1.1.1'; detour = 'proxy' }
            )
            strategy = 'ipv4_only'
        }
        inbounds  = $inbounds
        outbounds = @(
            $proxy
            @{ type = 'direct'; tag = 'direct' }
        )
        route = @{
            auto_detect_interface = $true
            final                 = if ($OnlyGames) { 'direct' } else { 'proxy' }
            rules                 = $rules
        }
        experimental = @{ cache_file = @{ enabled = $true } }
    }

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $json = $config | ConvertTo-Json -Depth 12
    # строго UTF-8 без BOM — иначе sing-box не может разобрать JSON
    [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
    Good "Конфиг создан: $ConfigPath"
}

function Test-Config {
    Say 'Проверяю конфиг...'
    $out = & $ExePath check -c $ConfigPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host $_ }
        throw 'Конфиг не прошёл проверку sing-box check'
    }
    Good 'Конфиг валиден'
}

function Stop-Vpn {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
    Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Install-Service {
    Say 'Регистрирую автозапуск (задача планировщика от SYSTEM)...'
    $action  = New-ScheduledTaskAction -Execute $ExePath -Argument "run -c `"$ConfigPath`"" -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Good 'Автозапуск настроен'
}

function Start-Vpn {
    Say 'Запускаю туннель...'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 4
    if (-not (Get-Process sing-box -ErrorAction SilentlyContinue)) {
        Warn2 'Процесс sing-box не найден'
        if (Test-Path $LogPath) { Get-Content $LogPath -Tail 25 | ForEach-Object { Write-Host "    $_" } }
        throw 'Не удалось запустить sing-box'
    }
    Good 'Процесс sing-box работает'
}

function Show-Status {
    $ip = $null
    try { $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim() } catch { }
    Write-Host ''
    Write-Host '===== Статус =====' -ForegroundColor Cyan
    Write-Host ("Внешний IP через VPN : {0}" -f ($(if ($ip) { $ip } else { 'не определён' })))
    if ($Mode -eq 'tun') {
        $ad = Get-NetAdapter -Name 'sing-box-tun' -ErrorAction SilentlyContinue
        Write-Host ("Адаптер TUN          : {0}" -f ($(if ($ad) { $ad.Status } else { 'не найден' })))
    }
    Write-Host ("Локальный прокси     : 127.0.0.1:{0} (HTTP/SOCKS5)" -f $SocksPort)
    Write-Host ("Лог                  : {0}" -f $LogPath)
    Write-Host ''
}

# ============================== ОСНОВНОЙ СЦЕНАРИЙ =============================
if ($Uninstall) {
    if (-not (Test-Admin)) { Bad 'Для удаления нужны права администратора'; exit 1 }
    Say 'Удаляю VPN...'
    Stop-Vpn
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    Warn2 "Файлы sing-box остались в $InstallDir (удалите вручную при необходимости)"
    Good 'VPN удалён, туннель остановлен'
    exit 0
}

if ($ShowLog) {
    if (Test-Path $LogPath) { Get-Content $LogPath -Tail 60 } else { Warn2 'Лог пуст' }
    exit 0
}

if ($Restart) {
    if (-not (Test-Admin)) { Bad 'Нужны права администратора'; exit 1 }
    Stop-Vpn; Start-Vpn; Show-Status; exit 0
}

if (-not $Link) { Bad 'Укажите строку подключения: -Link "ss://..." или "vless://..."'; exit 1 }
if (Test-Path $Link) { $Link = (Get-Content $Link -First 1).Trim() }

Get-SingBox
Get-Wintun
if ($Link -match '^ss://') {
    $parsed = ConvertFrom-SsLink $Link
    Good ("Shadowsocks: {0}:{1}  метод: {2}" -f $parsed.Server, $parsed.Port, $parsed.Method)
} else {
    $parsed = ConvertFrom-VlessLink $Link
    Good ("VLESS-Reality: {0}:{1}  SNI: {2}" -f $parsed.Server, $parsed.Port, $parsed.Sni)
}

Say 'Проверяю доступность сервера...'
if (-not (Test-NetConnection -ComputerName $parsed.Server -Port $parsed.Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Warn2 "Порт $($parsed.Port) на $($parsed.Server) недоступен (firewall хостера?). Продолжаю."
} else { Good 'Сервер доступен' }

New-Config $parsed
Test-Config
if ($CheckOnly) { Good 'Конфиг собран и проверен (режим -CheckOnly, ничего не запускалось)'; exit 0 }
Stop-Vpn
if (-not $NoAutoStart -and $Mode -eq 'tun') { Install-Service }
if ($Mode -eq 'tun') { Start-Vpn }
else {
    Say 'Запускаю sing-box в режиме SOCKS (без TUN)...'
    Start-Process -FilePath $ExePath -ArgumentList @('run','-c',"`"$ConfigPath`"") -WorkingDirectory $InstallDir -WindowStyle Hidden
    Start-Sleep -Seconds 3
    if (-not (Get-Process sing-box -ErrorAction SilentlyContinue)) {
        if (Test-Path $LogPath) { Get-Content $LogPath -Tail 25 }
        throw 'sing-box не запустился'
    }
    Good "SOCKS5/HTTP прокси: 127.0.0.1:$SocksPort"
}
Show-Status
Write-Host 'Готово. Проверка: https://api.ipify.org должно показать IP сервера.' -ForegroundColor Green
