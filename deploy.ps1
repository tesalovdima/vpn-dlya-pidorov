<#
.SYNOPSIS
    Разворачивает VPN-сервер на удалённом сервере по SSH прямо из Windows.

.DESCRIPTION
    Копирует server/install-vpn.sh на сервер, запускает его от root и
    показывает логин/пароль/PSK для подключения.
    Пароль SSH спрашивается интерактивно (или используйте -KeyFile).

.EXAMPLE
    .\deploy.ps1 -Server 185.125.217.195
.EXAMPLE
    .\deploy.ps1 -Server 185.125.217.195 -KeyFile "$env:USERPROFILE\.ssh\vpn_deploy"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$User = 'root',
    [int]$SshPort = 22,
    [string]$KeyFile,
    [string]$VpnUser = 'vpnuser',
    [string]$VpnPass,
    [string]$Psk,
    [int]$Mtu = 1300,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $root 'server\install-vpn.sh'
if (-not (Test-Path $installer)) { throw "Не найден $installer" }

$sshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', '-p', "$SshPort")
$scpOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', '-P', "$SshPort")
if ($KeyFile) { $sshOpts += @('-i', $KeyFile); $scpOpts += @('-i', $KeyFile) }
$target = "$User@$Server"

Write-Host "[*] Проверяю доступность $Server`:$SshPort ..." -ForegroundColor Cyan
if (-not (Test-NetConnection -ComputerName $Server -Port $SshPort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Порт $SshPort на $Server недоступен"
}

Write-Host '[*] Копирую установщик...' -ForegroundColor Cyan
& scp @scpOpts $installer "${target}:/root/install-vpn.sh"
if ($LASTEXITCODE -ne 0) { throw 'scp не смог скопировать файл' }

$args = @()
if ($Uninstall) { $args += '--uninstall' }
else {
    $args += "--user $VpnUser"
    if ($VpnPass) { $args += "--pass $VpnPass" }
    if ($Psk) { $args += "--psk $Psk" }
    $args += "--mtu $Mtu"
}
$remoteCmd = "sed -i s/\r\$// /root/install-vpn.sh; bash /root/install-vpn.sh $($args -join ' ')"

Write-Host '[*] Устанавливаю VPN на сервере (1-2 минуты)...' -ForegroundColor Cyan
$output = & ssh @sshOpts $target $remoteCmd 2>&1
$output | ForEach-Object { Write-Host $_ }

$params = @{}
foreach ($line in $output) {
    if ($line -match '^server=(.+)$')   { $params.server = $Matches[1].Trim() }
    if ($line -match '^login=(.+)$')    { $params.login  = $Matches[1].Trim() }
    if ($line -match '^password=(.+)$') { $params.pass   = $Matches[1].Trim() }
    if ($line -match '^psk=(.+)$')      { $params.psk    = $Matches[1].Trim() }
}

if ($params.server -and $params.login -and $params.pass -and $params.psk) {
    Write-Host ''
    Write-Host '=== Параметры подключения ===' -ForegroundColor Green
    Write-Host "Сервер:  $($params.server)"
    Write-Host "Логин:   $($params.login)"
    Write-Host "Пароль:  $($params.pass)"
    Write-Host "PSK:     $($params.psk)"
    Write-Host ''
    Write-Host 'Дальше (на этом ПК, от администратора):' -ForegroundColor Cyan
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$root\client\Add-Vpn.ps1`" -Server $($params.server) -User $($params.login) -Password `"$($params.pass)`" -Psk `"$($params.psk)`" -Connect"
} else {
    Write-Host '[!] Не удалось распарсить параметры — смотрите вывод выше' -ForegroundColor Yellow
}
