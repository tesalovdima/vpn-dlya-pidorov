# Безопасность (прочитайте обязательно)

## 1. Смените пароль root сервера

Пароль, который вы где-либо передавали в открытом виде, считается
скомпрометированным:

```bash
passwd                       # новый пароль: 20+ символов
```

## 2. SSH: только по ключу

На своём компьютере (ключ создаётся один раз):

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\vpn_deploy -N '""'
type $env:USERPROFILE\.ssh\vpn_deploy.pub
```

На сервере:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA...ваш_ключ...' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Проверьте вход по ключу **в новом окне**, и только затем:

```bash
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
```

## 3. Firewall

VPN-скрипт сам открывает только нужное: `500/udp`, `4500/udp`, `1701/udp`.
Проверьте:

```bash
ufw status
iptables -L INPUT -n | head
```

Не открывайте лишние порты (панели, БД, Docker API).

## 4. Пароль VPN-подключения

* Логин/пароль VPN и PSK лежат в `/root/vpn-info.txt` (права `600`).
* Сменить пароль:
  ```bash
  nano /etc/ppp/chap-secrets     # отредактируйте строку cn * пароль *
  systemctl restart xl2tpd
  ```
  Затем пересоздайте подключение на клиенте.
* Сменить PSK:
  ```bash
  nano /etc/ipsec.secrets        # : PSK "новый_ключ"
  ipsec restart
  ```
  Затем на клиенте: `client\Add-Vpn.ps1 -Remove` и создать заново с новым PSK.

## 5. Обновления и защита от перебора

```bash
apt update && apt -y upgrade
apt -y install fail2ban
systemctl enable --now fail2ban
```

Для защиты L2TP от перебора пароля добавьте ограничение попыток:

```bash
# не более 5 попыток MSCHAP за 10 минут
grep -q refuse-mschap /etc/ppp/options.xl2tpd || cat >> /etc/ppp/options.xl2tpd <<'EOF'
refuse-mschap
EOF
systemctl restart xl2tpd
```

## 6. Ограничения L2TP/IPsec (и когда нужен другой протокол)

* IPsec с общим ключом (PSK) и MSCHAPv2 — **не самый стойкий** вариант:
  трафик шифруется (AES), но аутентификация слабее, чем в TLS-схемах.
  Для домашнего использования этого достаточно; для параноидальных сценариев
  используйте `server/install-singbox.sh` (VLESS + TLS).
* Не публикуйте PSK/пароли: любой, кто их знает, имеет доступ к вашему VPN.

## 7. Не храните секреты в git

В репозитории **нет** паролей, ключей и ссылок подключения. Не коммитьте
`vpn-info.txt`, `*.vless-link`, `*.ss-link` — они перечислены в `.gitignore`.
