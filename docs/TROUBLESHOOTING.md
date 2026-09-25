# Если что-то не работает

## Windows: подключение не устанавливается

### Ошибка 789 «ошибка на уровне безопасности»

Причины и решения:

1. **PSK не совпадает** — проверьте на сервере:
   ```bash
   grep PSK /etc/ipsec.secrets
   ```
   и пересоздайте подключение с правильным ключом:
   ```powershell
   powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Name MyVPN -Remove
   powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Server ... -User ... -Password ... -Psk ...
   ```

2. **Клиент за NAT (домашний роутер)** — нужна правка реестра (скрипт делает её сам):
   ```
   HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent → AssumeUDPEncapsulationContextOnSendRule = 2
   ```
   После правки: `Restart-Service PolicyAgent` (или перезагрузка).

3. **Провайдер блокирует IKE** (UDP 500/4500). Проверка на сервере:
   ```bash
   journalctl -u strongswan-starter -n 30 | grep -i 'received packet'
   ```
   Если при попытке подключения **нет строк о пакетах** — IKE не доходит,
   используйте альтернативный режим `server/install-singbox.sh` (VLESS+TLS).

### Ошибка 691 — неверный логин/пароль

Проверьте `/etc/ppp/chap-secrets` и логин при подключении.

### Ошибка 809 / 720 — соединение не устанавливается

* На сервере проверьте, что `xl2tpd` активен: `systemctl status xl2tpd`
* Порт 1701/udp должен быть открыт (скрипт открывает сам).

### Windows просит логин и пароль при включении VPN

Так быть не должно: установщик (`client/install-client-vpn.bat`) сохраняет
логин и пароль в RAS, и Windows подключается без вопросов.

Если всё-таки спрашивает — значит креды не сохранились (например, подключение
создавали вручную). Лечится повторным запуском установщика с данными:

```bat
client\install-client-vpn.bat <IP> vpnuser <ПАРОЛЬ> <PSK>
```

…либо разовым вводом пароля в окне Windows с галочкой «Сохранить данные для входа».
Проверить, что Windows считает пароль сохранённым:

```powershell
(Get-VpnConnection -Name MyVPN).RememberCredential      # должно быть True
```

## После подключения пропал интернет

Значит, трафик уходит в туннель, но сервер его не пропускает дальше. На сервере:

```bash
iptables -L FORWARD -n | head -3          # policy должна быть ACCEPT
iptables -t nat -L POSTROUTING -n | grep MASQUERADE
sysctl net.ipv4.ip_forward                # должно быть 1
```

Самая частая причина — **UFW ставит `FORWARD = DROP`**. Скрипт установки это
исправляет (`DEFAULT_FORWARD_POLICY="ACCEPT"` + NAT в `/etc/ufw/before.rules`).
Если правили вручную:

```bash
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw reload
```

Отключить VPN аварийно: `rasdial "MyVPN" /disconnect`.

## Открываются не все сайты (например, «тяжёлые» с картинками)

Это MTU/MSS. Проверьте на сервере:

```bash
grep -E '^(mtu|mru)' /etc/ppp/options.xl2tpd        # должно быть 1300
iptables -t mangle -L FORWARD -n -v | grep TCPMSS  # должно быть set 1240
```

Если нет — уменьшите MTU: `bash server/install-vpn.sh --mtu 1250` и переподключитесь.

## YouTube/Discord не открываются через VPN

* Сервер должен иметь доступ к этим сайтам — проверьте на сервере:
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://discord.com
  ```
* Если сервер в России, часть сервисов может блокировать российские IP —
  тогда нужен VPS в Европе (достаточно поменять `-Server` у клиента и
  переустановить сервер на новом VPS).

## Диагностика: где ломается

```powershell
# клиент
powershell -ExecutionPolicy Bypass -File client\Add-Vpn.ps1 -Name MyVPN -Status
```
```bash
# сервер
ipsec statusall
journalctl -u strongswan-starter -n 50
journalctl -u xl2tpd -n 50
```
