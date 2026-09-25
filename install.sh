#!/usr/bin/env bash
# =============================================================================
#  VLESS + XTLS-REALITY  —  установка VPN-сервера одной командой
#  Подходит для обхода блокировок в РФ: трафик неотличим от обычного HTTPS
#  к крупному зарубежному сайту (SNI-маскировка), поддерживает UDP (для игр).
#
#  Использование (на сервере, от root):
#     bash install.sh
#
#  Параметры:
#     --port 443          порт (по умолчанию 443)
#     --sni www.microsoft.com   маскировочный домен
#     --name MyVPN        имя профиля в ссылке
#     --force             перегенерировать ключи и конфиг заново
#     --uninstall         удалить Xray и настройки
#     --help
# =============================================================================
set -euo pipefail

PORT=443
SNI=""
PROFILE_NAME="VPN-Reality"
FORCE=0
UNINSTALL=0

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
PARAMS_FILE="/root/.vpn-params"        # uuid / keys / sni / shortid / port
INFO_FILE="/root/vpn-info.txt"         # итоговая ссылка + инструкции
SYSCTL_FILE="/etc/sysctl.d/99-vpn-tuning.conf"

# Кандидаты SNI: доступны из РФ, TLS 1.3 + HTTP/2, крупные CDN
SNI_CANDIDATES=(
  "www.microsoft.com"
  "www.samsung.com"
  "www.apple.com"
  "www.bing.com"
  "www.lovelive-anime.jp"
  "dl.google.com"
)

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'
info() { echo -e "${CYN}[*]${NC} $*"; }
ok()   { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
hr()   { echo -e "${BLD}------------------------------------------------------------${NC}"; }

# ----------------------------------------------------------------------------
# Аргументы
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="${2:?}"; shift 2 ;;
    --sni)       SNI="${2:?}"; shift 2 ;;
    --name)      PROFILE_NAME="${2:?}"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root:  sudo bash install.sh"

# ----------------------------------------------------------------------------
# Определение ОС / пакетного менеджера
# ----------------------------------------------------------------------------
PKG=""
detect_pkg() {
  for m in apt-get dnf yum apk pacman zypper; do
    if command -v "$m" >/dev/null 2>&1; then PKG="$m"; return; fi
  done
}
detect_pkg
[[ -n "$PKG" ]] || warn "Не удалось определить пакетный менеджер, ставлю только то, что есть"

pkg_install() {
  case "$PKG" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true ;;
    dnf|yum) "$PKG" install -y "$@" >/dev/null 2>&1 || true ;;
    apk)     apk add --no-cache "$@" >/dev/null 2>&1 || true ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 || true ;;
    zypper)  zypper -n install "$@" >/dev/null 2>&1 || true ;;
  esac
}

init_system() {
  info "Система: $(uname -srm)"
  if [[ "$PKG" == "apt-get" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
  fi
  pkg_install curl ca-certificates openssl unzip tar
  pkg_install qrencode || true
}

# ----------------------------------------------------------------------------
# Удаление
# ----------------------------------------------------------------------------
do_uninstall() {
  info "Удаляю Xray и настройки..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
  rm -f "$PARAMS_FILE" "$INFO_FILE" "$SYSCTL_FILE"
  pkg_install >/dev/null 2>&1 || true
  ok "Готово. Служба и конфиги удалены."
  exit 0
}

# ----------------------------------------------------------------------------
# Сетевой тюнинг: BBR, fq, fastopen, большие буферы (важно для игр/UDP)
# ----------------------------------------------------------------------------
tune_network() {
  info "Тюнинг сети (BBR + fq)..."
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    warn "BBR недоступен в этом ядре — оставляю cubic"
    CC="cubic"
  else
    CC="bbr"
  fi
  cat > "$SYSCTL_FILE" <<EOF
# ==== VPN/игровой тюнинг (создано install.sh) ====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
EOF
  sysctl -q -p "$SYSCTL_FILE" 2>/dev/null || true
  ok "Конгестия: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?'), qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
}

# ----------------------------------------------------------------------------
# Установка Xray
# ----------------------------------------------------------------------------
install_xray() {
  if command -v xray >/dev/null 2>&1; then
    ok "Xray уже установлен: $(xray version 2>/dev/null | head -n1)"
    return
  fi
  info "Скачиваю и устанавливаю Xray-core (официальный скрипт)..."
  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/xray-install.log 2>&1; then
    tail -n 20 /tmp/xray-install.log >&2 || true
    die "Не удалось установить Xray. Смотри /tmp/xray-install.log"
  fi
  command -v xray >/dev/null 2>&1 || die "Бинарник xray не найден после установки"
  ok "Xray установлен: $(xray version 2>/dev/null | head -n1)"
}

# ----------------------------------------------------------------------------
# Генерация параметров
# ----------------------------------------------------------------------------
gen_reality_keys() {  # -> REALITY_PRIV, REALITY_PUB
  local out priv pub
  out="$(xray x25519 2>/dev/null || true)"
  priv="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*[Pp]rivate ?[Kk]ey:?[[:space:]]+([^[:space:]]+).*/\1/p' | head -n1)"
  pub="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*[Pp]ublic ?[Kk]ey:?[[:space:]]+([^[:space:]]+).*/\1/p' | head -n1)"

  # старые сборки: "Private key: X" / "Public key: Y" — уже покрыто выше
  # новые сборки (25.8+): "PrivateKey: X" / "Password: Y" — берём токены позиционно
  if [[ -z "$priv" || -z "$pub" ]]; then
    local tokens
    tokens="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9+/=_-]{40,64}' || true)"
    priv="${priv:-$(printf '%s\n' "$tokens" | sed -n '1p')}"
    pub="${pub:-$(printf '%s\n' "$tokens" | sed -n '2p')}"
  fi
  # производный публичный ключ (на случай, если вывели только приватный)
  if [[ -z "$pub" && -n "$priv" ]]; then
    out="$(xray x25519 -i "$priv" 2>/dev/null || true)"
    pub="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*([Pp]ublic ?[Kk]ey|[Pp]assword):?[[:space:]]+([^[:space:]]+).*/\2/p' | head -n1)"
  fi
  [[ -n "$priv" && -n "$pub" ]] || return 1
  REALITY_PRIV="$priv"; REALITY_PUB="$pub"
}

load_or_create_params() {
  if [[ $FORCE -eq 0 && -f "$PARAMS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PARAMS_FILE"
    ok "Использую существующие параметры из $PARAMS_FILE (--force чтобы перегенерировать)"
    return
  fi
  info "Генерирую ключи и UUID..."
  UUID="$(xray uuid)"
  gen_reality_keys || die "Не удалось сгенерировать ключи REALITY (проверьте вывод 'xray x25519')"
  SHORT_ID="$(openssl rand -hex 8)"
  {
    echo "UUID=$UUID"
    echo "REALITY_PRIV=$REALITY_PRIV"
    echo "REALITY_PUB=$REALITY_PUB"
    echo "SHORT_ID=$SHORT_ID"
    echo "PORT=$PORT"
  } > "$PARAMS_FILE"
  chmod 600 "$PARAMS_FILE"
  ok "UUID: $UUID"
  ok "Short ID: $SHORT_ID"
}

# ----------------------------------------------------------------------------
# Выбор SNI (маскировочного домена) и проверка доступности с сервера
# ----------------------------------------------------------------------------
check_sni() {
  local host="$1"
  curl -sS -o /dev/null --max-time 6 --tlsv1.3 "https://${host}" >/dev/null 2>&1
}

pick_sni() {
  if [[ -n "$SNI" ]]; then
    if check_sni "$SNI"; then ok "SNI: $SNI (доступен)"; else warn "SNI $SNI недоступен с сервера, но оставляю как задано"; fi
    return
  fi
  info "Подбираю маскировочный домен (SNI)..."
  local c
  for c in "${SNI_CANDIDATES[@]}"; do
    if check_sni "$c"; then SNI="$c"; ok "SNI: $c"; return; fi
  done
  SNI="${SNI_CANDIDATES[0]}"
  warn "Ни один кандидат не ответил, беру $SNI на свой риск"
}

# ----------------------------------------------------------------------------
# Порт
# ----------------------------------------------------------------------------
check_port() {
  local busy=""
  if command -v ss >/dev/null 2>&1; then
    busy="$(ss -Hlntup 2>/dev/null | awk -v p=":${PORT}\$" '$5 ~ p {print $1" "$5}' | head -n3)"
  fi
  if [[ -n "$busy" ]]; then
    warn "Порт ${PORT} уже занят:"
    echo "    $busy"
    warn "Если это nginx/apache — освободите порт или запустите: bash $0 --port 8443"
    die "Порт ${PORT} недоступен"
  fi
  ok "Порт ${PORT} свободен"
}

# ----------------------------------------------------------------------------
# Конфиг Xray
# ----------------------------------------------------------------------------
write_config() {
  info "Пишу конфиг ${XRAY_CONFIG}..."
  mkdir -p "$XRAY_DIR" /var/log/xray
  [[ -f "$XRAY_CONFIG" ]] && cp -f "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)" || true

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "user@${PROFILE_NAME}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${SHORT_ID}" ]
        },
        "tcpSettings": {
          "acceptProxyProtocol": false,
          "header": { "type": "none" }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }
    ]
  }
}
EOF
  chmod 644 "$XRAY_CONFIG"

  # Проверка валидности конфига
  if xray run -test -c "$XRAY_CONFIG" >/tmp/xray-test.log 2>&1 || xray -test -config "$XRAY_CONFIG" >/tmp/xray-test.log 2>&1; then
    ok "Конфиг валиден"
  else
    cat /tmp/xray-test.log >&2 || true
    die "Конфиг не прошёл проверку"
  fi
}

# ----------------------------------------------------------------------------
# Firewall
# ----------------------------------------------------------------------------
open_firewall() {
  info "Открываю порт ${PORT} в firewall..."
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
    ok "ufw: разрешён ${PORT}/tcp+udp"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld: разрешён ${PORT}/tcp+udp"
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
    ok "iptables: разрешён ${PORT}/tcp+udp"
  else
    warn "Firewall не найден — порт ${PORT} должен быть открыт в панели хостера"
  fi
}

# ----------------------------------------------------------------------------
# Служба
# ----------------------------------------------------------------------------
restart_service() {
  info "Запускаю службу xray..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray || die "Служба xray не запустилась (journalctl -u xray -n 50)"
  sleep 2
  systemctl is-active --quiet xray || die "Служба xray не активна (journalctl -u xray -n 50)"
  ok "Служба xray активна"
}

# ----------------------------------------------------------------------------
# Внешний IP
# ----------------------------------------------------------------------------
get_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com"; do
    ip="$(curl -s4 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  echo "${ip:-SERVER_IP}"
}

# ----------------------------------------------------------------------------
# Итоговая ссылка
# ----------------------------------------------------------------------------
build_link() {
  local host="$1"
  LINK="vless://${UUID}@${host}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#${PROFILE_NAME}"
}

print_result() {
  local host="$1"
  hr
  echo -e "${BLD}${GRN} ГОТОВО. VPN-сервер поднят.${NC}"
  hr
  echo -e "${BLD}Сервер:${NC}   ${host}:${PORT}"
  echo -e "${BLD}Протокол:${NC} VLESS + XTLS-Reality (vision), маскировка под ${SNI}"
  echo -e "${BLD}UUID:${NC}     ${UUID}"
  echo -e "${BLD}Public key:${NC} ${REALITY_PUB}"
  echo -e "${BLD}Short ID:${NC}   ${SHORT_ID}"
  echo
  echo -e "${BLD}Строка подключения (vless://):${NC}"
  echo -e "${CYN}${LINK}${NC}"
  echo

  if command -v qrencode >/dev/null 2>&1; then
    echo -e "${BLD}QR-код (v2rayN / v2rayNG / streisand / Hiddify):${NC}"
    qrencode -t ANSIUTF8 "$LINK" || true
    echo
  fi

  cat > "$INFO_FILE" <<EOF
# ==== VLESS Reality VPN ====
# Создано: $(date -Is)
Сервер:     ${host}:${PORT}
SNI:        ${SNI}
UUID:       ${UUID}
Public key: ${REALITY_PUB}
Short ID:   ${SHORT_ID}

Строка подключения:
${LINK}

Windows (одна команда, от администратора):
  powershell -ExecutionPolicy Bypass -File client\setup-windows.ps1 -Link "${LINK}"
EOF
  chmod 600 "$INFO_FILE"

  echo -e "${BLD}Что дальше:${NC}"
  echo "  1) Windows — VPN + League of Legends: см. docs/LOL.md"
  echo "     powershell -ExecutionPolicy Bypass -File client\\setup-windows.ps1 -Link \"<ссылка выше>\""
  echo "  2) Телефон — импортируйте ссылку в v2rayNG / Streisand / Hiddify"
  echo "  3) Все данные сохранены в ${INFO_FILE}"
  hr
  echo -e "${YLW}Безопасность:${NC} смените root-пароль сервера и отключите вход по паролю (docs/SECURITY.md)"
}

# ----------------------------------------------------------------------------
main() {
  hr
  echo -e "${BLD} VLESS + XTLS-Reality: установка VPN-сервера${NC}"
  hr
  [[ $UNINSTALL -eq 1 ]] && do_uninstall
  init_system
  tune_network
  install_xray
  load_or_create_params
  pick_sni
  check_port
  write_config
  open_firewall
  restart_service
  IP="$(get_public_ip)"
  build_link "$IP"
  print_result "$IP"
}

main "$@"
