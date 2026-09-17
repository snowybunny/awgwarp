#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  AWGWARP Manager v0.1
#  Cloudflare WARP внутри Docker-контейнера AmneziaWG
# ══════════════════════════════════════════════════════════════

WARP_VERSION="0.1"
WARP_DIR="/etc/awgwarp-manager"
WARP_CONF="$WARP_DIR/config"
WARP_LOG="/var/log/awgwarp-manager.log"

WGCF_VERSION="2.2.32"
WGCF_BIN="/root/wgcf"
WGCF_ACCOUNT="/root/wgcf-account.toml"
WGCF_PROFILE="/root/wgcf-profile.conf"

AWG_WARP_DIR="/opt/warp"
AWG_WARP_CONF="$AWG_WARP_DIR/warp.conf"
AWG_WARP_CLIENTS="$AWG_WARP_DIR/clients.list"
AWG_MARKER_BEGIN="# --- AWGWARP-MANAGER BEGIN ---"
AWG_MARKER_END="# --- AWGWARP-MANAGER END ---"


RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'

MY_IP=""

CONTAINER=""
AWG_VPN_CONF=""
AWG_VPN_IF=""
AWG_VPN_QUICK_CMD=""
AWG_CLIENTS_TABLE=""
AWG_START_SH=""
AWG_SUBNET=""
AWG_WARP_EXIT_IP=""
declare -a AWG_SELECTED_IPS=()
declare -a AWG_CLIENT_IPS=()
declare -A AWG_CLIENT_NAMES=()

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════

init_config() {
    mkdir -p "$WARP_DIR"
    if [ ! -f "$WARP_CONF" ]; then
        cat > "$WARP_CONF" <<'CONF'
CONTAINER=""
WARP_LICENSE_KEY=""
WARP_PLAN="free"
WGCF_ORIGINAL_LICENSE=""
WARP_LICENSE_ASKED="0"
WARP_ENDPOINT_OVERRIDE=""
LOG_ENABLED="0"
CONF
    fi
    source "$WARP_CONF"
    LOG_ENABLED="${LOG_ENABLED:-0}"
}

save_config_val() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$WARP_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$WARP_CONF"
    else
        echo "${key}=\"${value}\"" >> "$WARP_CONF"
    fi
    source "$WARP_CONF"
}

# ═══════════════════════════════════════════════════════════════
#  LOGGING / SYSTEM
# ═══════════════════════════════════════════════════════════════

log_action() { [ "${LOG_ENABLED:-0}" = "1" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WARP_LOG"; return 0; }

log_toggle_menu() {
  while true; do
    clear
    echo -e "\n${CYAN}━━━ Логирование (${WARP_LOG}) ━━━${NC}\n"
    if [ "${LOG_ENABLED:-0}" = "1" ]; then
      echo -e "  Статус: ${GREEN}Включено${NC}"
    else
      echo -e "  Статус: ${YELLOW}Выключено${NC} ${DIM}(по умолчанию)${NC}"
    fi
    echo -e "\n  1) Включить"
    echo -e "  2) Выключить"
    echo -e "  3) Показать последние записи лога"
    echo -e "  4) Очистить лог-файл"
    echo -e "  0) Назад"
    read -p "  Выбор: " c
    case "$c" in
      1) save_config_val "LOG_ENABLED" "1"; log_action "LOG: логирование включено"
         echo -e "${GREEN}✓ Включено${NC}"; read -p "Enter..." ;;
      2) log_action "LOG: логирование выключено"; save_config_val "LOG_ENABLED" "0"
         echo -e "${YELLOW}✓ Выключено${NC}"; read -p "Enter..." ;;
      3) clear; echo -e "\n${CYAN}━━━ Последние записи ━━━${NC}\n"
         [ -f "$WARP_LOG" ] && tail -n 50 "$WARP_LOG" || echo -e "${DIM}(лог пуст или не создан)${NC}"
         echo ""; read -p "Enter..." ;;
      4) rm -f "$WARP_LOG"; echo -e "${GREEN}✓ Лог очищен${NC}"; read -p "Enter..." ;;
      0) return ;;
    esac
  done
}

check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}[ERROR] Запустите от root!${NC}"; exit 1; }
}

check_deps() {
    for cmd in jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y > /dev/null 2>&1
            apt-get install -y jq curl > /dev/null 2>&1
            break
        fi
    done
}

get_my_ip() {
    MY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA BACKEND — WARP via wgcf (WireGuard inside Docker)
# ═══════════════════════════════════════════════════════════════

awg_pick_container() {
    if [ -n "${CONTAINER:-}" ]; then
        docker exec "$CONTAINER" sh -c "true" 2>/dev/null && return 0
        CONTAINER=""
    fi

    local -a containers=()
    mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia" || true)
    fi

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${RED}Контейнеры amnezia-awg / amnezia-awg2 не найдены.${NC}"
        echo -e "${WHITE}Убедитесь, что AmneziaWG запущен через Docker.${NC}"
        return 1
    elif [ ${#containers[@]} -eq 1 ]; then
        CONTAINER="${containers[0]}"
    else
        echo -e "\n${CYAN}Доступные контейнеры:${NC}"
        local i=1
        for c in "${containers[@]}"; do echo -e "  ${GREEN}$i)${NC} $c"; ((i++)); done
        echo -e "  ${DIM}0) Отмена${NC}"
        while true; do
            read -p "Выберите контейнер: " ch
            [ "$ch" = "0" ] && return 1
            [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#containers[@]} )) && { CONTAINER="${containers[$((ch-1))]}"; break; }
        done
    fi
    save_config_val "CONTAINER" "$CONTAINER"
    return 0
}

awg_load_container_data() {
    if [ "$CONTAINER" = "amnezia-awg2" ]; then
        AWG_VPN_CONF="/opt/amnezia/awg/awg0.conf"
        AWG_VPN_IF="awg0"
        AWG_VPN_QUICK_CMD="awg-quick"
    else
        AWG_VPN_CONF="/opt/amnezia/awg/wg0.conf"
        AWG_VPN_IF="wg0"
        AWG_VPN_QUICK_CMD="wg-quick"
    fi

    AWG_CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
    AWG_START_SH="/opt/amnezia/start.sh"

    docker exec "$CONTAINER" sh -c "[ -f '$AWG_VPN_CONF' ]" 2>/dev/null || {
        for f in /opt/amnezia/awg/wg0.conf /opt/amnezia/awg/awg0.conf /etc/wireguard/wg0.conf; do
            if docker exec "$CONTAINER" sh -c "[ -f '$f' ]" 2>/dev/null; then
                AWG_VPN_CONF="$f"
                break
            fi
        done
    }

    docker exec "$CONTAINER" sh -c "[ -f '$AWG_VPN_CONF' ]" 2>/dev/null || {
        echo -e "${RED}Не найден конфиг VPN в контейнере: $AWG_VPN_CONF${NC}"
        return 1
    }

    AWG_SUBNET=$(docker exec "$CONTAINER" sh -c "sed -n 's/^Address = \(.*\)$/\1/p' '$AWG_VPN_CONF' | head -n1 | cut -d',' -f1" 2>/dev/null | tr -d '\r')
    return 0
}

awg_detect_warp_exit_ip() {
    AWG_WARP_EXIT_IP=""
    if docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null; then
        AWG_WARP_EXIT_IP=$(docker exec "$CONTAINER" sh -c \
            "curl -s --interface warp --connect-timeout 3 https://ifconfig.me 2>/dev/null || true" | tr -d '\r\n')
    fi
}

is_warp_installed_awg() {
    docker exec "$CONTAINER" sh -c "[ -f '$AWG_WARP_CONF' ]" 2>/dev/null
}

is_warp_running_awg() {
    docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null
}

get_warp_status_awg() {
    if ! is_warp_installed_awg; then echo "Не установлен"; return; fi
    local base; is_warp_running_awg && base="Подключён" || base="Отключён"
    local plan_label="Free"
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        if [ "${WARP_PLAN:-free}" = "plus" ]; then
            plan_label="WARP+"
        else
            plan_label="WARP+?"
        fi
    fi
    echo "${base} (${plan_label})"
}

awg_backup() {
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    docker exec "$CONTAINER" sh -c "
        [ -f '$AWG_VPN_CONF' ] && cp '$AWG_VPN_CONF' '${AWG_VPN_CONF}.bak-${ts}'
        [ -f '$AWG_CLIENTS_TABLE' ] && cp '$AWG_CLIENTS_TABLE' '${AWG_CLIENTS_TABLE}.bak-${ts}'
        [ -f '$AWG_START_SH' ] && cp '$AWG_START_SH' '${AWG_START_SH}.bak-${ts}'
        [ -f '$AWG_START_SH' ] && [ ! -f /opt/amnezia/start.sh.final-backup ] && cp '$AWG_START_SH' /opt/amnezia/start.sh.final-backup
    " >/dev/null 2>&1
    log_action "AWG BACKUP: $ts"
}

# Скачивание файла с принудительным IPv4 (частая причина обрывов на VPS с
# нерабочим/недомаршрутизируемым IPv6) + ретраи + фолбэк curl <-> wget.
robust_download() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 10 --retry 2 --retry-delay 2 -o "$out" "$url" 2>/dev/null && return 0
    fi
    wget -4 -q --timeout=15 --tries=2 -O "$out" "$url" 2>/dev/null && return 0
    return 1
}

awg_install_wgcf() {
    if [ -x "$WGCF_BIN" ]; then return 0; fi
    local arch; arch=$(uname -m)
    local wa=""
    case "$arch" in
        x86_64) wa="amd64" ;; aarch64) wa="arm64" ;; armv7l) wa="armv7" ;;
        *) echo -e "${RED}Архитектура не поддерживается: $arch${NC}"; return 1 ;;
    esac
    local url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wa}"
    if ! robust_download "$url" "$WGCF_BIN"; then
        rm -f "$WGCF_BIN"
        echo -e "${RED}Не удалось скачать wgcf (v${WGCF_VERSION}).${NC}"
        echo -e "${YELLOW}URL: ${url}${NC}"
        echo -e "${YELLOW}Похоже на проблему с сетью сервера: нерабочий IPv6 (уже пробовали -4),${NC}"
        echo -e "${YELLOW}блокировка objects.githubusercontent.com файрволом/провайдером, либо DNS.${NC}"
        echo -e "${YELLOW}Проверьте вручную: curl -4 -v -o /dev/null \"${url}\"${NC}"
        return 1
    fi
    chmod +x "$WGCF_BIN"
}

awg_ensure_account() {
    local fresh=0
    if [ ! -f "$WGCF_ACCOUNT" ]; then
        echo -e "${YELLOW}Регистрация WARP через wgcf...${NC}"
        (cd /root && yes | ./wgcf register 2>/dev/null)
        fresh=1
    fi
    [ -f "$WGCF_ACCOUNT" ] || { echo -e "${RED}Не создан $WGCF_ACCOUNT${NC}"; return 1; }

    # Запоминаем "родной" (free) license_key аккаунта один раз — он нужен для
    # безопасного отката на Free, если активация WARP+ когда-либо не удастся.
    if [ "$fresh" -eq 1 ] || [ -z "${WGCF_ORIGINAL_LICENSE:-}" ]; then
        if [ "$fresh" -eq 1 ] || [ "${WARP_PLAN:-free}" != "plus" ]; then
            local lic; lic=$(awg_get_current_license)
            [ -n "$lic" ] && save_config_val "WGCF_ORIGINAL_LICENSE" "$lic"
        fi
    fi
    return 0
}

# ── WARP+ License helpers ────────────────────────────────────────

awg_get_current_license() {
    [ -f "$WGCF_ACCOUNT" ] || return 1
    sed -n "s/^license_key[[:space:]]*=[[:space:]]*['\"]\\(.*\\)['\"].*/\\1/p" "$WGCF_ACCOUNT" 2>/dev/null | head -1
}

awg_set_license_key() {
    local key="$1"
    [ -f "$WGCF_ACCOUNT" ] || return 1
    if grep -qE "^license_key" "$WGCF_ACCOUNT" 2>/dev/null; then
        sed -i "s|^license_key.*|license_key = '${key}'|" "$WGCF_ACCOUNT"
    else
        echo "license_key = '${key}'" >> "$WGCF_ACCOUNT"
    fi
}

awg_wgcf_update() {
    (cd /root && yes | ./wgcf update 2>&1)
}

awg_detect_warp_plan() {
    [ -z "${CONTAINER:-}" ] && { echo "unknown"; return; }
    local trace
    trace=$(docker exec "$CONTAINER" sh -c "curl -s --interface warp --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null")
    if echo "$trace" | grep -q "warp=plus"; then echo "plus"
    elif echo "$trace" | grep -q "warp=on"; then echo "free"
    else echo "unknown"; fi
}

# Несколько попыток проверить, что интерфейс warp реально доходит до
# Cloudflare (а не просто поднялся локально — wg-quick up "успевает" даже
# с нерабочим endpoint, реальный handshake при этом не происходит).
# Возвращает "plus"/"free" при успехе, "unknown" если так и не достучались.
awg_wait_warp_connectivity() {
    local tries="${1:-3}" i plan
    for ((i = 1; i <= tries; i++)); do
        plan=$(awg_detect_warp_plan)
        if [ "$plan" != "unknown" ]; then
            echo "$plan"
            return 0
        fi
        [ "$i" -lt "$tries" ] && sleep 2
    done
    echo "unknown"
    return 1
}

# Полный провижининг WARP (AmneziaWG): опционально пересоздаёт аккаунт,
# привязывает License Key, генерирует профиль, поднимает интерфейс,
# проверяет реальный план и применяет клиентские правила.
#
#   $1 — License Key ("" = оставаться на Free)
#   $2 — "1" = принудительно пересоздать аккаунт wgcf, даже если он уже есть
#
# ВАЖНО про WARP+: у Cloudflare есть известный баг — если аккаунт wgcf уже
# хоть раз подключался как Free, привязка лицензии к нему часто не поднимает
# статус до "plus". Поэтому при непустом License Key аккаунт ВСЕГДА
# пересоздаётся заново и лицензия привязывается ДО первого подключения.
#
# Откат на Free (awg_fallback_to_free) происходит ТОЛЬКО если Cloudflare API
# явно отклонил лицензию (ошибка в ответе `wgcf update`). Если API принял
# ключ (success), конфигурация с этим ключом сохраняется как есть — даже
# если проверка через trace ("cdn-cgi/trace") пока показывает не "plus":
# это может быть задержка применения на стороне Cloudflare или особенность
# конкретного типа аккаунта, а не признак того, что ключ не сработал.
awg_do_provision() {
    local lic_key="$1" force_fresh="${2:-0}"

    if [ "$force_fresh" = "1" ] || [ -n "$lic_key" ]; then
        docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true" 2>/dev/null
        rm -f "$WGCF_ACCOUNT"
        save_config_val "WGCF_ORIGINAL_LICENSE" ""
    fi

    awg_ensure_account || return 1

    if [ -n "$lic_key" ]; then
        echo -e "${YELLOW}  [*]${NC} Привязка License Key (до первого подключения)..."
        awg_set_license_key "$lic_key"
        local out; out=$(awg_wgcf_update)
        if echo "$out" | grep -qiE "error|invalid|fail|not[[:space:]]*found|unauthorized"; then
            echo -e "${RED}    ✗ Cloudflare отклонил лицензию (ошибка API), откат на Free.${NC}"
            awg_fallback_to_free
            return 1
        fi
        echo -e "${GREEN}    ✓ Ключ принят Cloudflare${NC}"
    fi

    awg_generate_profile || return 1
    local ep; ep=$(awg_resolve_endpoint) || return 1
    awg_build_warp_conf "$ep"
    awg_warp_up || return 1

    local plan="free"
    if [ -n "$lic_key" ]; then
        plan=$(awg_wait_warp_connectivity 3)
        if [ "$plan" != "plus" ]; then
            echo -e "${YELLOW}  ⚠ Лицензия принята Cloudflare, но trace пока показывает «${plan:-unknown}».${NC}"
            echo -e "${YELLOW}    Конфигурация с лицензией сохранена как есть — статус можно перепроверить позже (меню License → «Перепроверить статус»).${NC}"
        fi
    fi

    WARP_PLAN="$plan"; save_config_val "WARP_PLAN" "$plan"
    awg_apply_rules
    awg_patch_start_sh
    awg_detect_warp_exit_ip
    log_action "AWG PROVISION: plan=${WARP_PLAN}, license_key_set=$([ -n "$lic_key" ] && echo 1 || echo 0), ip=${AWG_WARP_EXIT_IP:-N/A}"
    return 0
}

# Откат на бесплатный WARP: восстанавливает "родной" license_key аккаунта
# и пересобирает профиль/конфиг/интерфейс. Вызывается при ЛЮБОЙ ошибке
# активации WARP+ (изнутри awg_do_provision), а также вручную из меню License.
awg_fallback_to_free() {
    echo -e "${YELLOW}  [*] Откат на бесплатный WARP (Free)...${NC}"
    if [ -f "$WGCF_ACCOUNT" ]; then
        local orig="${WGCF_ORIGINAL_LICENSE:-}"
        if [ -n "$orig" ]; then
            awg_set_license_key "$orig"
            awg_wgcf_update >/dev/null 2>&1
        fi
        awg_generate_profile >/dev/null 2>&1
        local ep; ep=$(awg_resolve_endpoint 2>/dev/null)
        if [ -n "$ep" ]; then
            awg_build_warp_conf "$ep"
            awg_warp_up >/dev/null 2>&1
        fi
    fi
    WARP_PLAN="free"; save_config_val "WARP_PLAN" "free"
    awg_detect_warp_exit_ip
    log_action "AWG LICENSE: fallback to Free, ip=${AWG_WARP_EXIT_IP:-N/A}"
    echo -e "${GREEN}    ✓ Free активен.${NC}"
}

awg_generate_profile() {
    (cd /root && yes | ./wgcf generate 2>/dev/null)
    [ -f "$WGCF_PROFILE" ] || { echo -e "${RED}Не создан профиль.${NC}"; return 1; }
}

awg_resolve_endpoint() {
    if [ -n "${WARP_ENDPOINT_OVERRIDE:-}" ]; then
        echo "$WARP_ENDPOINT_OVERRIDE"
        return 0
    fi
    local ep; ep=$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ep" ] && { echo -e "${RED}Не удалось определить IP endpoint.${NC}"; return 1; }
    echo "${ep}:2408"
}

awg_get_active_endpoint() {
    docker exec "$CONTAINER" sh -c "awk -F' = ' '/^Endpoint/{print \$2}' '$AWG_WARP_CONF'" 2>/dev/null
}

# Проверяет формат endpoint: IPv4:PORT (162.159.192.1:2408) либо
# [IPv6]:PORT (например [2602:fc59:b0:64::a29f:c08d]:2408 — в т.ч. для
# конструкций через NAT64-шлюзы). Порт должен быть в диапазоне 1-65535.
# Фактическая работоспособность самого адреса проверяется отдельно, уже
# после применения, через реальный handshake (awg_wait_warp_connectivity).
awg_is_valid_endpoint() {
    local val="$1" port
    if [[ "$val" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[2]}"
    elif [[ "$val" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    (( port >= 1 && port <= 65535 ))
}

# Меняет endpoint (IP:port) без пересоздания аккаунта/ключей — пересобирает
# warp.conf и ПОЛНОСТЬЮ ПЕРЕЗАПУСКАЕТ КОНТЕЙНЕР (awg_reload_warp_interface),
# т.к. простой wg-quick down/up внутри уже работающего контейнера иногда не
# сбрасывает состояние интерфейса AmneziaWG — только чистый рестарт делает
# это надёжно. После рестарта РЕАЛЬНО проверяется связь с Cloudflare (сам
# wg-quick "успевает" даже с нерабочим endpoint — просто без handshake).
# Если новый endpoint не отвечает — автоматически откатывается на
# предыдущий (рабочий) endpoint, чтобы WARP не оставался нерабочим.
# ВАЖНО: рестарт контейнера на несколько секунд обрывает ВСЕ VPN-соединения
# через него, не только WARP.
#   $1 — "ip:port" / "[ipv6]:port" или "" для сброса на автоматический (DNS engage.cloudflareclient.com)
awg_set_endpoint() {
    local val="$1"
    local prev_val="${WARP_ENDPOINT_OVERRIDE:-}"

    is_warp_installed_awg || { save_config_val "WARP_ENDPOINT_OVERRIDE" "$val"; return 0; }

    save_config_val "WARP_ENDPOINT_OVERRIDE" "$val"
    local ep; ep=$(awg_resolve_endpoint) || { save_config_val "WARP_ENDPOINT_OVERRIDE" "$prev_val"; return 1; }
    awg_build_warp_conf "$ep"
    awg_reload_warp_interface || { save_config_val "WARP_ENDPOINT_OVERRIDE" "$prev_val"; return 1; }

    echo -e "${YELLOW}  [*]${NC} Проверка реальной связи через новый endpoint..."
    local plan; plan=$(awg_wait_warp_connectivity 3)
    if [ "$plan" = "unknown" ]; then
        echo -e "${RED}    ✗ Endpoint не отвечает. Откатываюсь на предыдущий (${prev_val:-автоматический}).${NC}"
        save_config_val "WARP_ENDPOINT_OVERRIDE" "$prev_val"
        local ep2; ep2=$(awg_resolve_endpoint 2>/dev/null)
        if [ -n "$ep2" ]; then
            awg_build_warp_conf "$ep2"
            awg_reload_warp_interface >/dev/null 2>&1
        fi
        awg_apply_rules
        awg_patch_start_sh
        awg_detect_warp_exit_ip
        log_action "AWG ENDPOINT: ${val:-auto} FAILED (no handshake), rolled back to ${prev_val:-auto}"
        return 1
    fi
    echo -e "${GREEN}    ✓ Endpoint рабочий (статус: $([ "$plan" = "plus" ] && echo WARP+ || echo Free))${NC}"

    WARP_PLAN="$plan"; save_config_val "WARP_PLAN" "$plan"
    awg_apply_rules
    awg_patch_start_sh
    awg_detect_warp_exit_ip
    log_action "AWG ENDPOINT: set to ${val:-auto} (resolved: ${ep}), connectivity=ok"
    return 0
}

awg_build_warp_conf() {
    local endpoint="$1"
    local pk pub addr
    pk=$(awk -F' = ' '/^PrivateKey = /{print $2}' "$WGCF_PROFILE")
    pub=$(awk -F' = ' '/^PublicKey = /{print $2}' "$WGCF_PROFILE")
    addr=$(awk -F' = ' '/^Address = /{print $2}' "$WGCF_PROFILE" | cut -d',' -f1)

    docker exec "$CONTAINER" sh -c "mkdir -p '$AWG_WARP_DIR'"
    docker cp "$WGCF_PROFILE" "${CONTAINER}:${AWG_WARP_DIR}/wgcf-profile.conf" 2>/dev/null
    docker exec "$CONTAINER" sh -c "cat > '$AWG_WARP_CONF' <<'WARPEOF'
[Interface]
PrivateKey = ${pk}
Address = ${addr}
MTU = 1280
Table = off

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint}
PersistentKeepalive = 25
WARPEOF
chmod 600 '$AWG_WARP_CONF'"
}

awg_warp_up() {
    docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' >/dev/null 2>&1 || true"
    docker exec "$CONTAINER" sh -c "wg-quick up '$AWG_WARP_CONF'" || { echo -e "${RED}wg-quick up не удался.${NC}"; return 1; }
    docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" || { echo -e "${RED}Интерфейс warp не поднялся.${NC}"; return 1; }
}

# Полный перезапуск контейнера — используется вместо wg-quick down/up,
# когда меняется СОДЕРЖИМОЕ warp.conf на уже работающем интерфейсе
# (новый endpoint, новый ключ после лицензии/rekey/отката на Free).
# У AmneziaWG иногда остаётся "залипшее" состояние сокета/интерфейса,
# которое простой down+up внутри того же контейнера не сбрасывает —
# помогает только чистый рестарт контейнера (start.sh сам поднимет
# интерфейс заново с уже обновлённым файлом конфигурации).
awg_reload_warp_interface() {
    docker restart "$CONTAINER" >/dev/null 2>&1
    local a=0
    while [ "$a" -lt 15 ]; do
        docker exec "$CONTAINER" sh -c "true" 2>/dev/null && return 0
        sleep 1; ((a++))
    done
    if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
        return 0
    fi
    echo -e "${RED}Контейнер не отвечает после рестарта.${NC}"
    return 1
}

install_warp_awg() {
    clear; echo -e "\n${CYAN}━━━ Установка WARP (AmneziaWG) ━━━${NC}\n"
    if is_warp_installed_awg && is_warp_running_awg; then
        echo -e "${YELLOW}WARP уже установлен и работает.${NC}"; read -p "Enter..."; return
    fi
    if is_warp_installed_awg && ! is_warp_running_awg; then
        echo -e "${YELLOW}[*] WARP установлен, поднимаю интерфейс...${NC}"
        awg_warp_up && echo -e "${GREEN}  ✓ warp поднят${NC}" || echo -e "${RED}  Ошибка${NC}"
        read -p "Enter..."; return
    fi

    echo -e "${YELLOW}[1/4]${NC} Бэкап контейнера..."
    awg_backup; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[2/4]${NC} Скачиваю wgcf..."
    awg_install_wgcf || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"

    # ── WARP+ License: спрашиваем один раз при развёртывании каскада, ──
    # ── ДО регистрации/подключения аккаунта (см. примечание к          ──
    # ── awg_do_provision про баг Cloudflare с уже использованными      ──
    # ── free-аккаунтами). Сохраняем ключ в конфиг только после того,   ──
    # ── как Cloudflare его реально примет — невалидный ключ не висит.  ──
    local lic_key="${WARP_LICENSE_KEY:-}"
    if [ -z "$lic_key" ] && [ "${WARP_LICENSE_ASKED:-0}" != "1" ]; then
        save_config_val "WARP_LICENSE_ASKED" "1"
        echo ""
        read -p "$(echo -e "${CYAN}Есть лицензионный ключ WARP+? (y/n): ${NC}")" has_lic
        if [[ "$has_lic" == "y" ]]; then
            read -p "Введите WARP+ License Key: " lic_key
            lic_key=$(echo "$lic_key" | xargs)
        fi
    fi

    echo -e "${YELLOW}[3/4]${NC} Регистрация аккаунта, привязка лицензии и подключение..."
    if awg_do_provision "$lic_key" 0; then
        if [ -z "$lic_key" ]; then
            echo -e "${GREEN}  ✓ Free активен${NC}"
        else
            save_config_val "WARP_LICENSE_KEY" "$lic_key"
            if [ "${WARP_PLAN:-free}" = "plus" ]; then
                echo -e "${GREEN}  ✓ WARP+ активирован и подтверждён${NC}"
            else
                echo -e "${YELLOW}  ⚠ Лицензия принята Cloudflare, но статус пока показывает Free — перепроверьте позже через «Настройки WARP»${NC}"
            fi
        fi
    else
        save_config_val "WARP_LICENSE_KEY" ""
        echo -e "${RED}  ✗ Cloudflare отклонил ключ — он НЕ сохранён, работает Free. Введите ключ заново через «Настройки WARP»${NC}"
    fi

    echo -e "${YELLOW}[4/4]${NC} Готово."
    awg_detect_warp_exit_ip
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "\n  ${WHITE}WARP IP: ${GREEN}${AWG_WARP_EXIT_IP}${NC}"

    echo -e "\n${GREEN}WARP установлен! Управление клиентами — п.7.${NC}"
    log_action "AWG INSTALL: warp_ip=${AWG_WARP_EXIT_IP}, plan=${WARP_PLAN:-free}"
    read -p "Enter..."
}

start_warp_awg() {
    is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен (п.1).${NC}"; read -p "Enter..."; return; }
    is_warp_running_awg && { echo -e "\n${YELLOW}Уже работает.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${YELLOW}Поднимаю warp...${NC}"
    if awg_warp_up; then
        echo -e "${GREEN}[OK] WARP подключён.${NC}"; log_action "AWG START"
    else
        echo -e "${RED}Ошибка.${NC}"
    fi
    read -p "Enter..."
}

stop_warp_awg() {
    is_warp_running_awg || { echo -e "\n${YELLOW}Уже остановлен.${NC}"; read -p "Enter..."; return; }
    docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true"
    echo -e "${GREEN}[OK] WARP остановлен.${NC}"; log_action "AWG STOP"
    read -p "Enter..."
}

rekey_warp_awg() {
    is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${CYAN}━━━ Перевыпуск ключа WARP (AmneziaWG) ━━━${NC}\n"
    echo -e "${WHITE}Это создаст НОВЫЙ аккаунт wgcf (текущий wgcf-account.toml будет заменён).${NC}"
    read -p "Продолжить? (y/n): " c; [[ "$c" != "y" ]] && return

    echo -e "\n${YELLOW}[*]${NC} Пересоздаю аккаунт, подключаю, восстанавливаю лицензию..."
    if awg_do_provision "${WARP_LICENSE_KEY:-}" 1; then
        if [ -z "${WARP_LICENSE_KEY:-}" ]; then
            echo -e "${GREEN}  ✓ Free (лицензия не задана)${NC}"
        elif [ "${WARP_PLAN:-free}" = "plus" ]; then
            echo -e "${GREEN}  ✓ WARP+ переприменён и подтверждён${NC}"
        else
            echo -e "${YELLOW}  ⚠ Лицензия переприменена, но статус пока показывает Free — перепроверьте позже через «Настройки WARP»${NC}"
        fi
    else
        echo -e "${RED}  ✗ Cloudflare отклонил ключ, остаётся Free${NC}"
    fi

    echo -e "${GREEN}  ✓ Готово!${NC}"
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "  ${WHITE}Новый WARP IP: ${GREEN}${AWG_WARP_EXIT_IP}${NC}"
    read -p "Enter..."
}

show_status_awg() {
    clear; echo -e "\n${CYAN}━━━ Статус WARP (AmneziaWG) ━━━${NC}\n"
    echo -e "  ${WHITE}Контейнер: ${CYAN}${CONTAINER}${NC}"
    echo -e "  ${WHITE}Подсеть:   ${CYAN}${AWG_SUBNET:-N/A}${NC}"
    local st; st=$(get_warp_status_awg)
    local sc="$RED"; [[ "$st" == "Подключён"* ]] && sc="$GREEN"; [[ "$st" == "Отключён"* ]] && sc="$YELLOW"
    echo -e "  ${WHITE}WARP:      ${sc}${st}${NC}"
    local plan_label="${YELLOW}Free${NC}"
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        if [ "${WARP_PLAN:-free}" = "plus" ]; then
            plan_label="${GREEN}WARP+${NC}"
        else
            plan_label="${YELLOW}Лицензия применена, Cloudflare пока сообщает Free${NC}"
        fi
    fi
    echo -e "  ${WHITE}План:      $(echo -e "$plan_label")"
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        echo -e "  ${WHITE}License:   ${CYAN}${WARP_LICENSE_KEY:0:4}****${WARP_LICENSE_KEY: -4}${NC}"
    fi
    echo -e "  ${WHITE}Реальный IP: ${GREEN}${MY_IP}${NC}"
    awg_detect_warp_exit_ip
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "  ${WHITE}WARP IP:   ${GREEN}${AWG_WARP_EXIT_IP}${NC}"

    awg_load_clients
    echo -e "\n  ${WHITE}Клиентов в WARP: ${CYAN}${#AWG_SELECTED_IPS[@]}${NC}"
    if [ ${#AWG_SELECTED_IPS[@]} -gt 0 ]; then
        awg_parse_clients_table
        for ip in "${AWG_SELECTED_IPS[@]}"; do
            echo -e "    ${GREEN}●${NC} $(awg_format_label "$ip")"
        done
    fi

    if is_warp_running_awg; then
        echo -e "\n  ${CYAN}── wg show warp ──${NC}"
        docker exec "$CONTAINER" sh -c "wg show warp 2>/dev/null" | while IFS= read -r l; do echo -e "  ${WHITE}$l${NC}"; done
    fi
    echo ""; read -p "Enter..."
}

uninstall_awg() {
    echo -e "\n${YELLOW}Удаление WARP (AmneziaWG)...${NC}\n"

    awg_cleanup_rules
    docker exec "$CONTAINER" sh -c "
        wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true
        ip link del warp 2>/dev/null || true
        rm -rf '$AWG_WARP_DIR'
    " >/dev/null 2>&1
    echo -e "  ${GREEN}✓${NC}  WARP удалён из контейнера"

    awg_remove_from_start_sh
    if docker exec "$CONTAINER" sh -c '[ -f /opt/amnezia/start.sh.final-backup ]' 2>/dev/null; then
        docker exec "$CONTAINER" sh -c "
            cp /opt/amnezia/start.sh.final-backup '$AWG_START_SH' 2>/dev/null
            chmod +x '$AWG_START_SH' 2>/dev/null
            rm -f /opt/amnezia/start.sh.final-backup
        " 2>/dev/null
        echo -e "  ${GREEN}✓${NC}  start.sh восстановлен"
    fi

    rm -f "$WGCF_BIN" "$WGCF_ACCOUNT" "$WGCF_PROFILE"
    echo -e "  ${GREEN}✓${NC}  wgcf и профили удалены"
}

awg_restart_container() {
    echo -e "\n${YELLOW}Перезапуск контейнера ${CONTAINER}...${NC}"
    docker restart "$CONTAINER" >/dev/null
    local a=0
    while [ "$a" -lt 10 ]; do
        docker exec "$CONTAINER" sh -c "true" 2>/dev/null && { echo -e "${GREEN}[OK] Перезапущен.${NC}"; log_action "AWG RESTART"; read -p "Enter..."; return; }
        sleep 1; ((a++))
    done
    echo -e "${RED}Не удалось за 10с.${NC}"; read -p "Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA CLIENT MANAGEMENT
# ═══════════════════════════════════════════════════════════════

awg_load_clients() {
    AWG_SELECTED_IPS=()
    local raw; raw=$(docker exec "$CONTAINER" sh -c "cat '$AWG_WARP_CLIENTS' 2>/dev/null || true" | tr -d '\r')
    if [ -n "$raw" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)
            [ -n "$line" ] && AWG_SELECTED_IPS+=("$line")
        done <<< "$raw"
    fi
}

awg_save_clients() {
    local content=""
    for ip in "${AWG_SELECTED_IPS[@]}"; do
        content="${content}${ip}"$'\n'
    done
    docker exec "$CONTAINER" sh -c "mkdir -p '$AWG_WARP_DIR' && cat > '$AWG_WARP_CLIENTS' <<'CLEOF'
${content}CLEOF
"
}

awg_parse_clients_table() {
    AWG_CLIENT_NAMES=()

    local raw
    raw=$(docker exec "$CONTAINER" sh -c "cat '$AWG_CLIENTS_TABLE' 2>/dev/null || true" | tr -d '\r')
    [ -z "$raw" ] && return 0

    declare -A key_to_name=()
    local id_name_pairs
    id_name_pairs=$(echo "$raw" | awk '
        /"clientId"/ {
            s = $0
            gsub(/.*"clientId"[[:space:]]*:[[:space:]]*"/, "", s)
            gsub(/".*/, "", s)
            cid = s
        }
        /"clientName"/ {
            s = $0
            gsub(/.*"clientName"[[:space:]]*:[[:space:]]*"/, "", s)
            gsub(/".*/, "", s)
            name = s
            if (cid != "" && name != "") {
                print cid "|" name
            }
        }')

    if [ -n "$id_name_pairs" ]; then
        while IFS='|' read -r cid name; do
            [ -n "$cid" ] && [ -n "$name" ] && key_to_name["$cid"]="$name"
        done <<< "$id_name_pairs"
    fi

    local conf_peers
    conf_peers=$(docker exec "$CONTAINER" sh -c "cat '$AWG_VPN_CONF' 2>/dev/null || true" | tr -d '\r' | awk '
        /^\[Peer\]/ { pubkey=""; ip="" }
        /^PublicKey/ {
            s = $0
            sub(/^[^=]*= */, "", s)
            pubkey = s
        }
        /^AllowedIPs/ {
            s = $0
            sub(/^[^=]*= */, "", s)
            ip = s
            if (pubkey != "" && ip != "") {
                print pubkey "|" ip
            }
        }')

    if [ -n "$conf_peers" ]; then
        while IFS='|' read -r pubkey ip; do
            if [ -n "$pubkey" ] && [ -n "$ip" ] && [ -n "${key_to_name[$pubkey]+_}" ]; then
                local name="${key_to_name[$pubkey]}"
                AWG_CLIENT_NAMES["$ip"]="$name"
                local bare="${ip%/32}"
                AWG_CLIENT_NAMES["$bare"]="$name"
            fi
        done <<< "$conf_peers"
    fi

    return 0
}

awg_get_name() {
    local ip="$1" bare="${1%/32}"
    [ -n "${AWG_CLIENT_NAMES[$bare]+_}" ] && { echo "${AWG_CLIENT_NAMES[$bare]}"; return; }
    [ -n "${AWG_CLIENT_NAMES[$ip]+_}" ] && { echo "${AWG_CLIENT_NAMES[$ip]}"; return; }
    [ -n "${AWG_CLIENT_NAMES[${bare}/32]+_}" ] && { echo "${AWG_CLIENT_NAMES[${bare}/32]}"; return; }
}

awg_format_label() {
    local ip="$1" name; name=$(awg_get_name "$ip")
    [ -n "$name" ] && echo "$ip ($name)" || echo "$ip"
}

awg_get_client_ips() {
    AWG_CLIENT_IPS=()
    mapfile -t AWG_CLIENT_IPS < <(docker exec "$CONTAINER" sh -c "sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*\(.*\/32\)[[:space:]]*$/\1/p' '$AWG_VPN_CONF'" 2>/dev/null | tr -d '\r')
    if [ "${#AWG_CLIENT_IPS[@]}" -eq 0 ]; then
        mapfile -t AWG_CLIENT_IPS < <(docker exec "$CONTAINER" sh -c "awk '/^\[Peer\]/,/^$/' '$AWG_VPN_CONF' | sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p'" 2>/dev/null | tr -d '\r' | grep '/32')
    fi
}

awg_toggle_clients_ssh() {
    awg_get_client_ips; awg_parse_clients_table; awg_load_clients

    if [ ${#AWG_CLIENT_IPS[@]} -eq 0 ]; then
        echo -e "\n  ${RED}Нет клиентов в конфиге VPN.${NC}"
        read -p "Enter..."; return
    fi

    local -a pending_ips=()
    for ip in "${AWG_SELECTED_IPS[@]}"; do pending_ips+=("$ip"); done

    while true; do
        local pending_set=" ${pending_ips[*]+"${pending_ips[*]}"} "
        clear; echo -e "\n${CYAN}━━━ Управление клиентами WARP ━━━${NC}\n"
        echo -e "  ${DIM}Нажмите номер чтобы вкл/выкл WARP для клиента${NC}\n"

        local i=1 warp_count=0
        for ip in "${AWG_CLIENT_IPS[@]}"; do
            local label; label=$(awg_format_label "$ip")
            if [[ "$pending_set" == *" $ip "* ]]; then
                echo -e "  ${GREEN} $i) ✅  $label${NC}"
                ((warp_count++))
            else
                echo -e "  ${WHITE} $i)${NC} ☐   $label"
            fi
            ((i++))
        done

        echo ""
        echo -e "  ${WHITE}Через WARP: ${CYAN}${warp_count}${NC} из ${#AWG_CLIENT_IPS[@]}"
        echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}all${NC}) Включить всех   ${YELLOW}none${NC}) Выключить всех"
        echo -e "  ${GREEN}ok${NC})  Применить        ${DIM}0${NC})    Отмена (без изменений)"
        echo ""
        read -p "  > " answer

        case "$answer" in
            0|"")
                return ;;
            all)
                pending_ips=("${AWG_CLIENT_IPS[@]}") ;;
            none)
                pending_ips=() ;;
            ok)
                AWG_SELECTED_IPS=("${pending_ips[@]+"${pending_ips[@]}"}")
                echo -e "\n${YELLOW}  Применяю правила...${NC}"
                awg_save_clients; awg_apply_rules; awg_patch_start_sh
                echo -e "${GREEN}  ✓ Правила сохранены${NC}"
                echo -e "\n${YELLOW}  Перезапуск контейнера ${CONTAINER}...${NC}"
                docker restart "$CONTAINER" >/dev/null 2>&1
                local a=0
                while [ "$a" -lt 15 ]; do
                    docker exec "$CONTAINER" sh -c "true" 2>/dev/null && break
                    sleep 1; ((a++))
                done
                if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
                    echo -e "${GREEN}  ✓ Контейнер перезапущен${NC}"
                else
                    echo -e "${RED}  ⚠ Контейнер не отвечает${NC}"
                fi
                log_action "AWG CLIENTS APPLIED: ${#AWG_SELECTED_IPS[@]} in WARP, container restarted"
                read -p "  Enter..."; return ;;
            *)
                IFS=',' read -ra parts <<< "$answer"
                for p in "${parts[@]}"; do
                    p=$(echo "$p" | xargs)
                    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#AWG_CLIENT_IPS[@]} )); then
                        local ip="${AWG_CLIENT_IPS[$((p-1))]}"
                        if [[ "$pending_set" == *" $ip "* ]]; then
                            local -a tmp=()
                            for eip in "${pending_ips[@]}"; do
                                [ "$eip" != "$ip" ] && tmp+=("$eip")
                            done
                            pending_ips=("${tmp[@]+"${tmp[@]}"}")
                        else
                            pending_ips+=("$ip")
                        fi
                    fi
                done ;;
        esac
    done
}

awg_warp_settings_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Настройки WARP: License / Endpoint (AmneziaWG) ━━━${NC}\n"
        local plan_label="${YELLOW}Free${NC}"
        if [ -n "${WARP_LICENSE_KEY:-}" ]; then
            if [ "${WARP_PLAN:-free}" = "plus" ]; then
                plan_label="${GREEN}WARP+${NC}"
            else
                plan_label="${YELLOW}Лицензия применена, Cloudflare пока сообщает Free${NC}"
            fi
        fi
        echo -e "  ${WHITE}Текущий план:${NC}      $(echo -e "$plan_label")"
        if [ -n "${WARP_LICENSE_KEY:-}" ]; then
            echo -e "  ${WHITE}Сохранённый ключ:${NC} ${CYAN}${WARP_LICENSE_KEY:0:4}****${WARP_LICENSE_KEY: -4}${NC}"
        else
            echo -e "  ${WHITE}Сохранённый ключ:${NC} ${DIM}не задан${NC}"
        fi
        if is_warp_installed_awg; then
            local cur_ep; cur_ep=$(awg_get_active_endpoint)
            if [ -n "${WARP_ENDPOINT_OVERRIDE:-}" ]; then
                echo -e "  ${WHITE}Endpoint:${NC}          ${CYAN}${cur_ep:-$WARP_ENDPOINT_OVERRIDE}${NC} ${DIM}(задан вручную)${NC}"
            else
                echo -e "  ${WHITE}Endpoint:${NC}          ${CYAN}${cur_ep:-автоматически}${NC} ${DIM}(auto: engage.cloudflareclient.com)${NC}"
            fi
        fi
        echo -e "\n  1) ${GREEN}Ввести / изменить License Key и активировать WARP+${NC}"
        echo -e "  2) ${YELLOW}Вернуться на Free (отключить WARP+)${NC}"
        echo -e "  3) ${CYAN}Перепроверить статус лицензии (без пересоздания аккаунта)${NC}"
        echo -e "  4) ${GREEN}Указать свой Endpoint (IP:port)${NC}"
        echo -e "  5) ${YELLOW}Сбросить Endpoint на автоматический${NC}"
        echo -e "  6) ${RED}Удалить сохранённый License Key${NC}"
        echo -e "  0) ${DIM}Назад${NC}"
        echo ""
        read -p "  Выбор: " lc
        case "$lc" in
            1)
                is_warp_installed_awg || { echo -e "\n${RED}Сначала установите WARP (п.1).${NC}"; read -p "Enter..."; continue; }
                read -p "  Введите WARP+ License Key: " newkey
                newkey=$(echo "$newkey" | xargs)
                [ -z "$newkey" ] && continue
                echo -e "\n${WHITE}Аккаунт wgcf будет пересоздан — это нужно, чтобы Cloudflare гарантированно${NC}"
                echo -e "${WHITE}активировал WARP+ (иначе он часто остаётся на Free для уже подключавшегося аккаунта).${NC}\n"
                if awg_do_provision "$newkey" 1; then
                    save_config_val "WARP_LICENSE_KEY" "$newkey"
                    if [ "${WARP_PLAN:-free}" = "plus" ]; then
                        echo -e "\n${GREEN}[OK] WARP+ активирован и подтверждён.${NC}"
                    else
                        echo -e "\n${YELLOW}[OK] Cloudflare принял лицензию, но статус пока показывает Free.${NC}"
                        echo -e "${YELLOW}     Ключ и конфигурация сохранены — перепроверьте статус позже (п.3 этого меню).${NC}"
                    fi
                else
                    save_config_val "WARP_LICENSE_KEY" ""
                    echo -e "\n${RED}[!] Cloudflare отклонил ключ — он НЕ сохранён, оставлен Free. Проверьте ключ и попробуйте снова.${NC}"
                fi
                read -p "Enter..." ;;
            2)
                is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; continue; }
                echo ""
                awg_fallback_to_free
                awg_apply_rules; awg_patch_start_sh
                echo -e "\n${GREEN}[OK] Возвращено на Free.${NC}"
                read -p "Enter..." ;;
            3)
                is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; continue; }
                if [ -z "${WARP_LICENSE_KEY:-}" ]; then
                    echo -e "\n${YELLOW}Лицензия не задана — план Free.${NC}"; read -p "Enter..."; continue
                fi
                echo -e "\n${CYAN}Проверяю статус через Cloudflare trace...${NC}"
                local plan; plan=$(awg_detect_warp_plan)
                WARP_PLAN="$plan"; save_config_val "WARP_PLAN" "$plan"
                if [ "$plan" = "plus" ]; then
                    echo -e "${GREEN}[OK] Подтверждено: WARP+.${NC}"
                else
                    echo -e "${YELLOW}Статус: ${plan:-unknown}. Лицензия сохранена, попробуйте перепроверить позже.${NC}"
                fi
                read -p "Enter..." ;;
            4)
                is_warp_installed_awg || { echo -e "\n${RED}Сначала установите WARP (п.1).${NC}"; read -p "Enter..."; continue; }
                echo -e "\n${WHITE}Формат: IP:PORT или [IPv6]:PORT, например:${NC}"
                echo -e "  ${CYAN}162.159.192.1:2408${NC}"
                echo -e "  ${CYAN}[2602:fc59:b0:64::a29f:c08d]:2408${NC}"
                echo -e "${DIM}(рабочие порты Cloudflare WARP: 2408, 500, 1701, 4500, 4443, 8095, 8886, 51820)${NC}"
                echo -e "${YELLOW}Внимание: контейнер будет перезапущен — все VPN-клиенты на пару секунд отключатся.${NC}"
                read -p "  Введите Endpoint: " newep
                newep=$(echo "$newep" | xargs)
                [ -z "$newep" ] && continue
                if ! awg_is_valid_endpoint "$newep"; then
                    echo -e "\n${RED}Неверный формат. Нужно IP:PORT или [IPv6]:PORT.${NC}"; read -p "Enter..."; continue
                fi
                echo -e "\n${YELLOW}Перезапускаю контейнер и проверяю связь...${NC}"
                if awg_set_endpoint "$newep"; then
                    echo -e "\n${GREEN}[OK] Endpoint изменён на ${newep} и рабочий.${NC}"
                else
                    echo -e "\n${RED}[!] Этот endpoint не отвечает — автоматически откачен на предыдущий рабочий.${NC}"
                    echo -e "${WHITE}    Попробуйте ввести другой IP:PORT.${NC}"
                fi
                read -p "Enter..." ;;
            5)
                is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; continue; }
                echo ""
                if awg_set_endpoint ""; then
                    echo -e "\n${GREEN}[OK] Endpoint сброшен на автоматический и рабочий.${NC}"
                else
                    echo -e "\n${RED}[!] Автоматический endpoint тоже не отвечает — откачен на предыдущий.${NC}"
                fi
                read -p "Enter..." ;;
            6)
                if [ -z "${WARP_LICENSE_KEY:-}" ]; then
                    echo -e "\n${YELLOW}Сохранённый ключ отсутствует — удалять нечего.${NC}"; read -p "Enter..."; continue
                fi
                echo -e "\n${WHITE}Будет удалён сохранённый License Key: ${CYAN}${WARP_LICENSE_KEY:0:4}****${WARP_LICENSE_KEY: -4}${NC}"
                read -p "  Удалить? (y/n): " confirm_del
                [[ "$confirm_del" != "y" ]] && continue
                save_config_val "WARP_LICENSE_KEY" ""
                echo ""
                if is_warp_installed_awg; then
                    awg_fallback_to_free
                    awg_apply_rules; awg_patch_start_sh
                    echo -e "\n${GREEN}[OK] Ключ удалён, WARP переведён на Free.${NC}"
                else
                    WARP_PLAN="free"; save_config_val "WARP_PLAN" "free"
                    echo -e "\n${GREEN}[OK] Ключ удалён.${NC}"
                fi
                read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA RUNTIME RULES & PERSISTENCE
# ═══════════════════════════════════════════════════════════════

awg_cleanup_rules() {
    docker exec "$CONTAINER" sh -c '
        ip rule | awk "/lookup 100/ {print \$1}" | sed "s/://g" | sort -rn | while read -r pr; do
            ip rule del priority "$pr" 2>/dev/null || true
        done
        iptables -t nat -S POSTROUTING | grep "\-o warp -j MASQUERADE" | while read -r line; do
            rule=$(echo "$line" | sed "s/^-A /-D /")
            iptables -t nat $rule || true
        done
        ip route flush table 100 2>/dev/null || true
    ' >/dev/null 2>&1 || true
}

# Всегда работает с АКТУАЛЬНЫМ списком клиентов с диска (awg_load_clients),
# а не с тем, что может (или не может) лежать в памяти на момент вызова —
# иначе при вызове из меню License/Endpoint, минуя меню "Управление
# клиентами", AWG_SELECTED_IPS был бы пуст и все правила маршрутизации
# клиентов через warp стирались бы без восстановления.
awg_apply_rules() {
    awg_load_clients
    awg_cleanup_rules
    [ ${#AWG_SELECTED_IPS[@]} -eq 0 ] && return 0
    docker exec "$CONTAINER" sh -c "ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"
    local prio=100
    for ip in "${AWG_SELECTED_IPS[@]}"; do
        docker exec "$CONTAINER" sh -c "
            ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true
            iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE 2>/dev/null
        " >/dev/null 2>&1
        ((prio++))
    done
}

awg_patch_start_sh() {
    [ -z "${AWG_START_SH:-}" ] && return
    docker exec "$CONTAINER" sh -c "[ -f /opt/amnezia/start.sh.final-backup ] || cp '$AWG_START_SH' /opt/amnezia/start.sh.final-backup" 2>/dev/null

    local warp_block=""
    warp_block+="${AWG_MARKER_BEGIN}"$'\n'
    warp_block+=""$'\n'
    warp_block+="if [ -f '${AWG_WARP_CONF}' ]; then"$'\n'
    warp_block+="  wg-quick up '${AWG_WARP_CONF}' || true"$'\n'
    warp_block+="  sleep 3"$'\n'
    warp_block+="fi"$'\n'
    warp_block+=""$'\n'

    if [ ${#AWG_SELECTED_IPS[@]} -gt 0 ]; then
        warp_block+="ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
        warp_block+=""$'\n'
        local prio=100
        for ip in "${AWG_SELECTED_IPS[@]}"; do
            warp_block+="ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true"$'\n'
            warp_block+="iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE 2>/dev/null"$'\n'
            ((prio++))
        done
    fi

    warp_block+=""$'\n'
    warp_block+="${AWG_MARKER_END}"

    docker exec "$CONTAINER" sh -c "
        if grep -qF '${AWG_MARKER_BEGIN}' '$AWG_START_SH'; then
            sed -i '/# --- AWGWARP-MANAGER BEGIN ---/,/# --- AWGWARP-MANAGER END ---/d' '$AWG_START_SH'
        fi
    " 2>/dev/null

    docker exec "$CONTAINER" sh -c "
        if grep -qF 'tail -f /dev/null' '$AWG_START_SH'; then
            tmpfile=\$(mktemp)
            while IFS= read -r line; do
                if echo \"\$line\" | grep -qF 'tail -f /dev/null'; then
                    cat <<'WARPBLOCK'
${warp_block}
WARPBLOCK
                fi
                echo \"\$line\"
            done < '$AWG_START_SH' > \"\$tmpfile\"
            mv \"\$tmpfile\" '$AWG_START_SH'
            chmod +x '$AWG_START_SH'
        else
            cat >> '$AWG_START_SH' <<'WARPBLOCK'

${warp_block}
WARPBLOCK
            chmod +x '$AWG_START_SH'
        fi
    " 2>/dev/null
}

awg_remove_from_start_sh() {
    [ -z "${AWG_START_SH:-}" ] && return
    docker exec "$CONTAINER" sh -c "
        if grep -qF '${AWG_MARKER_BEGIN}' '$AWG_START_SH' 2>/dev/null; then
            sed -i '/# --- AWGWARP-MANAGER BEGIN ---/,/# --- AWGWARP-MANAGER END ---/d' '$AWG_START_SH'
        fi
    " 2>/dev/null
}
# ═══════════════════════════════════════════════════════════════
#  INFO
# ═══════════════════════════════════════════════════════════════

show_info() {
    clear; echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  📚 AWGWARP Manager v${WARP_VERSION}                             ${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}═══ AmneziaWG ═══${NC}\n"
    echo -e "${WHITE}  Клиент → AmneziaWG Docker → warp WG → Cloudflare → Интернет${NC}\n"
    echo -e "${GREEN}  1.${NC} wgcf генерирует WireGuard-профиль WARP"
    echo -e "${GREEN}  2.${NC} WG-интерфейс warp внутри Docker-контейнера"
    echo -e "${GREEN}  3.${NC} Маршрутизация per-client через ip rule"
    echo -e "${GREEN}  4.${NC} Персистентность через start.sh контейнера"
    echo -e "\n${GREEN}  ✓${NC}  Разблокировка ChatGPT, Netflix, Disney+, Spotify"
    echo -e "${GREEN}  ✓${NC}  Чистый IP от Cloudflare"
    echo -e "${GREEN}  ✓${NC}  Бесплатно (Cloudflare WARP)"
    echo ""; read -p "Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  FULL UNINSTALL
# ═══════════════════════════════════════════════════════════════

full_uninstall() {
    clear
    echo -e "\n${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}            ⚠  ПОЛНОЕ УДАЛЕНИЕ AWGWARP MANAGER  ⚠                  ${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}\n"
    echo -e "${WHITE}Режим: ${CYAN}AmneziaWG${NC}\n"
    read -p "$(echo -e "${RED}Удалить полностью? (y/n): ${NC}")" c1
    [[ "$c1" != "y" ]] && return

    uninstall_awg

    rm -f "$NIGHTLY_CRON_FILE" 2>/dev/null
    echo -e "  ${GREEN}✓${NC}  Ночное автообслуживание (cron)"

    rm -rf "$WARP_DIR" "$WARP_LOG"
    echo -e "  ${GREEN}✓${NC}  Конфигурация и логи"
    rm -f /usr/local/bin/awgwarp
    echo -e "  ${GREEN}✓${NC}  Команда awgwarp"

    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  AWGWARP Manager полностью удалён.${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    log_action "UNINSTALL: full removal (amnezia)"
    read -p "Enter..."
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  NIGHTLY MAINTENANCE — автообновление WARP + рестарт в 03:00
# ═══════════════════════════════════════════════════════════════

NIGHTLY_CRON_FILE="/etc/cron.d/awgwarp-manager-nightly"

nightly_cron_status() {
  [ -f "$NIGHTLY_CRON_FILE" ] && echo "on" || echo "off"
}

install_nightly_cron() {
  cat > "$NIGHTLY_CRON_FILE" <<EOF
# AWGWARP Manager: ночное автообслуживание (проверка обновлений + рестарт), ежедневно в 03:00
0 3 * * * root /usr/local/bin/awgwarp --nightly-maintenance >/dev/null 2>&1
EOF
  chmod 644 "$NIGHTLY_CRON_FILE"
  systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
  log_action "NIGHTLY: автообслуживание включено (03:00 ежедневно)"
}

remove_nightly_cron() {
  rm -f "$NIGHTLY_CRON_FILE"
  log_action "NIGHTLY: автообслуживание выключено"
}

# ── AmneziaWG: проверка обновления бинарника wgcf, без потери аккаунта/лицензии ──
nightly_update_wgcf() {
  [ -x "$WGCF_BIN" ] || return 0

  local latest
  latest=$(curl -4 -s --max-time 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')

  if [ -z "$latest" ] || [ "$latest" = "${WGCF_VERSION}" ]; then
    log_action "NIGHTLY AWG: wgcf без изменений (версия ${WGCF_VERSION})"
    return 0
  fi

  local arch wa
  arch=$(uname -m)
  case "$arch" in
    x86_64) wa="amd64" ;;
    aarch64) wa="arm64" ;;
    armv7l) wa="armv7" ;;
    *) log_action "NIGHTLY AWG: неизвестная архитектура $arch, пропуск"; return 0 ;;
  esac

  local tmp_bin="/root/wgcf.new"
  if robust_download "https://github.com/ViRb3/wgcf/releases/download/v${latest}/wgcf_${latest}_linux_${wa}" "$tmp_bin" \
    && chmod +x "$tmp_bin" && "$tmp_bin" --version >/dev/null 2>&1; then
    mv -f "$tmp_bin" "$WGCF_BIN"
    save_config_val "WGCF_VERSION" "$latest"
    WGCF_VERSION="$latest"
    log_action "NIGHTLY AWG: wgcf обновлён до ${latest} (аккаунт и лицензия сохранены)"
  else
    rm -f "$tmp_bin"
    log_action "NIGHTLY AWG: ВНИМАНИЕ — не удалось скачать/проверить wgcf ${latest}, оставлена текущая версия"
  fi
}

# ── Рестарт контейнера — точная копия рестарта после сохранения клиентов WARP ──
nightly_restart_awg_container() {
  [ -z "${CONTAINER:-}" ] && return 0

  echo -e "\n${YELLOW}  Перезапуск контейнера ${CONTAINER}...${NC}"
  docker restart "$CONTAINER" >/dev/null 2>&1
  local a=0
  while [ "$a" -lt 15 ]; do
    docker exec "$CONTAINER" sh -c "true" 2>/dev/null && break
    sleep 1; ((a++))
  done
  if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Контейнер перезапущен${NC}"
    log_action "NIGHTLY AWG: контейнер перезапущен успешно"
  else
    echo -e "${RED}  ⚠ Контейнер не отвечает${NC}"
    log_action "NIGHTLY AWG: ВНИМАНИЕ — контейнер не отвечает после рестарта"
  fi
}

nightly_maintenance() {
  init_config
  get_my_ip >/dev/null 2>&1

  log_action "NIGHTLY: старт автообслуживания"

  if awg_pick_container 2>/dev/null; then
    awg_load_container_data 2>/dev/null
    nightly_update_wgcf
    nightly_restart_awg_container
  else
    log_action "NIGHTLY AWG: контейнер не найден, пропуск"
  fi

  log_action "NIGHTLY: автообслуживание завершено"
}

nightly_cron_menu() {
  while true; do
    clear
    local st; st=$(nightly_cron_status)
    echo -e "\n${CYAN}━━━ Ночное автообслуживание (03:00) ━━━${NC}\n"
    if [ "$st" = "on" ]; then
      echo -e "  Статус: ${GREEN}Включено${NC}"
    else
      echo -e "  Статус: ${YELLOW}Выключено${NC}"
    fi
    echo -e "\n  Каждую ночь в ${WHITE}03:00${NC} будет выполняться:"
    echo -e "   ${DIM}•${NC} Проверка обновления wgcf + рестарт контейнера ${CONTAINER:-} (даже без обновлений)"
    echo ""
    echo -e "  1) Включить"
    echo -e "  2) Выключить"
    echo -e "  3) Запустить сейчас (тест)"
    echo -e "  0) Назад"
    read -p "  Выбор: " c
    case "$c" in
      1) install_nightly_cron; echo -e "${GREEN}✓ Включено${NC}"; read -p "Enter..." ;;
      2) remove_nightly_cron; echo -e "${YELLOW}✓ Выключено${NC}"; read -p "Enter..." ;;
      3) nightly_maintenance; echo -e "${GREEN}✓ Выполнено. Лог: ${WARP_LOG}${NC}"; read -p "Enter..." ;;
      0) return ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear
        local st sc
        st=$(get_warp_status_awg)
        sc="$RED"; [[ "$st" == *"Подключён"* ]] && sc="$GREEN"; [[ "$st" == *"Отключён"* && "$st" != *"Подключён"* ]] && sc="$YELLOW"

        echo -e "${MAGENTA}══════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  AWGWARP Manager v${WARP_VERSION}                        ${NC}"
        echo -e "${MAGENTA}══════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}IP сервера:${NC} ${GREEN}${MY_IP}${NC}   ${WHITE}Режим:${NC} ${CYAN}AmneziaWG${NC}"
        echo -e "  ${WHITE}WARP:${NC} ${sc}${st}${NC}"
        if [ -n "${CONTAINER:-}" ]; then
            echo -e "  ${WHITE}Контейнер:${NC} ${CYAN}${CONTAINER}${NC}"
        fi

        echo -e "\n${CYAN}── WARP-ключ ──────────────────────────────────────────${NC}"
        echo -e "  1) ${GREEN}Установить WARP${NC}"
        echo -e "  2) ${CYAN}Запустить WARP${NC}"
        echo -e "  3) ${YELLOW}Остановить WARP${NC}"
        echo -e "  4) 📊 Статус"
        echo -e "  5) 🔑 ${YELLOW}Перевыпуск ключа${NC}"

        echo -e "\n${CYAN}── AmneziaWG ──────────────────────────────────────────${NC}"
        echo -e "  6) 👥 ${GREEN}Управление клиентами WARP${NC}"
        local plan_short="Free"
        if [ -n "${WARP_LICENSE_KEY:-}" ]; then
            [ "${WARP_PLAN:-free}" = "plus" ] && plan_short="WARP+" || plan_short="WARP+?"
        fi
        echo -e "  7) 🔐 ${CYAN}Настройки WARP (License / Endpoint)${NC} ${DIM}(план: ${plan_short})${NC}"

        echo -e "\n${CYAN}── Автообслуживание ────────────────────────────────────${NC}"
        local ncs ncs_label lg_label
        ncs=$(nightly_cron_status)
        ncs_label="${YELLOW}Выкл${NC}"; [ "$ncs" = "on" ] && ncs_label="${GREEN}Вкл${NC}"
        echo -e "  8) 🌙 ${CYAN}Ночное обслуживание (03:00)${NC} ${DIM}(статус: ${NC}${ncs_label}${DIM})${NC}"
        lg_label="${YELLOW}Выкл${NC}"; [ "${LOG_ENABLED:-0}" = "1" ] && lg_label="${GREEN}Вкл${NC}"
        echo -e "  9) 📝 ${CYAN}Логирование в awgwarp-manager.log${NC} ${DIM}(статус: ${NC}${lg_label}${DIM})${NC}"

        echo -e "\n${CYAN}── Прочее ─────────────────────────────────────────────${NC}"
        echo -e " 10) ${MAGENTA}📚 Инструкция${NC}"
        echo -e " 11) ${RED}⚠  Полное удаление${NC}"
        echo -e "  0) Выход"
        echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
        read -p "  Выбор: " ch

        case $ch in
            1)  install_warp_awg ;;
            2)  start_warp_awg ;;
            3)  stop_warp_awg ;;
            4)  show_status_awg ;;
            5)  rekey_warp_awg ;;
            6)  awg_toggle_clients_ssh ;;
            7)  awg_warp_settings_menu ;;
            8)  nightly_cron_menu ;;
            9)  log_toggle_menu ;;
            10) show_info ;;
            11) full_uninstall ;;
            0)  exit 0 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  STARTUP
# ═══════════════════════════════════════════════════════════════

run_startup() {
    local total=6 s=0

    clear; echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}            AWGWARP Manager v${WARP_VERSION} — Загрузка          ${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка root..." "$s" "$total"
    check_root
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   root OK                                    \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Зависимости..." "$s" "$total"
    check_deps
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Зависимости OK                             \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка команды awgwarp..." "$s" "$total"
    local upgrade_msg="установлена"
    [ -s "/usr/local/bin/awgwarp" ] && upgrade_msg="обновлена (v${WARP_VERSION})"
    if [ "$(readlink -f "$0" 2>/dev/null)" != "/usr/local/bin/awgwarp" ]; then
        if [ -s "$0" ]; then
            # $0 — реальный читаемый файл (обычный запуск: bash script.sh).
            cp -f "$0" "/usr/local/bin/awgwarp.tmp" 2>/dev/null
        else
            # $0 не годится для копирования — типичный случай:
            # запуск через process substitution (bash <(curl ...)),
            # где $0 указывает на одноразовый канал (/dev/fd/N),
            # который к этому моменту уже пуст (EOF). Копировать
            # оттуда нечего — молча создавать 0-байтный файл нельзя,
            # это хуже, чем вообще не установить команду.
            rm -f "/usr/local/bin/awgwarp.tmp" 2>/dev/null
        fi
        if [ -s "/usr/local/bin/awgwarp.tmp" ]; then
            mv -f "/usr/local/bin/awgwarp.tmp" "/usr/local/bin/awgwarp"
            chmod +x "/usr/local/bin/awgwarp"
        else
            rm -f "/usr/local/bin/awgwarp.tmp" 2>/dev/null
            if [ ! -s "/usr/local/bin/awgwarp" ]; then
                printf "\r  ${CYAN}[%d/%d]${NC}  ${RED}✗${NC}   Не удалось установить команду awgwarp                        \n" "$s" "$total"
                echo -e "${YELLOW}  Похоже, скрипт запущен через 'bash <(curl ...)' — из такого запуска${NC}"
                echo -e "${YELLOW}  self-copy не работает (\$0 указывает на одноразовый канал, не файл).${NC}"
                echo -e "${YELLOW}  Скачайте скрипт в обычный файл и запустите его так:${NC}"
                echo -e "${CYAN}    curl -fsSL <URL> -o awgwarp.sh && bash awgwarp.sh${NC}"
                upgrade_msg="НЕ установлена"
            else
                upgrade_msg="оставлена как есть (не удалось обновить)"
            fi
        fi
    fi
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Команда awgwarp %s (локально)         \n" "$s" "$total" "$upgrade_msg"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Определение IP..." "$s" "$total"
    get_my_ip
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   IP: %-25s             \n" "$s" "$total" "$MY_IP"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Docker контейнер AmneziaWG..." "$s" "$total"
    if awg_pick_container 2>/dev/null; then
        awg_load_container_data 2>/dev/null
        printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Контейнер: %-20s        \n" "$s" "$total" "$CONTAINER"
    else
        printf "\r  ${CYAN}[%d/%d]${NC}  ${YELLOW}⚠${NC}   Контейнер не найден                     \n" "$s" "$total"
    fi

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка WARP..." "$s" "$total"
    local ws; ws=$(get_warp_status_awg)
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   WARP: %-25s           \n" "$s" "$total" "$ws"

    echo ""
    local w=40 bar=""
    for ((i=0; i<w; i++)); do bar+="█"; done
    echo -e "  ${CYAN}[${GREEN}${bar}${CYAN}]${NC} ${GREEN}100%${NC}"
    echo -e "\n  ${GREEN}✅  AWGWARP Manager v${WARP_VERSION} (AmneziaWG) готов!${NC}\n"
    sleep 2

    show_info
    show_menu
}

# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
    --nightly-maintenance) nightly_maintenance ;;
    *) init_config; run_startup ;;
esac
