@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title VPN installer

rem ===========================================================================
rem  VPN (L2TP/IPsec) - установка клиента для Windows
rem
rem  Просто двойной клик - спросит данные и всё настроит.
rem
rem  Варианты запуска (из командной строки от администратора):
rem    install-client.bat 185.125.217.195 vpnuser ПАРОЛЬ PSK     - установить
rem    install-client.bat connect 185.125.217.195 vpnuser ПАРОЛЬ PSK
rem    install-client.bat disconnect
rem    install-client.bat status
rem    install-client.bat test 185.125.217.195 vpnuser ПАРОЛЬ PSK
rem    install-client.bat remove
rem ===========================================================================

set "HERE=%~dp0"
set "PS1=%HERE%Add-Vpn.ps1"
set "NAME=MyVPN"

set "MODE=%~1"
set "SRV=%~1"
set "USR=%~2"
set "PWD=%~3"
set "PSK=%~4"

rem --- нужны права администратора ---
net session >nul 2>&1
if errorlevel 1 (
    echo [*] Требуются права администратора - запрашиваю UAC...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

if not exist "%PS1%" (
    echo [x] Не найден Add-Vpn.ps1 рядом с этим файлом.
    echo     Скопируйте папку client целиком.
    pause
    exit /b 1
)

if /i "%MODE%"=="remove"     goto :remove
if /i "%MODE%"=="uninstall"  goto :remove
if /i "%MODE%"=="status"     goto :status
if /i "%MODE%"=="connect"    goto :connect
if /i "%MODE%"=="disconnect" goto :disconnect
if /i "%MODE%"=="test"       goto :test
if /i "%MODE%"=="help"       goto :help
if /i "%MODE%"=="-h"         goto :help
if /i "%MODE%"=="--help"     goto :help
if not "%SRV%"=="" goto :install

:ask
echo ==========================================================
echo    Установка VPN (L2TP/IPsec) для Windows
echo ==========================================================
echo.
echo Данные для подключения выдаёт владелец сервера.
echo.
set "SRV="
set /p "SRV=IP сервера: "
set /p "USR=Логин: "
set /p "PWD=Пароль: "
set /p "PSK=Ключ (PSK): "
set "N="
set /p "N=Название подключения [MyVPN]: "
if not "%N%"=="" set "NAME=%N%"

:install
if "%SRV%"=="" echo [x] Не указан IP сервера & pause & exit /b 1
if "%USR%"=="" echo [x] Не указан логин & pause & exit /b 1
if "%PWD%"=="" echo [x] Не указан пароль & pause & exit /b 1
if "%PSK%"=="" echo [x] Не указан PSK & pause & exit /b 1

echo.
echo [*] Создаю подключение "%NAME%"...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Server "%SRV%" -User "%USR%" -Password "%PWD%" -Psk "%PSK%" -Name "%NAME%"
if errorlevel 1 goto :fail

echo.
set "GO="
set /p "GO=Подключиться сейчас и проверить связь? [Y/n]: "
if /i "%GO%"=="n" goto :done
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -User "%USR%" -Password "%PWD%" -Test
goto :done

:connect
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -User "%USR%" -Password "%PWD%" -Connect
goto :done

:test
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -User "%USR%" -Password "%PWD%" -Test
goto :done

:disconnect
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -Disconnect
goto :done

:status
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -Status
goto :done

:remove
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Name "%NAME%" -Remove
goto :done

:help
echo.
echo  VPN (L2TP/IPsec) - клиент для Windows
echo.
echo   install-client.bat                       - установить (спросит данные)
echo   install-client.bat IP ЛОГИН ПАРОЛЬ PSK   - установить без вопросов
echo   install-client.bat connect IP ЛОГИН ПАРОЛЬ PSK - подключиться
echo   install-client.bat test  IP ЛОГИН ПАРОЛЬ PSK - проверить и отключиться
echo   install-client.bat status                - состояние и внешний IP
echo   install-client.bat disconnect            - отключить
echo   install-client.bat remove                - удалить подключение
echo.
echo   После установки VPN включается и выключается как обычно:
echo   Параметры - Сеть и Интернет - VPN, или значок сети в трее.
echo.

:done
echo.
pause
exit /b 0

:fail
echo.
echo [x] Не получилось. Смотрите docs\TROUBLESHOOTING.md
pause
exit /b 1
