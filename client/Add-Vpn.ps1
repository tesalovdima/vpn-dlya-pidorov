<#
.SYNOPSIS
    Добавляет VPN в стандартные подключения Windows (Панель управления →
    Сеть → VPN). Дальше включается/отключается в один клик — в Параметрах,
    в трее или командой.

.DESCRIPTION
    Создаёт L2TP/IPsec-подключение с указанными параметрами, применяет
    необходимые правки реестра (для работы за домашним роутером/NAT)
    и проверяет подключение.

.EXAMPLE
    # создать подключение
    powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Server 185.125.217.195 -User vpnuser -Password 'xxx' -Psk 'yyy'

.EXAMPLE
    # подключить / отключить / статус / удалить
    ... -Connect
    ... -Disconnect
    ... -Status
    ... -Remove
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$User,
    [string]$Password,
    [string]$Psk,
    [string]$Name = 'MyVPN',
    [int]$Mtu = 1300,
    [switch]$Connect,
    [switch]$Disconnect,
    [switch]$Status,
    [switch]$Remove,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn2($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Bad 'Нужны права администратора — перезапустите PowerShell от имени администратора'
    exit 1
}

# ---------------------------------------------------------------- status
if ($Status) {
    $c = Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue
    if (-not $c) { Warn2 "Подключение '$Name' не найдено"; exit 1 }
    Write-Host "Имя:         $($c.Name)"
    Write-Host "Сервер:      $($c.ServerAddress)"
    Write-Host "Тип:         $($c.TunnelType)"
    Write-Host "Состояние:   $($c.ConnectionStatus)"
    if ($c.ConnectionStatus -eq 'Connected') {
        Say 'Проверка внешнего IP...'
        Write-Host ("Внешний IP:  " + (curl.exe -sS --max-time 10 https://api.ipify.org))
    }
    exit 0
}

# ---------------------------------------------------------------- disconnect
if ($Disconnect) {
    Say "Отключаю '$Name'..."
    rasdial "$Name" /disconnect | Out-Null
    Start-Sleep -Seconds 2
    Good "Состояние: $((Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue).ConnectionStatus)"
    exit 0
}

# ---------------------------------------------------------------- remove
if ($Remove) {
    Say "Удаляю подключение '$Name'..."
    rasdial "$Name" /disconnect 2>$null | Out-Null
    Remove-VpnConnection -Name $Name -Force -ErrorAction SilentlyContinue
    Good 'Подключение удалено'
    exit 0
}

# ---------------------------------------------------------------- create
if (-not $Server -or -not $User -or -not $Password -or -not $Psk) {
    Bad 'Укажите: -Server <IP> -User <логин> -Password <пароль> -Psk <ключ IPsec>'
    exit 1
}

# правка реестра: работа L2TP/IPsec за NAT (домашний роутер)
Say 'Настраиваю работу L2TP/IPsec за NAT...'
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent' -Name 'AssumeUDPEncapsulationContextOnSendRule' `
    -Value 2 -PropertyType DWord -Force | Out-Null
Restart-Service PolicyAgent -Force -ErrorAction SilentlyContinue
Restart-Service IKEEXT -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Good 'NAT-фикс применён'

Say "Создаю подключение '$Name'..."
Remove-VpnConnection -Name $Name -Force -ErrorAction SilentlyContinue
Add-VpnConnection -Name $Name -ServerAddress $Server -TunnelType L2tp -L2tpPsk $Psk `
    -AuthenticationMethod MSChapv2 -EncryptionLevel Required -RememberCredential -Force | Out-Null
Set-VpnConnection -Name $Name -SplitTunneling $false -Force
Good "Подключение '$Name' добавлено в Windows (Параметры → Сеть и Интернет → VPN)"

# ---------------------------------------------------------------- connect + test
if ($Connect -or $Test) {
    Say 'Подключаюсь...'
    $r = rasdial "$Name" $User $Password 2>&1 | Out-String
    Write-Host $r.Trim()
    Start-Sleep -Seconds 6

    $st = (Get-VpnConnection -Name $Name).ConnectionStatus
    Good "Состояние: $st"

    if ($st -eq 'Connected') {
        $ip = curl.exe -sS --max-time 10 https://api.ipify.org
        Good "Внешний IP через VPN: $ip"
        foreach ($s in @('https://www.youtube.com','https://discord.com','https://www.leagueoflegends.com')) {
            $code = (curl.exe -sS --max-time 12 -o NUL -w '%{http_code}' $s 2>&1) -join ''
            Write-Host ("    {0,-34} {1}" -f $s, $code)
        }
        # UDP внутри туннеля (важно для League of Legends)
        try {
            $d = Resolve-DnsName www.google.com -Server 8.8.8.8 -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            Good 'UDP внутри туннеля: работает'
        } catch { Warn2 'UDP внутри туннеля: не отвечает' }
    }

    if ($Test) {
        Say 'Отключаю после теста...'
        rasdial "$Name" /disconnect | Out-Null
        Start-Sleep -Seconds 3
        Good "Состояние: $((Get-VpnConnection -Name $Name).ConnectionStatus)"
        Good "Внешний IP без VPN: $(curl.exe -sS --max-time 10 https://api.ipify.org)"
    }
}
