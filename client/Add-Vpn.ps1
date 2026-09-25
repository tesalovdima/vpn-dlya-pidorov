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

# --- сохранение логина/пароля прямо в RAS (то же, что галочка "Сохранить данные")
#     Нужно, чтобы при включении VPN в Windows ничего не спрашивалось.
if (-not ('RasCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RasCred
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RASCREDENTIALS
    {
        public int dwSize;
        public int dwMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)] public string szDomain;
    }

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasSetCredentials(string phonebook, string entry, ref RASCREDENTIALS creds, bool clear);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasGetCredentials(string phonebook, string entry, ref RASCREDENTIALS creds);

    public static int Set(string phonebook, string entry, string user, string pass)
    {
        RASCREDENTIALS c = new RASCREDENTIALS();
        c.dwSize = Marshal.SizeOf(typeof(RASCREDENTIALS));
        c.dwMask = 7;
        c.szUserName = user;
        c.szPassword = pass;
        c.szDomain = "";
        return RasSetCredentials(phonebook, entry, ref c, false);
    }

    public static string GetRaw(string phonebook, string entry)
    {
        RASCREDENTIALS c = new RASCREDENTIALS();
        c.dwSize = Marshal.SizeOf(typeof(RASCREDENTIALS));
        c.dwMask = 7;
        c.szUserName = "";
        c.szPassword = "";
        c.szDomain = "";
        int rc = RasGetCredentials(phonebook, entry, ref c);
        return rc + "|" + c.szUserName + "|" + c.szPassword;
    }
}
'@
}

function Get-RasPhonebook {
    Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
}

function Save-VpnCredentials {
    param([string]$ConnName, [string]$UserName, [string]$Pass)
    $pbk = Get-RasPhonebook
    if (-not (Test-Path $pbk)) { return $false }
    try {
        if ([RasCred]::Set($pbk, $ConnName, $UserName, $Pass) -ne 0) { return $false }
        return (([RasCred]::GetRaw($pbk, $ConnName) -split '\|')[0] -eq '0')
    } catch { return $false }
}

function Get-SavedCredentials {
    param([string]$ConnName)
    $pbk = Get-RasPhonebook
    if (-not (Test-Path $pbk)) { return $null }
    try {
        $p = [RasCred]::GetRaw($pbk, $ConnName) -split '\|'
        if ($p[0] -eq '0' -and $p[1] -and $p[2]) {
            return [pscustomobject]@{ User = $p[1]; Pass = $p[2] }
        }
        return $null
    } catch { return $null }
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
if ($Server) {
    if (-not $User -or -not $Password -or -not $Psk) {
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

    # сохраняем логин/пароль: при включении VPN Windows не будет их спрашивать
    Say 'Сохраняю логин и пароль для подключения...'
    if (Save-VpnCredentials -ConnName $Name -UserName $User -Pass $Password) {
        Good 'Логин и пароль сохранены — при включении VPN вводить их не нужно'
    } else {
        Warn2 'Пароль сохранить не удалось: Windows спросит его при первом включении'
    }
} elseif (-not $Connect -and -not $Test) {
    Bad 'Укажите: -Server <IP> -User <логин> -Password <пароль> -Psk <ключ IPsec>'
    exit 1
} elseif (-not (Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue)) {
    Bad "Подключение '$Name' не найдено — сначала создайте его (параметр -Server)"
    exit 1
}

# ---------------------------------------------------------------- connect + test
if ($Connect -or $Test) {
    Say 'Подключаюсь...'
    if (-not $User -or -not $Password) {
        $saved = Get-SavedCredentials -ConnName $Name
        if ($saved) {
            $User = $saved.User
            $Password = $saved.Pass
            Good 'Беру сохранённые логин и пароль'
        }
    }
    if ($User -and $Password) {
        $r = rasdial "$Name" $User $Password 2>&1 | Out-String
    } else {
        $r = rasdial "$Name" 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Warn2 'Подключиться не удалось — введите логин и пароль.'
        $User = Read-Host 'Логин'
        $Password = Read-Host 'Пароль'
        $r = rasdial "$Name" $User $Password 2>&1 | Out-String
    }
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
