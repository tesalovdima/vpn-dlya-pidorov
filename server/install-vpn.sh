#!/usr/bin/env bash
# =============================================================================
#  VPN-сервер за одну команду: L2TP/IPsec (нативное подключение Windows)
#  Проверено на Ubuntu 24.04. Работает через DPI, поддерживает UDP (игры).
#
#  Запуск на сервере (root):
#     bash server/install-vpn.sh
#
#  Параметры:
#     --user  ИМЯ          логин VPN (по умолчанию vpnuser)
#     --pass  ПАРОЛЬ       пароль (по умолчанию сгенерируется)
#     --psk   КЛЮЧ         общий ключ IPsec (по умолчанию сгенерируется)
#     --mtu   1300         MTU внутри туннеля
#     --uninstall          удалить VPN
# =============================================================================
set -euo pipefail

VPN_USER="vpnuser"
VPN_PASS=""
PSK=""
MTU="1300"
UNINSTALL=0
POOL="10.10.10.0/24"
LOCAL_IP="10.10.10.1"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'
info() { echo -e "${CYN}[*]${NC} $*"; }
ok()   { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) VPN_USER="${2:?}"; shift 2 ;;
    --pass) VPN_PASS="${2:?}"; shift 2 ;;
    --psk)  PSK="${2:?}"; shift 2 ;;
    --mtu)  MTU="${2:?}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash server/install-vpn.sh"

# ---------------------------------------------------------------- uninstall
if [[ $UNINSTALL -eq 1 ]]; then
  info "Удаляю L2TP/IPsec VPN..."
  systemctl stop xl2tpd strongswan-starter 2>/dev/null || true
  systemctl disable xl2tpd strongswan-starter 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge strongswan strongswan-starter xl2tpd >/dev/null 2>&1 || true
  rm -f /etc/ipsec.conf /etc/ipsec.secrets /etc/ppp/chap-secrets /etc/ppp/options.xl2tpd \
        /etc/xl2tpd/xl2tpd.conf /etc/sysctl.d/99-l2tp-vpn.conf /etc/iproute2/rt_tables.bak 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s ${POOL} -o "$(ip route get 1.1.1.1 | awk '{print $5; exit}')" -j MASQUERADE 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true
  ok "VPN удалён"
  exit 0
fi

[[ -n "$VPN_PASS" ]] || VPN_PASS="$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 14)"
[[ -n "$PSK" ]]      || PSK="$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 20)"

info "Система: $(uname -srm)"
info "Устанавливаю strongSwan + xl2tpd..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq strongswan xl2tpd ppp iptables openssl curl >/dev/null

WAN="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
WAN="${WAN:-eth0}"
PUB_IP="$(curl -s4 --max-time 10 https://api.ipify.org || echo SERVER_IP)"
ok "Внешний интерфейс: $WAN, IP: $PUB_IP"

# ---------------------------------------------------------------- IPsec
cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=no
    charondebug="ike 1, knl 1, cfg 0"

conn %default
    keyexchange=ikev1
    authby=secret
    keyingtries=3
    ikelifetime=8h
    keylife=1h
    rekey=no
    # pfs не указываем: PFS выключен, поскольку в esp нет DH-группы
    mobike=no

conn L2TP-PSK
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    auto=add
    ike=aes256-sha256-modp2048,aes256-sha1-modp2048,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha256,aes256-sha1,aes128-sha1,3des-sha1!
EOF

cat > /etc/ipsec.secrets <<EOF
: PSK "$PSK"
EOF
chmod 600 /etc/ipsec.secrets

# ---------------------------------------------------------------- xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
access control = no

[lns default]
ip range = 10.10.10.2-10.10.10.254
local ip = ${LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 1.1.1.1
ms-dns 8.8.8.8
asyncmap 0
auth
crtscts
lock
hide-password
modem
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu ${MTU}
mru ${MTU}
EOF

cat > /etc/ppp/chap-secrets <<EOF
${VPN_USER} * ${VPN_PASS} *
EOF
chmod 600 /etc/ppp/chap-secrets

# ---------------------------------------------------------------- sysctl
cat > /etc/sysctl.d/99-l2tp-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_no_pmtu_disc = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
# BBR — это модуль ядра. Если его нет (например, установлено другое ядро),
# sysctl вернёт ошибку; это не критично, ядро останется на cubic.
modprobe tcp_bbr 2>/dev/null || true
sysctl -q -p /etc/sysctl.d/99-l2tp-vpn.conf 2>/dev/null || warn 'часть параметров ядра недоступна — не критично'
ok "IP forwarding + BBR включены"

# ---------------------------------------------------------------- firewall
# ВАЖНО: ufw по умолчанию ставит FORWARD=DROP, из-за этого VPN-клиенты
# остаются без интернета. Разрешаем форвардинг.
if [[ -f /etc/default/ufw ]]; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi
if [[ -f /etc/ufw/before.rules ]] && ! grep -q '10.10.10.0/24' /etc/ufw/before.rules; then
  python3 - <<PY
p='/etc/ufw/before.rules'
s=open(p).read()
s="""*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${POOL} -o ${WAN} -j MASQUERADE
COMMIT

"""+s
open(p,'w').write(s)
PY
  ufw reload >/dev/null 2>&1 || true
fi

iptables -C FORWARD -i ppp+ -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ppp+ -j ACCEPT
iptables -C FORWARD -o ppp+ -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ppp+ -j ACCEPT
iptables -t nat -C POSTROUTING -s ${POOL} -o ${WAN} -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s ${POOL} -o ${WAN} -j MASQUERADE
# MSS clamping — без него большие сайты (Instagram и т.п.) не грузятся
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o ppp+ -j TCPMSS --set-mss 1240 2>/dev/null || \
  iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -o ppp+ -j TCPMSS --set-mss 1240
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i ppp+ -j TCPMSS --set-mss 1240 2>/dev/null || \
  iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -i ppp+ -j TCPMSS --set-mss 1240
for p in 500 4500 1701; do
  iptables -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $p -j ACCEPT
done
if command -v ufw >/dev/null 2>&1; then
  ufw allow 500/udp  >/dev/null 2>&1 || true
  ufw allow 4500/udp >/dev/null 2>&1 || true
  ufw allow 1701/udp >/dev/null 2>&1 || true
fi
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
netfilter-persistent save >/dev/null 2>&1 || true
ok "Firewall и NAT настроены"

# ---------------------------------------------------------------- start
systemctl enable strongswan-starter >/dev/null 2>&1 || systemctl enable strongswan >/dev/null 2>&1
systemctl enable xl2tpd >/dev/null 2>&1
systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan
systemctl restart xl2tpd
sleep 3

# strongswan-starter на Ubuntu — oneshot-служба: она остаётся "inactive",
# хотя charon (сам IPsec-демон) работает. Проверяем именно charon.
ipsec start >/dev/null 2>&1 || true
sleep 2
XL2="$(systemctl is-active xl2tpd || true)"
ipsec status >/dev/null 2>&1 || die "IPsec (charon) не запустился"
[[ "$XL2" == "active" ]] || die "xl2tpd не запустился: $XL2"
ok "IPsec (charon) и xl2tpd работают"

cat > /root/vpn-info.txt <<EOF
# ===== L2TP/IPsec VPN =====
server=${PUB_IP}
login=${VPN_USER}
password=${VPN_PASS}
psk=${PSK}
mtu=${MTU}
# =========================
EOF
chmod 600 /root/vpn-info.txt

echo
echo -e "${BLD}${GRN}ГОТОВО. VPN-сервер работает.${NC}"
echo "  Сервер:   ${PUB_IP}"
echo "  Логин:    ${VPN_USER}"
echo "  Пароль:   ${VPN_PASS}"
echo "  Ключ PSK: ${PSK}"
echo
echo "Windows (от администратора):"
echo "  powershell -ExecutionPolicy Bypass -File client\\Add-Vpn.ps1 -Server ${PUB_IP} -User ${VPN_USER} -Password ${VPN_PASS} -Psk ${PSK}"
echo
echo "Все данные сохранены в /root/vpn-info.txt"

# машиночитаемый вывод — его разбирает deploy.ps1
echo "server=${PUB_IP}"
echo "login=${VPN_USER}"
echo "password=${VPN_PASS}"
echo "psk=${PSK}"
echo "mtu=${MTU}"
