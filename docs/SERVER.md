# Работа с сервером

## Файлы

| Путь | Назначение |
|---|---|
| `/usr/local/etc/xray/config.json` | конфиг Xray (inbound VLESS-Reality) |
| `/root/.vpn-params` | UUID, ключи Reality, shortId, порт |
| `/root/vpn-info.txt` | готовая ссылка `vless://` + сводка |
| `/etc/sysctl.d/99-vpn-tuning.conf` | BBR, fq, буферы |

## Основные команды

```bash
systemctl status xray            # состояние службы
systemctl restart xray           # перезапуск
systemctl stop xray              # остановка
journalctl -u xray -n 100 -f     # логи в реальном времени
xray run -test -c /usr/local/etc/xray/config.json   # проверка конфига
xray version                     # версия
```

## Переустановка с новыми ключами

```bash
bash install.sh --force            # новые UUID/ключи/конфиг
bash install.sh --port 8443 --force
bash install.sh --sni www.samsung.com --force
bash install.sh --uninstall        # полное удаление
```

## Добавить второго пользователя (отдельный UUID)

Несколько клиентов удобно разводить по UUID — тогда можно отключить один, не
задев остальные.

1. Сгенерируйте UUID:
   ```bash
   xray uuid
   ```
2. Добавьте объект в `settings.clients` в `/usr/local/etc/xray/config.json`:
   ```json
   {
     "id": "<НОВЫЙ_UUID>",
     "flow": "xtls-rprx-vision",
     "email": "phone"
   }
   ```
3. Проверьте и перезапустите:
   ```bash
   xray run -test -c /usr/local/etc/xray/config.json && systemctl restart xray
   ```
4. Соберите ссылку, заменив UUID в старой:
   ```
   vless://<НОВЫЙ_UUID>@<IP>:<PORT>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<SNI>&fp=chrome&pbk=<PUBLIC_KEY>&sid=<SHORT_ID>&type=tcp#phone
   ```

## Второй порт (если провайдер режет основной)

Добавьте ещё один inbound с тем же `privateKey`/`shortIds`, но другим портом и
`dest`, затем откройте порт:

```bash
# скопируйте блок inbound, измените "port" и "tag"
nano /usr/local/etc/xray/config.json
xray run -test -c /usr/local/etc/xray/config.json && systemctl restart xray
ufw allow 8443/tcp
```

## Проверка, что UDP-туннель живой (на сервере)

```bash
ss -tnp | grep xray | head            # активные сессии
tail -f /var/log/xray/error.log       # ошибки Reality
```

## Мониторинг трафика (опционально)

В `config.json` включите статистику и API:

```json
"api": { "tag": "api", "services": ["StatsService"] },
"stats": {},
"policy": { "system": { "statsInboundUplink": true, "statsInboundDownlink": true } }
```

и смотрите через `xray api statsquery --server=127.0.0.1:10085 -pattern ""`.

## Бэкап

Достаточно двух файлов:

```bash
tar czf /root/vpn-backup.tgz /usr/local/etc/xray/config.json /root/.vpn-params /root/vpn-info.txt
```
