# VPN за одну команду (L2TP/IPsec) + клиент для Windows

Поднимает личный VPN-сервер **одной командой** и добавляет его в Windows как
**обычное VPN-подключение** — включать и выключать можно в один клик
(Параметры → Сеть и Интернет → VPN, значок сети в трее).

Проверено: работает через российских провайдеров с DPI/ТСПУ, поддерживает
**UDP** (нужно для League of Legends), YouTube и Discord открываются.

---

## 0. Скачать архивом

Один zip — в нём и сервер, и клиент, и документация:

| Что | Ссылка |
|---|---|
| Последний релиз | https://github.com/tesalovdima/vpn-dlya-pidorov/releases/latest |
| Архив тега v1.0.0 | https://github.com/tesalovdima/vpn-dlya-pidorov/archive/refs/tags/v1.0.0.zip |
| Весь репозиторий zip | https://github.com/tesalovdima/vpn-dlya-pidorov/archive/refs/heads/main.zip |

Распаковать и запустить `client\install-client-vpn.bat` (двойной клик) —
он сам создаст VPN-подключение в Windows.

> В архиве **нет** никаких паролей и ключей: логин/пароль/PSK выдаёт тот,
> кто ставит сервер (скрипт печатает их в конце установки).

---

## 1. Быстрый старт

### Шаг 1 — сервер (Ubuntu/Debian, root)

```bash
curl -fsSL https://raw.githubusercontent.com/tesalovdima/vpn-dlya-pidorov/main/server/install-vpn.sh -o vpn.sh && bash vpn.sh
```

Скрипт выведет в конце логин, пароль и PSK — они понадобятся на клиенте.
Он сам: ставит strongSwan + xl2tpd, включает IP-форвардинг, NAT, MSS-clamping
(без него не грузятся «тяжёлые» сайты), открывает порты и запускает службы.

### Шаг 2 — Windows

**Самый простой способ — батник** (двойной клик, дальше всё сам):

```
client\install-client-vpn.bat
```

Он запросит IP сервера, логин, пароль и PSK, сам попросит права
администратора (UAC), создаст подключение и предложит сразу проверить связь.

То же самое без вопросов, одной строкой (cmd **от администратора**):

```bat
client\install-client-vpn.bat 1.2.3.4 vpnuser ПАРОЛЬ PSK
```

**Через PowerShell** (альтернатива):

```powershell
git clone git@github.com:tesalovdima/vpn-dlya-pidorov.git
cd vpn-dlya-pidorov
powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 `
    -Server <IP_СЕРВЕРА> -User vpnuser -Password <ПАРОЛЬ> -Psk <PSK>
```

Готово. В Windows появилось подключение **MyVPN** — оно в списке стандартных
подключений: включить/выключить можно в Параметрах, в трее или командой:

```powershell
rasdial "MyVPN" vpnuser <ПАРОЛЬ>       # подключить
rasdial "MyVPN" /disconnect            # отключить
```

---

## 2. Что где лежит

```
server/install-vpn.sh       # VPN-сервер L2TP/IPsec одной командой (+ --uninstall)
server/install-singbox.sh   # альтернатива: VLESS + TLS (sing-box), если L2TP заблокируют
client/install-client-vpn.bat   # установщик для Windows: двойной клик и готово
client/Add-Vpn.ps1          # добавляет VPN в стандартные подключения Windows
client/setup-windows.ps1    # альтернативный клиент (sing-box, SOCKS/TUN)
deploy.ps1                  # развёртывание сервера прямо из Windows по SSH
docs/LOL.md                 # League of Legends: UDP, пинг, античит
docs/TROUBLESHOOTING.md     # если что-то не работает
docs/SECURITY.md            # защита сервера (обязательно к прочтению)
```

---

## 3. Управление клиентом

```powershell
# подключить
rasdial "MyVPN" vpnuser <ПАРОЛЬ>

# отключить
rasdial "MyVPN" /disconnect

# посмотреть состояние и внешний IP
powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Name MyVPN -Status

# подключить → проверить → автоматически отключить (безопасная проверка)
powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Name MyVPN -User vpnuser -Password <ПАРОЛЬ> -Test

# удалить подключение из Windows
powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Name MyVPN -Remove
```

То же самое батником (удобнее — просто двойной клик):

```bat
client\install-client-vpn.bat status        :: состояние и внешний IP
client\install-client-vpn.bat disconnect    :: отключить
client\install-client-vpn.bat remove        :: удалить подключение
client\install-client-vpn.bat test 1.2.3.4 vpnuser ПАРОЛЬ PSK   :: подключить, проверить, отключить
```

Либо просто через интерфейс: **Параметры → Сеть и Интернет → VPN → MyVPN → Подключить**.

---

## 4. Почему L2TP/IPsec, а не VLESS+Reality?

На тестах у провайдера с активным DPI (Ростов-на-Дону):

| Протокол | Результат |
|---|---|
| VLESS + XTLS-Reality | ❌ `REALITY: processed invalid connection` — DPI ломает рукопожатие |
| Shadowsocks-2022 | ⚠️ работал, затем провайдер его заблокировал |
| VLESS + обычный TLS | ✅ работает (оставлен как резерв в `server/install-singbox.sh`) |
| **L2TP/IPsec** | ✅ **работает**, Windows-нативное подключение, полный UDP |

L2TP/IPsec не притворяется HTTPS, но здесь он стабильнее — и главное, даёт
**нативное подключение Windows** с полноценным UDP-туннелем.

---

## 5. Скрипты сервера

```bash
bash server/install-vpn.sh                          # установка
bash server/install-vpn.sh --user myuser --pass mypass --psk mykey
bash server/install-vpn.sh --mtu 1300               # MTU внутри туннеля
bash server/install-vpn.sh --uninstall              # удалить VPN
```

Проверка состояния:

```bash
systemctl status strongswan-starter xl2tpd
ipsec statusall
journalctl -u xl2tpd -n 30
cat /root/vpn-info.txt          # логин/пароль/PSK
```

---

## 6. Важно

* Пароль root, переданный в открытом виде, **смените** после установки — см.
  [docs/SECURITY.md](docs/SECURITY.md).
* Другие VPN-клиенты (Zapret/GoodbyeDPI, Windscribe, Shadowsocks-клиент и т.п.)
  могут конфликтовать — на время экспериментов их лучше выключать, хотя с
  L2TP/IPsec они уживаются.
* Скрипты рассчитаны на законное использование на собственном сервере.
