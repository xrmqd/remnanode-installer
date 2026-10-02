#!/usr/bin/env bash
# Unified VPN node installer. Run: sudo bash vpn-install.sh
# Ubuntu 22.04/24.04, Debian 12/13; systemd; amd64/arm64.
# Installs Remnanode 2.8.0, Caddy + Gcore DNS, BBR, Psiphon and free WARP.
# Only three inputs; existing installations from this script can be rerun.
# Sources inspected 2026-10-01:
# https://github.com/Capybara-z/RemnaSetup/tree/55495e9783b8388a48e6580ff4c2c26a3eafa08f
# https://github.com/caddy-dns/gcore
# https://github.com/ViRb3/wgcf
# Psiphon/WARP installation behavior reviewed from the two user-provided
# sh.ghostos.space scripts. This script does not execute those installers.
#
# RemnaSetup configuration/site attribution:
# MIT License; Copyright (c) 2024 Capybara
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

set +x
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

MANAGED_TAG='unified-vpn-installer-v1'
STATE_DIR=/var/lib/unified-vpn-installer
NODE_IMAGE=remnawave/node:2.8.0
MIN_GO_VERSION=1.25
REMNA_COMMIT=55495e9783b8388a48e6580ff4c2c26a3eafa08f
LOG='' TMP_DIR='' BACKUP_DIR='' STAGE='Проверки' PSIPHON_BIND='' UI_FD=2
GCORE_TOKEN='' NODE_TOKEN='' SNI_DOMAIN=''
CYAN='' GREEN='' RED='' BOLD='' RESET=''

note() { printf '  %s\n' "$*"; }
fail() { printf '\n%sОШИБКА%s: %s\n' "$RED" "$RESET" "$*" >&"$UI_FD"; exit 1; }
stage() {
    STAGE="$2"
    printf '\n%s────────────────────────────────────────────────────────%s\n' "$CYAN" "$RESET"
    printf '%s[%02d/08]%s %s%s%s\n' "$CYAN" "$1" "$RESET" "$BOLD" "$2" "$RESET"
    printf '%s────────────────────────────────────────────────────────%s\n' "$CYAN" "$RESET"
}
run() { "$@" </dev/null; }

on_error() {
    local code="$1" line="$2"
    trap - ERR
    printf '\nОШИБКА на этапе «%s» (строка %s, код %s).\n' "$STAGE" "$line" "$code" >&"$UI_FD"
    [[ -z "$LOG" ]] || printf 'Журнал (доступен root): %s\n' "$LOG" >&"$UI_FD"
    [[ -z "$BACKUP_DIR" ]] || printf 'Резервные копии: %s\n' "$BACKUP_DIR" >&"$UI_FD"
    exit "$code"
}

cleanup() {
    unset GCORE_TOKEN NODE_TOKEN
    [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}

backup() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        mkdir -p -- "$BACKUP_DIR$(dirname "$path")"
        cp -a -- "$path" "$BACKUP_DIR$path"
    fi
}

download() {
    curl --fail --progress-bar --show-error --location --retry 3 --connect-timeout 15 \
        --max-time 300 --proto '=https' --proto-redir '=https' "$1" -o "$2"
}

preflight() {
    [[ "$(uname -s)" == Linux ]] || fail 'Этот установщик предназначен для Linux VPS.'
    [[ "$EUID" -eq 0 ]] || fail 'Запустите: sudo bash vpn-install.sh'
    [[ "${BASH_VERSINFO[0]}" -ge 4 ]] || fail 'Нужен Bash 4 или новее.'
    [[ -d /run/systemd/system ]] || fail 'Нужна система с systemd.'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID:$VERSION_ID" in
        ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
        *) fail 'Поддерживаются Ubuntu 22.04/24.04 и Debian 12/13.' ;;
    esac
    OS_ID="$ID" OS_CODENAME="${VERSION_CODENAME:-}"
    [[ "$OS_CODENAME" =~ ^[a-z]+$ ]] || fail 'Не удалось определить кодовое имя системы.'
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in amd64|arm64) ;; *) fail 'Поддерживаются amd64 и arm64.' ;; esac
    command -v flock >/dev/null || fail 'Отсутствует flock из util-linux.'
    exec 9>/run/lock/unified-vpn-installer.lock
    flock -n 9 || fail 'Другой экземпляр установщика уже запущен.'
    local overrides
    overrides="$(systemctl show caddy.service -p DropInPaths --value 2>/dev/null || true)"
    [[ -z "$overrides" ]] || fail 'Обнаружены дополнительные настройки caddy.service (drop-in). Нужен отдельный разбор существующей службы.'

    if [[ ! -f "$STATE_DIR/owner" ]] || [[ "$(cat "$STATE_DIR/owner")" != "$MANAGED_TAG" ]]; then
        command -v caddy >/dev/null && fail 'Caddy уже установлен другим способом; нужен чистый VPS.'
        [[ -z "$(systemctl show caddy.service -p FragmentPath --value 2>/dev/null || true)" ]] || \
            fail 'Найдена прежняя служба Caddy; нужен чистый VPS.'
        local path
        for path in /etc/caddy/Caddyfile /etc/systemd/system/caddy.service \
            /opt/remnanode/compose.yaml /opt/remnanode/compose.yml \
            /opt/remnanode/docker-compose.yaml /opt/remnanode/docker-compose.yml \
            /etc/wireguard/warp.conf /etc/default/ghost-warp /etc/default/ghost-psiphon \
            /var/www/site/index.html; do
            [[ ! -e "$path" ]] || fail "Найдена прежняя установка: $path. Нужен чистый VPS или повторный запуск именно этого установщика."
        done
        if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
            if docker container inspect remnanode >/dev/null 2>&1; then
                fail 'Контейнер remnanode уже существует и создан другим установщиком.'
            fi
        fi
        local port
        for port in 80 8443 3001 2019; do
            if command -v ss >/dev/null && [[ -n "$(ss -H -ltn "sport = :$port")" ]]; then
                fail "Порт $port уже занят. Установка остановлена до изменений."
            fi
        done
    fi
}

valid_token() { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; }
valid_domain() {
    local domain="$1" label
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ && ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
}

normalize_sni_domain() {
    # Terminal paste can add CR, non-breaking spaces or zero-width marks.
    SNI_DOMAIN="${SNI_DOMAIN//$'\r'/}"
    SNI_DOMAIN="${SNI_DOMAIN//$'\302\240'/ }"
    SNI_DOMAIN="${SNI_DOMAIN//$'\342\200\213'/}"
    SNI_DOMAIN="${SNI_DOMAIN//$'\357\273\277'/}"
    SNI_DOMAIN="${SNI_DOMAIN#"${SNI_DOMAIN%%[![:space:]]*}"}"
    SNI_DOMAIN="${SNI_DOMAIN%"${SNI_DOMAIN##*[![:space:]]}"}"
    SNI_DOMAIN="$(printf '%s' "$SNI_DOMAIN" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    SNI_DOMAIN="${SNI_DOMAIN%.}"
}

read_inputs() {
    [[ -t 0 ]] || fail 'Запускайте сохранённый файл в терминале: sudo bash vpn-install.sh'
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        CYAN=$'\033[36m' GREEN=$'\033[32m' RED=$'\033[31m'
        BOLD=$'\033[1m' RESET=$'\033[0m'
    fi
    printf '\n%s╭──────────────────────────────────────────────────────╮%s\n' "$CYAN" "$RESET"
    printf '%s│%s  %sVPN NODE%s                                            %s│%s\n' "$CYAN" "$RESET" "$BOLD" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s  Remnanode 2.8.0 · Caddy/Gcore · Psiphon · WARP      %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s╰──────────────────────────────────────────────────────╯%s\n\n' "$CYAN" "$RESET"
    printf 'Введите три параметра и нажмите Enter после каждого.\n\n'
    IFS= read -r -p '  1/3  Gcore API token: ' GCORE_TOKEN || fail 'Ввод прерван.'
    valid_token "$GCORE_TOKEN" || fail 'Gcore token пуст или содержит пробелы/неожиданные символы.'
    IFS= read -r -p '  2/3  PublicKey / токен ноды из панели Remnawave: ' NODE_TOKEN || fail 'Ввод прерван.'
    valid_token "$NODE_TOKEN" || fail 'Токен ноды пуст или содержит пробелы/неожиданные символы.'
    IFS= read -r -p '  3/3  Домен для SNI (без https:// и порта): ' SNI_DOMAIN || fail 'Ввод прерван.'
    normalize_sni_domain
    valid_domain "$SNI_DOMAIN" || fail 'Нужен полный домен, например node.example.com; для IDN используйте punycode.'
    printf '\n%s✓%s Данные приняты. Дальше вопросов не будет.\n' "$GREEN" "$RESET"
}

init_workspace() {
    install -d -m 0700 "$STATE_DIR" /var/log/unified-vpn-installer
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    LOG="/var/log/unified-vpn-installer/install-$stamp.log"
    BACKUP_DIR="/var/backups/unified-vpn-installer/$stamp"
    install -d -m 0700 "$BACKUP_DIR"
    : > "$LOG"
    chmod 0600 "$LOG"
    # /opt is normally executable, unlike /tmp on hardened servers.
    TMP_DIR="$(mktemp -d /opt/.unified-vpn-build.XXXXXX)"
    printf '%s\n' "$MANAGED_TAG" > "$STATE_DIR/owner"
    note "Журнал установки: $LOG"
}

install_dependencies() {
    run apt-get -o DPkg::Lock::Timeout=180 update
    run apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold install -y \
        ca-certificates curl gnupg python3 iproute2 iputils-ping kmod \
        wireguard-tools logrotate openssl util-linux coreutils
}

validate_node_token() {
    # Remnanode 2.8.0 expects a base64 JSON bundle, not a Reality public key.
    printf '%s' "$NODE_TOKEN" | python3 -c '
import base64,json,sys
try:
    raw=sys.stdin.read()
    payload=json.loads(base64.b64decode(raw+"="*((-len(raw))%4),altchars=b"-_",validate=True))
    assert isinstance(payload,dict)
    assert all(isinstance(payload.get(k),str) and payload[k].strip()
               for k in ("caCertPem","jwtPublicKey","nodeCertPem","nodeKeyPem"))
except Exception:
    print("Нужен полный PublicKey/токен ноды из панели Remnawave, а не ключ Reality.",file=sys.stderr)
    sys.exit(1)
'
}

install_docker() {
    if ! command -v docker >/dev/null; then
        # Official signed Docker repository; no remote shell installer.
        install -d -m 0755 /etc/apt/keyrings
        run download "https://download.docker.com/linux/$OS_ID/gpg" "$TMP_DIR/docker.asc"
        install -m 0644 "$TMP_DIR/docker.asc" /etc/apt/keyrings/docker.asc
        backup /etc/apt/sources.list.d/docker.sources
        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$OS_ID
Suites: $OS_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        chmod 0644 /etc/apt/sources.list.d/docker.sources
        run apt-get -o DPkg::Lock::Timeout=180 update
        run apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold install -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    run systemctl enable --now docker
    run docker info
    docker compose version >/dev/null 2>&1 || fail 'Установленный Docker не содержит docker compose. Установите Compose plugin и повторите запуск.'
    if docker container inspect remnanode >/dev/null 2>&1; then
        [[ "$(docker inspect -f '{{index .Config.Labels "io.unified-vpn-installer.managed"}}' remnanode)" == true ]] || \
            fail 'Существующий remnanode создан другим установщиком; контейнер не изменён.'
    fi
}

install_bbr() {
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fx bbr >/dev/null; then
        run modprobe tcp_bbr
    fi
    sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fx bbr >/dev/null \
        || fail 'Ядро не поддерживает BBR.'
    backup /etc/sysctl.d/99-unified-vpn-bbr.conf
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-unified-vpn-bbr.conf
    chmod 0644 /etc/sysctl.d/99-unified-vpn-bbr.conf
    run sysctl -p /etc/sysctl.d/99-unified-vpn-bbr.conf
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'BBR не включился.'
    [[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || fail 'Очередь fq не включилась.'
}

write_node_compose() {
    # JSON is also valid YAML. $$ preserves any literal $ under Compose.
    printf '%s' "$NODE_TOKEN" | python3 -c '
import json,sys
token=sys.stdin.read().replace("$", "$$")
json.dump({"services":{"remnanode":{
    "image":"remnawave/node:2.8.0", "container_name":"remnanode",
    "hostname":"remnanode", "network_mode":"host", "restart":"always",
    "labels":{"io.unified-vpn-installer.managed":"true"},
    "cap_add":["NET_ADMIN"],
    "ulimits":{"nofile":{"soft":1048576,"hard":1048576}},
    "environment":{"NODE_PORT":"3001","SECRET_KEY":token},
    "volumes":["/var/log/remnanode:/var/log/remnanode"],
    "logging":{"driver":"json-file","options":{"max-size":"10m","max-file":"3"}}
}}},sys.stdout,indent=2)
print()
'
}

install_node() {
    install -d -m 0700 /opt/remnanode
    install -d -m 0755 /var/log/remnanode
    backup /opt/remnanode/docker-compose.yml
    write_node_compose > "$TMP_DIR/node-compose.yml"
    run docker compose -f "$TMP_DIR/node-compose.yml" config -q
    run docker pull "$NODE_IMAGE"
    install -m 0600 "$TMP_DIR/node-compose.yml" /opt/remnanode/docker-compose.yml
    backup /etc/logrotate.d/remnanode
    cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 0644 /etc/logrotate.d/remnanode
    run docker compose -p remnanode -f /opt/remnanode/docker-compose.yml up -d remnanode
    unset NODE_TOKEN
}

write_caddyfile() {
    cat <<EOF
{
    acme_dns gcore {env.GCORE_API_TOKEN}
}

$SNI_DOMAIN:8443 {
    @local remote_ip 127.0.0.1 ::1
    handle @local {
        root * /var/www/site
        try_files {path} /index.html
        file_server
    }
    handle {
        abort
    }
}
EOF
}

install_host_go() {
    local current_go='' latest_go archive
    if command -v go >/dev/null 2>&1; then
        current_go="$(go env GOVERSION | sed 's/^go//')"
    fi
    if [[ -n "$current_go" ]] && dpkg --compare-versions "$current_go" ge "$MIN_GO_VERSION"; then
        note "Использую установленный Go $current_go."
        return
    fi
    note 'Устанавливаю актуальный Go на сервере.'
    latest_go="$(curl --fail --silent --show-error --location --proto '=https' \
        --proto-redir '=https' 'https://go.dev/VERSION?m=text' | sed -n '1p')"
    [[ "$latest_go" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'Не удалось определить версию Go.'
    archive="${latest_go}.linux-${ARCH}.tar.gz"
    curl --fail --progress-bar --show-error --location --retry 3 --connect-timeout 15 \
        --max-time 900 --proto '=https' --proto-redir '=https' \
        "https://go.dev/dl/$archive" -o "$TMP_DIR/$archive"
    rm -rf -- /usr/local/go
    run tar -C /usr/local -xzf "$TMP_DIR/$archive"
    export PATH="/usr/local/go/bin:$PATH"
    current_go="$(go env GOVERSION | sed 's/^go//')"
    dpkg --compare-versions "$current_go" ge "$MIN_GO_VERSION" || \
        fail "Установленный Go $current_go ниже требуемой версии $MIN_GO_VERSION."
    note "Установлен Go $current_go."
}

install_caddy() {
    note 'Собираю Caddy с Gcore прямо на сервере через Go и xcaddy; это может занять несколько минут.'
    run apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold install -y \
        build-essential wget
    install_host_go
    install -d -m 0700 "$TMP_DIR/go-bin" "$TMP_DIR/caddy-build"
    run env GOBIN="$TMP_DIR/go-bin" go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    (
        cd "$TMP_DIR/caddy-build"
        run "$TMP_DIR/go-bin/xcaddy" build --with github.com/caddy-dns/gcore
    )
    "$TMP_DIR/caddy-build/caddy" list-modules | grep -Fx dns.providers.gcore >/dev/null \
        || fail 'В собранном Caddy нет модуля dns.providers.gcore.'

    getent group caddy >/dev/null || groupadd --system caddy
    if ! id caddy >/dev/null 2>&1; then
        useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
            --shell /usr/sbin/nologin --comment 'Caddy web server' caddy
    fi
    install -d -o caddy -g caddy -m 0750 /var/lib/caddy
    install -d -o root -g caddy -m 0750 /etc/caddy
    install -d -m 0755 /usr/local/bin /var/www/site /var/www/site/assets
    local file
    for file in index.html assets/main.js assets/style.css; do
        run download "https://raw.githubusercontent.com/Capybara-z/RemnaSetup/$REMNA_COMMIT/data/site/$file" "$TMP_DIR/$(basename "$file")"
        backup "/var/www/site/$file"
        install -m 0644 "$TMP_DIR/$(basename "$file")" "/var/www/site/$file"
    done
    # Tokens are not command-line arguments and are not expanded into Caddyfile.
    printf "GCORE_API_TOKEN='%s'\n" "$GCORE_TOKEN" > "$TMP_DIR/gcore.env"
    write_caddyfile > "$TMP_DIR/Caddyfile"
    run "$TMP_DIR/caddy-build/caddy" fmt --overwrite "$TMP_DIR/Caddyfile"
    run "$TMP_DIR/caddy-build/caddy" validate --adapter caddyfile \
        --envfile "$TMP_DIR/gcore.env" --config "$TMP_DIR/Caddyfile"
    for file in /usr/bin/caddy /usr/local/bin/caddy /etc/caddy/Caddyfile /etc/caddy/gcore.env \
        /etc/systemd/system/caddy.service; do
        backup "$file"
    done
    install -m 0755 "$TMP_DIR/caddy-build/caddy" /usr/bin/caddy.new
    mv -f /usr/bin/caddy.new /usr/bin/caddy
    install -o root -g caddy -m 0640 "$TMP_DIR/Caddyfile" /etc/caddy/Caddyfile
    install -o root -g root -m 0600 "$TMP_DIR/gcore.env" /etc/caddy/gcore.env
    cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy with Gcore DNS for the VPN node
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/gcore.env
Environment=XDG_DATA_HOME=/var/lib/caddy/.local/share
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/caddy.service
    run systemctl daemon-reload
    run systemctl enable caddy
    run systemctl restart caddy
    unset GCORE_TOKEN
}

# install_psiphon requires root, Bash >= 4, docker, systemd, curl, ip, ss,
# awk, flock, coreutils and parent helpers fail(message), note(message), backup(path).
# It publishes PSIPHON_BIND for the parent summary. No interactive input.
install_psiphon() {
    local root=/opt/ghost-psiphon owner=/opt/ghost-psiphon/.unified-vpn-installer
    local image=swarupsengupta2007/psiphon:latest bind path unit fragment label device_region probe
    local -a paths=(/etc/default/ghost-psiphon /usr/local/sbin/ghost-psiphon-run
        /usr/local/sbin/ghost-psiphon-watchdog /usr/local/bin/ghost-psiphon
        /var/lib/ghost-psiphon-watchdog.state
        /etc/systemd/system/ghost-psiphon.service
        /etc/systemd/system/ghost-psiphon-watchdog.service
        /etc/systemd/system/ghost-psiphon-watchdog.timer)

    if [[ ! -f "$owner" ]]; then
        for path in "$root" "${paths[@]}"; do
            [[ ! -e "$path" && ! -L "$path" ]] || fail "Уже существует сторонняя установка Psiphon: $path"
        done
        for unit in ghost-psiphon.service ghost-psiphon-watchdog.service ghost-psiphon-watchdog.timer; do
            fragment=$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)
            [[ -z "$fragment" ]] || fail "Уже существует сторонний unit: $fragment"
        done
    fi
    if docker container inspect ghost-psiphon >/dev/null 2>&1; then
        label=$(docker inspect -f '{{index .Config.Labels "io.unified-vpn-installer.component"}}' ghost-psiphon)
        [[ -f "$owner" && "$label" == psiphon ]] || fail 'Имя контейнера ghost-psiphon уже занято.'
    fi
    if [[ -f "$owner" ]]; then
        for path in /etc/default/ghost-psiphon /usr/local/sbin/ghost-psiphon-run \
            /usr/local/sbin/ghost-psiphon-watchdog /etc/systemd/system/ghost-psiphon.service \
            /etc/systemd/system/ghost-psiphon-watchdog.service /etc/systemd/system/ghost-psiphon-watchdog.timer; do
            if [[ -f "$path" ]]; then backup "$path"; fi
        done
    fi

    bind=$(ip -4 -o addr show dev docker0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)
    # Accept only an actual RFC1918 IPv4 address on docker0; otherwise use loopback.
    if ! awk -F. 'NF==4 && $1<=255 && $2<=255 && $3<=255 && $4<=255 &&
        ($1==10 || ($1==172 && $2>=16 && $2<=31) || ($1==192 && $2==168)) {ok=1} END {exit !ok}' <<< "$bind"; then
        bind=127.0.0.1
    fi
    # Keep the selected bind address on a rerun so the panel outbound stays valid.
    if [[ -f "$owner" && -r /etc/default/ghost-psiphon ]]; then
        local saved_bind
        saved_bind=$(sed -n 's/^BIND=//p' /etc/default/ghost-psiphon)
        [[ "$saved_bind" == "$bind" || "$saved_bind" == 127.0.0.1 ]] ||
            fail "Адрес docker0 изменился ($saved_bind -> $bind); проверьте outbound перед переустановкой."
        bind=$saved_bind
    fi
    PSIPHON_BIND=$bind
    note "Psiphon: загрузка образа, SOCKS $bind:1080, HTTP $bind:8080."
    docker pull "$image"
    if [[ -f "$owner" ]]; then
        for unit in ghost-psiphon-watchdog.timer ghost-psiphon-watchdog.service ghost-psiphon.service; do
            if systemctl cat "$unit" >/dev/null 2>&1; then systemctl stop "$unit"; fi
        done
    fi
    # Ports remain exactly the requested defaults; a collision must not silently change them.
    if ss -H -ltn | awk '{n=split($4,a,":"); if (a[n]==1080 || a[n]==8080) found=1} END {exit !found}'; then
        fail 'Порты 1080 или 8080 уже заняты. Psiphon оставлен без изменения портов.'
    fi
    install -d -m 0755 "$root"
    printf '%s\n' 'Managed by unified-vpn-installer' > "$owner"
    chmod 0600 "$owner"
    install -d -m 0750 -o 1000 -g 1000 "$root/config"
    if [[ ! -f /etc/default/ghost-psiphon ]]; then
        device_region=
        for probe in https://ipinfo.io/country https://api.country.is https://ifconfig.co/country-iso; do
            device_region=$(curl -4 -fsS --max-time 8 "$probe" 2>/dev/null |
                grep -oE '\b[A-Z]{2}\b' | head -n 1 || true)
            if [[ -n "$device_region" ]]; then break; fi
        done
        device_region=${device_region:-US}
        cat > /etc/default/ghost-psiphon <<PSIPHON_ENV
# Managed by unified-vpn-installer
IMAGE=$image
BIND=$bind
DEVICE_REGION=$device_region
PSIPHON_ENV
        cat >> /etc/default/ghost-psiphon <<'PSIPHON_DEFAULTS'
SOCKS_PORT=1080
HTTP_PORT=8080
FAIL_THRESHOLD=2
FAIL_WINDOW=5
ROTATE_COOLDOWN=1800
MIN_THROUGHPUT_KBPS=800
THROUGHPUT_GRACE_SEC=900
DENY_REGIONS='RU BY IR SY CU KP CN VE'
PSIPHON_DEFAULTS
    fi
    chmod 0600 /etc/default/ghost-psiphon

    cat > /usr/local/sbin/ghost-psiphon-run <<'PSIPHON_RUN'
#!/usr/bin/env bash
# Managed by unified-vpn-installer
set -Eeuo pipefail
# shellcheck source=/dev/null
source /etc/default/ghost-psiphon
if docker container inspect ghost-psiphon >/dev/null 2>&1; then
    [[ $(docker inspect -f '{{index .Config.Labels "io.unified-vpn-installer.component"}}' ghost-psiphon) == psiphon ]] || exit 1
    if [[ ${1:-start} == stop ]]; then exec docker stop -t 10 ghost-psiphon; fi
    docker rm -f ghost-psiphon >/dev/null
fi
[[ ${1:-start} != stop ]] || exit 0
exec docker run --rm --name ghost-psiphon \
    --label io.unified-vpn-installer.component=psiphon \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    -p "${BIND}:${SOCKS_PORT}:${SOCKS_PORT}" -p "${BIND}:${HTTP_PORT}:${HTTP_PORT}" \
    -e PUID=1000 -e PGID=1000 -e SOCKS_PORT="$SOCKS_PORT" -e HTTP_PORT="$HTTP_PORT" \
    -e DEVICE_REGION="${DEVICE_REGION:-US}" -e EGRESS_REGION= \
    -v /opt/ghost-psiphon/config:/config "$IMAGE"
PSIPHON_RUN

    cat > /usr/local/sbin/ghost-psiphon-watchdog <<'PSIPHON_WATCHDOG'
#!/usr/bin/env bash
# Managed by unified-vpn-installer
set -Eeuo pipefail
umask 077
export LC_ALL=C
# shellcheck source=/dev/null
source /etc/default/ghost-psiphon
exec 9>/run/ghost-psiphon-watchdog.lock
flock -n 9 || exit 0
state=/var/lib/ghost-psiphon-watchdog.state
window=''
last_rotate=0
if [[ -r "$state" ]]; then
    # Read state as data, never source a log/state file.
    read -r last_rotate window < "$state" || true
    [[ $last_rotate =~ ^[0-9]+$ ]] || last_rotate=0
    [[ $window =~ ^[01]*$ ]] || window=''
fi
probe_file=$(mktemp /run/ghost-psiphon-probe.XXXXXX)
trap 'rm -f "$probe_file"' EXIT
socks=(--socks5-hostname "$BIND:$SOCKS_PORT" --noproxy '')
alive=0
for attempt in 1 2; do
    code=$(curl -sS -o /dev/null --max-time 20 "${socks[@]}" -w '%{http_code}' \
        https://www.gstatic.com/generate_204 2>/dev/null) || true
    if [[ "$code" == 204 ]]; then alive=1; break; fi
    if [[ "$attempt" == 1 ]]; then sleep 15; fi
done
reason=''
gl=''
kbps=''
if [[ "$alive" == 0 ]]; then
    reason='SOCKS tunnel health check failed'
else
    probe=$(curl -sS --max-time 25 "${socks[@]}" -H 'Accept-Language: en-US' \
        -o "$probe_file" -w '%{speed_download} %{http_code}' https://www.youtube.com/ 2>/dev/null) || true
    speed=${probe%% *}; code=${probe##* }
    [[ $speed =~ ^[0-9]+([.][0-9]+)?$ ]] || speed=0
    kbps=$(( ${speed%%.*} / 1024 ))
    gl=$(sed -n 's/.*"GL":"\([A-Z][A-Z]\)".*/\1/p' "$probe_file" | head -n 1 || true)
    got=$(stat -c %s "$probe_file")
    if [[ -n "$gl" && " $DENY_REGIONS " == *" $gl "* ]]; then
        reason="Exit country rejected: $gl"
    elif [[ "$code" == 000 || -z "$code" ]]; then
        reason='SOCKS is reachable, but content request got no HTTP response'
    fi
    started=$(docker inspect -f '{{.State.StartedAt}}' ghost-psiphon 2>/dev/null || true)
    start_epoch=$(date -d "$started" +%s 2>/dev/null || printf '0')
    age=$(( $(date +%s) - start_epoch ))
    if [[ -z "$reason" && "$MIN_THROUGHPUT_KBPS" -gt 0 && "$got" -ge 50000 &&
          "$kbps" -lt "$MIN_THROUGHPUT_KBPS" && "$age" -ge "$THROUGHPUT_GRACE_SEC" ]]; then
        reason="Slow tunnel: $kbps KiB/s < $MIN_THROUGHPUT_KBPS KiB/s"
    fi
    printf 'Country=%s throughput=%s KiB/s age=%ss\n' "${gl:-unknown}" "$kbps" "$age"
fi
if [[ -n "$reason" ]]; then window+="1"; printf '%s\n' "$reason"; else window+="0"; fi
if [[ ${#window} -gt "$FAIL_WINDOW" ]]; then window=${window: -FAIL_WINDOW}; fi
ones=${window//0/}
now=$(date +%s)
if [[ ${#ones} -ge "$FAIL_THRESHOLD" && $((now - last_rotate)) -ge "$ROTATE_COOLDOWN" ]]; then
    printf 'Rotating Psiphon after %s failures in %s checks.\n' "${#ones}" "${#window}"
    systemctl restart ghost-psiphon.service
    last_rotate=$now
    window=''
fi
printf '%s %s\n' "$last_rotate" "$window" > "$state.tmp"
mv -f "$state.tmp" "$state"
PSIPHON_WATCHDOG

    cat > /etc/systemd/system/ghost-psiphon.service <<'PSIPHON_SERVICE'
# Managed by unified-vpn-installer
[Unit]
Description=Psiphon local proxy
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/ghost-psiphon-run
ExecStop=/usr/local/sbin/ghost-psiphon-run stop
Restart=always
RestartSec=10
TimeoutStartSec=0
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
PSIPHON_SERVICE
    cat > /etc/systemd/system/ghost-psiphon-watchdog.service <<'PSIPHON_WD_SERVICE'
# Managed by unified-vpn-installer
[Unit]
Description=Check Psiphon tunnel
After=ghost-psiphon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ghost-psiphon-watchdog
TimeoutStartSec=150
Nice=10
PSIPHON_WD_SERVICE
    cat > /etc/systemd/system/ghost-psiphon-watchdog.timer <<'PSIPHON_TIMER'
# Managed by unified-vpn-installer
[Unit]
Description=Check Psiphon every ten minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=30s
Unit=ghost-psiphon-watchdog.service

[Install]
WantedBy=timers.target
PSIPHON_TIMER
    chmod 0755 /usr/local/sbin/ghost-psiphon-run /usr/local/sbin/ghost-psiphon-watchdog
    chmod 0644 /etc/systemd/system/ghost-psiphon{,-watchdog}.service /etc/systemd/system/ghost-psiphon-watchdog.timer
    bash -n /usr/local/sbin/ghost-psiphon-run
    bash -n /usr/local/sbin/ghost-psiphon-watchdog
    systemctl daemon-reload
    systemctl enable ghost-psiphon.service ghost-psiphon-watchdog.timer
    systemctl restart ghost-psiphon.service ghost-psiphon-watchdog.timer
    systemctl is-active --quiet ghost-psiphon.service
    note "Psiphon установлен; проверка трафика выполняется после установки остальных компонентов."
}

# Free WARP via native WireGuard. Requires root, installed dependencies,
# and parent helpers note(), fail(), backup(path).
# Public wgcf v2.3.0 release hashes checked on 2026-10-01.
install_warp() (
    set -Eeuo pipefail
    umask 077
    local state=/opt/vpn-setup/warp conf=/etc/wireguard/warp.conf
    local marker='# Managed by vpn-install.sh (warp).'
    local arch hash asset tmp old_endpoint='' attempt account_ok=0
    local priv pub addr mtu path probe="vwp${BASHPID}" probe_created=0
    [[ $EUID == 0 ]] || fail 'Для установки WARP нужен root.'
    if [[ -e "$state" || -L "$state" ]]; then
        [[ -d "$state" && ! -L "$state" && "$(stat -c %u "$state")" == 0 ]] || \
            fail "Каталог WARP $state имеет неподходящий тип или владельца."
        if [[ ! -f "$state/.managed-by-vpn-install" || -L "$state/.managed-by-vpn-install" ]] || \
            ! grep -Fxq "$marker" "$state/.managed-by-vpn-install"; then
            fail "Каталог $state уже существует и не принадлежит этому установщику."
        fi
    fi
    # Inspect all reserved paths before creating the ownership marker or changing files.
    for path in "$conf" /usr/local/sbin/vpn-warp-check \
        /etc/systemd/system/vpn-warp-watchdog.service /etc/systemd/system/vpn-warp-watchdog.timer; do
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ ! -f "$path" || -L "$path" || "$(stat -c %u "$path")" != 0 ]] || \
                ! grep -Fxq "$marker" "$path"; then
                fail "Файл $path уже существует и не принадлежит этому установщику."
            fi
        fi
    done
    if [[ ! -e "$conf" ]] && ip link show warp >/dev/null 2>&1; then
        fail 'Интерфейс warp уже существует и не принадлежит этому установщику.'
    fi
    case "$(dpkg --print-architecture)" in
        amd64) arch=amd64; hash=01614e38c0eb5f3405232e71cfaf02d64d4809e4988ad8f5a8071af16d193405 ;;
        arm64) arch=arm64; hash=dcadadc42bcc410a4032a6d1c0490ea510e199f0aaaee397dc1aa0fbd27038e8 ;;
        *) fail 'Для WARP поддерживаются только amd64 и arm64.' ;;
    esac
    note 'Устанавливаю бесплатный WARP: интерфейс warp, без замены DNS и маршрута сервера.'
    # Create the marker first: interrupted attempts remain eligible for a safe rerun.
    install -d -m 0700 "$state"
    printf '%s\n' "$marker" > "$state/.managed-by-vpn-install"
    chmod 0600 "$state/.managed-by-vpn-install"
    tmp="$(mktemp -d "$state/.install.XXXXXX")"
    trap 'if [[ "$probe_created" == 1 ]]; then ip link delete dev "$probe" >/dev/null 2>&1 || true; fi; rm -rf -- "$tmp"' EXIT
    modprobe wireguard >/dev/null 2>&1 || true
    if ! ip link add dev "$probe" type wireguard; then
        fail 'Ядро/виртуализация не позволяет создать WireGuard-интерфейс.'
    fi
    probe_created=1
    ip link delete dev "$probe"
    probe_created=0
    install -d -m 0700 /etc/wireguard
    asset="wgcf_2.3.0_linux_${arch}"
    if [[ ! -x "$state/wgcf" ]] || \
       ! printf '%s  %s\n' "$hash" "$state/wgcf" | sha256sum --check --status; then
        curl -fSL --retry 3 --connect-timeout 15 --max-time 180 \
            "https://github.com/ViRb3/wgcf/releases/download/v2.3.0/$asset" -o "$tmp/wgcf"
        printf '%s  %s\n' "$hash" "$tmp/wgcf" | sha256sum --check --status || \
            fail 'SHA256 бинарного файла wgcf не совпал с официальным релизом.'
        install -m 0755 "$tmp/wgcf" "$state/wgcf"
    fi
    timeout 15 "$state/wgcf" --help > /dev/null 2>&1 </dev/null || \
        fail "wgcf не запускается. Проверьте архитектуру и отсутствие noexec на $state."

    # wgcf keeps the account in its working directory; never re-register an existing account.
    cd "$state"
    if [[ -e wgcf-account.toml ]]; then
        [[ -s wgcf-account.toml ]] || fail "Файл $state/wgcf-account.toml пуст; автоматическая замена аккаунта запрещена."
        note 'Использую сохранённый аккаунт WARP.'
    else
        for attempt in 1 2 3; do
            note "Регистрация бесплатного WARP: попытка $attempt/3."
            # Accepting Cloudflare ToS is part of unattended free-account registration.
            # Show registration output and retain it in a root-only file.
            if timeout 90 "$state/wgcf" register --accept-tos </dev/null 2>&1 | \
                tee "$state/registration.log"; then
                account_ok=1
            fi
            # Registration can save a valid account before a later metadata request fails.
            if [[ -s wgcf-account.toml ]]; then account_ok=1; break; fi
            [[ $attempt == 3 ]] || sleep "$((attempt * 7))"
        done
        [[ $account_ok == 1 && -s wgcf-account.toml ]] || \
            fail "Cloudflare не зарегистрировал WARP. Закрытый журнал: $state/registration.log. Повторный запуск безопасен."
    fi
    chmod 0600 wgcf-account.toml
    if ! timeout 90 "$state/wgcf" generate --profile "$tmp/wgcf-profile.conf" \
        </dev/null 2>&1 | tee "$state/generation.log"; then
        fail "Не удалось получить профиль WARP. Аккаунт сохранён. Журнал: $state/generation.log."
    fi
    [[ -s "$tmp/wgcf-profile.conf" ]] || fail 'wgcf не создал профиль WireGuard.'
    priv="$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {sub(/^[^=]*=/,""); gsub(/[[:space:]]/,""); print; exit}' "$tmp/wgcf-profile.conf")"
    pub="$(awk '/^[[:space:]]*PublicKey[[:space:]]*=/ {sub(/^[^=]*=/,""); gsub(/[[:space:]]/,""); print; exit}' "$tmp/wgcf-profile.conf")"
    # Split Address fields without losing a possible second comma-separated address.
    addr="$(awk '/^[[:space:]]*Address[[:space:]]*=/ {sub(/^[^=]*=/,""); n=split($0,a,","); for(i=1;i<=n;i++){gsub(/[[:space:]]/,"",a[i]); if(a[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/){print a[i]; exit}}}' "$tmp/wgcf-profile.conf")"
    mtu="$(awk -F ' *= *' '$1 ~ /^[[:space:]]*MTU$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$tmp/wgcf-profile.conf")"
    [[ "$priv" =~ ^[A-Za-z0-9+/]{43}=$ && "$pub" =~ ^[A-Za-z0-9+/]{43}=$ && -n "$addr" ]] || \
        fail 'В профиле WARP отсутствуют корректные ключи или IPv4-адрес.'
    [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1280
    (( mtu >= 1280 && mtu <= 1500 )) || fail 'Некорректный MTU в профиле WARP.'
    if [[ -f "$conf" ]]; then
        old_endpoint="$(awk -F ' *= *' '$1 ~ /^[[:space:]]*Endpoint$/ {print $2; exit}' "$conf")"
        cp -p "$conf" "$tmp/previous-warp.conf"
        backup "$conf"
    fi
    [[ "$old_endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] || old_endpoint=162.159.192.1:2408
    cat > "$tmp/warp.conf" <<CONF
$marker
[Interface]
PrivateKey = $priv
Address = $addr
MTU = $mtu
Table = off

[Peer]
PublicKey = $pub
AllowedIPs = 0.0.0.0/0
Endpoint = $old_endpoint
PersistentKeepalive = 25
CONF
    # Validation only strips wg-quick directives; no interface is started here.
    wg-quick strip "$tmp/warp.conf" > /dev/null
    systemctl stop vpn-warp-watchdog.timer vpn-warp-watchdog.service >/dev/null 2>&1 || true
    install -m 0600 "$tmp/warp.conf" "$conf"
    install -m 0600 "$tmp/wgcf-profile.conf" "$state/wgcf-profile.conf"
    write_warp_watchdog "$tmp"
    systemctl daemon-reload
    systemctl enable wg-quick@warp.service vpn-warp-watchdog.timer
    if ! systemctl restart wg-quick@warp.service; then
        # Restore the preceding managed profile when an update cannot start.
        if [[ -f "$tmp/previous-warp.conf" ]]; then
            install -m 0600 "$tmp/previous-warp.conf" "$conf"
            systemctl restart wg-quick@warp.service || true
        fi
        fail 'wg-quick@warp не запустился; проверьте journalctl -u wg-quick@warp.'
    fi
    systemctl start vpn-warp-watchdog.timer
    if /usr/local/sbin/vpn-warp-check repair; then
        note 'WARP: подтверждён выход через Cloudflare.'
    else
        note 'WARP установлен, но рабочий выход пока не подтверждён. Сторож повторит проверку через 5 минут.'
    fi
    cat > "$state/warp-outbound.json" <<'OUTBOUND'
{
  "tag": "warp-out",
  "protocol": "freedom",
  "settings": { "domainStrategy": "UseIPv4" },
  "streamSettings": { "sockopt": { "interface": "warp" } }
}
OUTBOUND
)

write_warp_watchdog() {
    local tmp="$1" path
    for path in /usr/local/sbin/vpn-warp-check /etc/systemd/system/vpn-warp-watchdog.service \
        /etc/systemd/system/vpn-warp-watchdog.timer; do
        if [[ -f "$path" ]]; then backup "$path"; fi
    done
    cat > "$tmp/vpn-warp-check" <<'WARP_CHECK'
#!/usr/bin/env bash
# Managed by vpn-install.sh (warp).
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
conf=/etc/wireguard/warp.conf

healthy() {
    local trace timestamp now
    systemctl is-active --quiet wg-quick@warp.service || return 1
    ip link show dev warp >/dev/null 2>&1 || return 1
    # SO_BINDTODEVICE prevents a successful request over the server's default interface.
    trace="$(curl -4 -fsS --noproxy '*' --interface if!warp --connect-timeout 4 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
    trace="${trace//$'\r'/}"
    grep -qE '^warp=(on|plus)$' <<< "$trace" || return 1
    timestamp="$(wg show warp latest-handshakes | awk 'NR==1 {print $2}')" || return 1
    [[ "$timestamp" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    (( timestamp > 0 && now >= timestamp && now - timestamp <= 180 )) || return 1
    printf '%s\n' "$trace" | awk -F= '$1=="warp" || $1=="ip" || $1=="loc" {print}'
}

case "${1:-check}" in
    check) healthy; exit $? ;;
    repair) ;;
    *) printf 'Usage: vpn-warp-check [check|repair]\n' >&2; exit 2 ;;
esac
exec 9>/run/lock/vpn-warp-check.lock
flock -w 150 9 || exit 1
if healthy; then exit 0; fi
systemctl restart wg-quick@warp.service || exit 1
if healthy; then exit 0; fi
peer="$(wg show warp peers | awk 'NR==1 {print; exit}')"
back="$(wg show warp endpoints | awk 'NR==1 {print $2; exit}')"
[[ -n "$peer" && -n "$back" && "$back" != '(none)' ]] || exit 1
resolved="$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1 {print $1}')" || resolved=''
# The candidates retain the original installer's fallback addresses. Only a
# successful HTTPS trace through warp is accepted; an old handshake is insufficient.
candidates=("$back")
[[ -z "$resolved" ]] || candidates+=("$resolved:2408")
candidates+=(162.159.192.1:2408 162.159.193.1:2408 188.114.96.1:2408 \
    188.114.98.1:2408 162.159.192.1:500 188.114.96.1:1701 \
    162.159.195.1:4500 188.114.99.1:8886)
seen=' '
for candidate in "${candidates[@]}"; do
    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] || continue
    [[ "$seen" != *" $candidate "* ]] || continue
    seen+="$candidate "
    wg set warp peer "$peer" endpoint "$candidate" || continue
    if healthy; then
        replacement="$(mktemp /etc/wireguard/.warp-endpoint.XXXXXX)"
        if sed "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $candidate|" "$conf" > "$replacement" && \
            grep -Fxq "Endpoint = $candidate" "$replacement"; then
            chmod 0600 "$replacement"
            mv -f "$replacement" "$conf"
            printf 'WARP endpoint: %s\n' "$candidate"
            exit 0
        fi
        rm -f "$replacement"
        printf 'Cannot persist WARP endpoint.\n' >&2
        break
    fi
done
wg set warp peer "$peer" endpoint "$back" || true
printf 'WARP is not verified: endpoint probes did not complete a tunnel HTTPS request.\n' >&2
exit 1
WARP_CHECK
    bash -n "$tmp/vpn-warp-check"
    install -m 0755 "$tmp/vpn-warp-check" /usr/local/sbin/vpn-warp-check
    cat > /etc/systemd/system/vpn-warp-watchdog.service <<'SERVICE'
# Managed by vpn-install.sh (warp).
[Unit]
Description=Check WARP and recover its WireGuard endpoint
Wants=network-online.target
After=network-online.target wg-quick@warp.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-warp-check repair
TimeoutStartSec=300
Nice=10
UMask=0077
SERVICE
    cat > /etc/systemd/system/vpn-warp-watchdog.timer <<'TIMER'
# Managed by vpn-install.sh (warp).
[Unit]
Description=Check WARP every five minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=15s
Unit=vpn-warp-watchdog.service

[Install]
WantedBy=timers.target
TIMER
    chmod 0644 /etc/systemd/system/vpn-warp-watchdog.service /etc/systemd/system/vpn-warp-watchdog.timer
}

verify_warp() {
    [[ -x /usr/local/sbin/vpn-warp-check ]] && \
        /usr/local/sbin/vpn-warp-check check
}


verify_node() {
    local attempt first second
    for attempt in {1..30}; do
        first="$(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}} {{.Config.Image}}' remnanode 2>/dev/null)" || first=''
        if [[ "$first" == true\ * && "$first" == *" $NODE_IMAGE" ]] && \
            timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3001' >/dev/null 2>&1; then
            sleep 5
            second="$(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}} {{.Config.Image}}' remnanode 2>/dev/null)" || second=''
            if [[ "$first" == "$second" ]]; then return 0; fi
        fi
        sleep 2
    done
    return 1
}

verify_psiphon() {
    local attempt code
    for attempt in {1..6}; do
        if ! systemctl is-active --quiet ghost-psiphon.service; then return 1; fi
        code="$(curl --silent --show-error --noproxy '' --socks5-hostname "$PSIPHON_BIND:1080" \
            --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' \
            https://www.gstatic.com/generate_204 2>/dev/null)" || code=''
        if [[ "$code" == 204 ]]; then return 0; fi
        sleep 5
    done
    return 1
}

verify_caddy() {
    local attempt
    for attempt in {1..30}; do
        systemctl is-active --quiet caddy || return 1
        if curl --fail --silent --show-error --noproxy '*' \
            --resolve "$SNI_DOMAIN:8443:127.0.0.1" --connect-timeout 2 --max-time 5 \
            "https://$SNI_DOMAIN:8443/" -o /dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

write_connection_info() {
    cat > "$STATE_DIR/outbounds.json" <<EOF
{
  "outbounds": [
    {
      "tag": "psiphon-out",
      "protocol": "socks",
      "settings": {"address": "$PSIPHON_BIND", "port": 1080}
    },
    {
      "tag": "warp-out",
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIPv4"},
      "streamSettings": {"sockopt": {"interface": "warp"}}
    }
  ]
}
EOF
    cat > "$STATE_DIR/connection-info.txt" <<EOF
Remnanode: $NODE_IMAGE
API port: 3001 (mTLS; нужен полный токен ноды из панели)
SNI: $SNI_DOMAIN
Reality target: 127.0.0.1:8443
Reality serverNames: ["$SNI_DOMAIN"]
Reality xver: 0
Psiphon SOCKS: $PSIPHON_BIND:1080
Psiphon HTTP: $PSIPHON_BIND:8080
Psiphon поддерживает TCP; UDP-трафик в psiphon-out не направлять.
WARP interface: warp; IPv4; Table=off
Outbound examples: $STATE_DIR/outbounds.json
Gcore credentials: /etc/caddy/gcore.env (root:root, 0600)
Node credentials: /opt/remnanode/docker-compose.yml (root:root, 0600)

Профиль Xray, подключение ноды к панели и правила маршрутизации настраиваются
в панели Remnawave. Файл outbounds.json содержит примеры добавляемых outbound,
а не замену всего Config Profile. Caddy занимает 8443 и стандартный HTTP 80;
443 остаётся для Xray. Firewall и правила провайдера скрипт не меняет.

Диагностика:
  systemctl status caddy ghost-psiphon wg-quick@warp --no-pager
  journalctl -u caddy -n 80 --no-pager
  journalctl -u ghost-psiphon -n 80 --no-pager
  journalctl -u wg-quick@warp -n 80 --no-pager
  /usr/local/sbin/vpn-warp-check check
  docker logs --tail 80 remnanode
EOF
    chmod 0600 "$STATE_DIR/connection-info.txt" "$STATE_DIR/outbounds.json"
}

final_checks() {
    local incomplete=0 service
    note 'Проверяю ноду, оба туннеля и сертификат Caddy. Выпуск сертификата может занять несколько минут.'
    if verify_node; then
        note 'OK · Remnanode 2.8.0 работает, TCP 3001 доступен, перезапусков при проверке нет.'
    else
        note 'ОШИБКА · Нода не прошла проверку готовности; см. docker logs remnanode.'
        incomplete=1
    fi
    if verify_psiphon; then
        note "OK · Запрос через Psiphon $PSIPHON_BIND:1080 выполнен."
    else
        note 'ОШИБКА · Psiphon установлен, но запрос через туннель не прошёл.'
        incomplete=1
    fi
    if verify_warp; then
        note 'OK · WARP подтвердил соединение с Cloudflare через интерфейс warp.'
    else
        note 'ОШИБКА · WARP установлен, но рабочее соединение не подтверждено.'
        incomplete=1
    fi
    if verify_caddy; then
        note "OK · Caddy отдаёт страницу с доверенным сертификатом для $SNI_DOMAIN."
    else
        note 'ОШИБКА · HTTPS Caddy не подтвердился. Проверьте токен/зону Gcore и journalctl -u caddy.'
        incomplete=1
    fi
    for service in docker caddy ghost-psiphon wg-quick@warp \
        ghost-psiphon-watchdog.timer vpn-warp-watchdog.timer; do
        if ! systemctl is-enabled --quiet "$service" || ! systemctl is-active --quiet "$service"; then
            note "ОШИБКА · Служба/таймер $service не активны либо автозапуск отключён."
            incomplete=1
        fi
    done
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr || \
          "$(sysctl -n net.core.default_qdisc)" != fq ]]; then
        note 'ОШИБКА · Итоговые значения BBR/fq отличаются от запрошенных.'
        incomplete=1
    else
        note 'OK · BBR + fq включены.'
    fi
    printf '\nПараметры для панели: %s/connection-info.txt\n' "$STATE_DIR"
    printf 'Примеры outbound:    %s/outbounds.json\n' "$STATE_DIR"
    printf 'Журнал установки:    %s\n' "$LOG"
    printf 'Резервные копии:      %s\n' "$BACKUP_DIR"
    if [[ "$incomplete" -ne 0 ]]; then
        printf '\nУстановка завершена с ошибками проверки; полноценная готовность не подтверждена.\n'
        return 2
    fi
    printf '\n%s✓ ГОТОВО%s · Все локальные проверки прошли.\n' "$GREEN" "$RESET"
    printf 'Для панели: API 3001; SNI %s; Reality target 127.0.0.1:8443; xver 0.\n' "$SNI_DOMAIN"
    printf 'Подключение панели и работа VPN-клиента этими проверками не проверялись.\n'
}

main() {
    exec 3>&2
    UI_FD=3
    trap 'on_error "$?" "$LINENO"' ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    preflight
    read_inputs
    init_workspace
    # Show command output live while keeping the root-only installation log.
    exec > >(tee -a "$LOG") 2>&1
    UI_FD=2
    stage 1 'Базовые пакеты'
    install_dependencies
    validate_node_token
    stage 2 'Docker и Compose'
    install_docker
    stage 3 'BBR'
    install_bbr
    stage 4 'Remnanode 2.8.0'
    install_node
    stage 5 'Caddy с Gcore DNS'
    install_caddy
    stage 6 'Psiphon'
    install_psiphon
    stage 7 'Бесплатный WARP'
    install_warp
    write_connection_info
    stage 8 'Проверка установки'
    # Only checks (not installation functions) are evaluated in a conditional.
    local result=0
    final_checks || result=$?
    exit "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
