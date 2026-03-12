#!/bin/bash

# ============================================================================
#  UBUNTU SERVER OPTIMIZATION SCRIPT  v3.2
# ============================================================================

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "Ошибка: требуются права root. Запустите: sudo $0"
    exit 1
fi

set -eo pipefail

# --- Цвета (ANSI C quoting) ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# --- Иконки ---
OK="[OK]"
WARN="[!!]"
ERR="[XX]"
INFO="[ii]"
SKIP="[>>]"
CLEAN="[**]"
PLUS="[++]"
LOCK="[##]"

# --- Статистика ---
INSTALLED_UTILS=0
FREED_SPACE_BEFORE=0
SCRIPT_START_TIME=$(date +%s)
CURRENT_SECTION=0
SECTION_START_TIME=0
TOTAL_SECTIONS=10
AUTO_MODE=false

IS_TTY=false
[ -t 1 ] && IS_TTY=true

# ─── Spinner ─────────────────────────────────────────────────────────────────
spinner() {
    local pid=$1 msg=$2
    local chars='|/-\' i=0
    local t0; t0=$(date +%s)
    if [ "$IS_TTY" = true ]; then
        tput civis 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            local e=$(( $(date +%s) - t0 ))
            printf "\r${YELLOW}  ${chars:$(( i % 4 )):1} ${msg} ${CYAN}[${e}s]${NC}"
            i=$(( i + 1 )); sleep 0.15
        done
        tput cnorm 2>/dev/null || true
        local total=$(( $(date +%s) - t0 ))
        printf "\r${GREEN}  ${OK} ${msg} ${DIM}(${total}s)${NC}\n"
    else
        echo "  >> ${msg}..."
        wait "$pid" 2>/dev/null || true
        echo "  ${OK} ${msg} — готово"
    fi
}

# ─── Подтверждение ───────────────────────────────────────────────────────────
confirm() {
    [ "$AUTO_MODE" = true ] && return 0
    while true; do
        printf "${MAGENTA}  ? $1 ${CYAN}[y/n]: ${NC}"
        read -r yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo -e "${YELLOW}  Введите y или n.${NC}" ;;
        esac
    done
}

# ─── Прогресс-бар ────────────────────────────────────────────────────────────
show_progress() {
    local cur=$1 total=$2 w=48
    local pct=$(( cur * 100 / total ))
    local fill=$(( w * cur / total ))
    local empty=$(( w - fill ))
    printf "${BLUE}  ["
    printf "%${fill}s"  | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] ${BOLD}%3d%%${NC} ${DIM}(%d/%d)${NC}\n" "$pct" "$cur" "$total"
}

# ─── Секции ──────────────────────────────────────────────────────────────────
section_start() {
    CURRENT_SECTION=$(( CURRENT_SECTION + 1 ))
    SECTION_START_TIME=$(date +%s)
    echo ""
    printf "${BLUE}  ════════════════════════════════════════════════════════${NC}\n"
    show_progress "$CURRENT_SECTION" "$TOTAL_SECTIONS"
    echo -e "${CYAN}${BOLD}  ▶  $1${NC}"
    echo ""
}
section_end() {
    local dur=$(( $(date +%s) - SECTION_START_TIME ))
    echo ""
    echo -e "${DIM}  ✔ Выполнено за ${dur}s${NC}"
}
section_separator() {
    printf "${BLUE}  ════════════════════════════════════════════════════════${NC}\n"
}

# ─── Расчёт SWAP ─────────────────────────────────────────────────────────────
calculate_swap_size() {
    local ram_gb; ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    [ -z "$ram_gb" ] || [ "$ram_gb" -eq 0 ] && { echo "4G"; return; }
    if   [ "$ram_gb" -lt 2  ]; then local s=$(( ram_gb * 2 )); [ "$s" -lt 2 ] && s=2; echo "${s}G"
    elif [ "$ram_gb" -lt 4  ]; then echo "4G"
    elif [ "$ram_gb" -lt 8  ]; then
        local s=$(( ram_gb / 2 ))
        [ "$s" -lt 4 ] && s=4
        [ "$s" -gt 8 ] && s=8
        echo "${s}G"
    elif [ "$ram_gb" -lt 16 ]; then echo "8G"
    else echo "16G"
    fi
}

# ─── Создание SWAP ───────────────────────────────────────────────────────────
create_swap_file() {
    local swap_size=$1
    local swap_gb; swap_gb=$(echo "$swap_size" | sed 's/G$//')
    local avail_kb; avail_kb=$(df / | awk 'NR==2{print $4}')
    local need_kb=$(( swap_gb * 1024 * 1024 + 524288 ))
    if [ "$avail_kb" -lt "$need_kb" ]; then
        echo -e "${RED}  ${ERR} Недостаточно места! Нужно ~${swap_gb}GB + 512MB, доступно: $(df -h / | awk 'NR==2{print $4}')${NC}"
        return 1
    fi
    set +e
    fallocate -l "$swap_size" /swapfile > /dev/null 2>&1 &
    local fpid=$!
    spinner $fpid "Создание /swapfile ${swap_size} (fallocate)"
    wait $fpid; local frc=$?
    set -e
    if [ $frc -ne 0 ]; then
        echo -e "${YELLOW}  ${WARN} fallocate не поддерживается — используем dd...${NC}"
        dd if=/dev/zero of=/swapfile bs=1M count=$(( swap_gb * 1024 )) status=none &
        spinner $! "Создание /swapfile ${swap_size} (dd)"
    fi
    chmod 600 /swapfile
    echo -e "${GREEN}  ${OK} Права /swapfile: 600${NC}"
    if mkswap /swapfile > /dev/null 2>&1; then
        echo -e "${GREEN}  ${OK} /swapfile отформатирован${NC}"
    else
        echo -e "${RED}  ${ERR} Ошибка mkswap!${NC}"; rm -f /swapfile; return 1
    fi
    if swapon /swapfile; then
        echo -e "${GREEN}  ${OK} Swap активирован${NC}"
    else
        echo -e "${RED}  ${ERR} Ошибка swapon!${NC}"; rm -f /swapfile; return 1
    fi
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo -e "${GREEN}  ${OK} /swapfile добавлен в /etc/fstab${NC}"
    if grep -q 'vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
    else
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    sysctl -q vm.swappiness=10
    echo -e "${GREEN}  ${OK} vm.swappiness=10${NC}"
    return 0
}

# ─── install_util ─────────────────────────────────────────────────────────────
declare -A PKG_CMD=([speedtest-cli]="speedtest" [mtr]="mtr")
install_util() {
    local pkg=$1 desc=$2
    local cmd="${PKG_CMD[$pkg]:-$pkg}"
    if ! command -v "$cmd" &>/dev/null; then
        if confirm "Установить ${BOLD}${pkg}${NC} — ${desc}?"; then
            set +e
            DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$pkg" > /dev/null 2>&1 &
            spinner $! "Установка ${pkg}"
            wait $!; local rc=$?
            set -e
            if [ $rc -eq 0 ]; then
                echo -e "${GREEN}  ${OK} ${pkg} установлен${NC}"
                INSTALLED_UTILS=$(( INSTALLED_UTILS + 1 ))
            else
                echo -e "${RED}  ${ERR} Ошибка установки ${pkg} (код: ${rc})${NC}"
                if ! confirm "Продолжить несмотря на ошибку?"; then exit 1; fi
            fi
        else
            echo -e "${DIM}  ${SKIP} ${pkg} пропущен${NC}"
        fi
    else
        echo -e "${DIM}  ${INFO} ${pkg} уже установлен${NC}"
    fi
}

# ─── journald параметр ────────────────────────────────────────────────────────
set_journal_param() {
    local key=$1 val=$2 file=/etc/systemd/journald.conf
    if grep -qE "^#?${key}=" "$file"; then
        sed -i "s|^#\?${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# ─── Очистка корзины (вынесена отдельной функцией, явный return 0) ────────────
#  ИСПРАВЛЕНО: || return и && return заменены на if/fi,
#  чтобы set -e не прерывал скрипт при возврате ненулевого кода
_clean_trash() {
    local path=$1 uname=$2
    if [ ! -d "$path" ]; then return 0; fi
    local sz; sz=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
    if [ "${sz:-0}" -le 4096 ]; then return 0; fi
    local hr; hr=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
    _TOTAL_TRASH=$(( _TOTAL_TRASH + sz ))
    rm -rf "${path}/files" "${path}/info" 2>/dev/null || true
    mkdir -p "${path}/files" "${path}/info"  2>/dev/null || true
    echo -e "${GREEN}  ${CLEAN} ${uname}: ${hr}${NC}"
    return 0
}

# ─── Меню ─────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo ""
    echo -e "${BLUE}  ╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${NC}  ${CYAN}${BOLD}  UBUNTU SERVER OPTIMIZATION  v3.2             ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ║${NC}  ${DIM}  Комплексная оптимизация Ubuntu Server         ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Выберите режим:${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}1)${NC}  Автоматический   ${DIM}— всё по умолчанию, без вопросов${NC}"
    echo -e "  ${BOLD}${YELLOW}2)${NC}  Интерактивный    ${DIM}— каждое действие с подтверждением${NC}"
    echo ""
    printf "  ${MAGENTA}Ваш выбор ${CYAN}[1-2]: ${NC}"
    read -r MODE
    case $MODE in
        1) AUTO_MODE=true ;;
        2) AUTO_MODE=false ;;
        *) echo -e "${RED}  ${ERR} Неверный выбор.${NC}"; exit 1 ;;
    esac
    echo ""
}

# ─── Сводка (полностью переработана) ─────────────────────────────────────────
show_summary() {
    local rec_swap; rec_swap=$(calculate_swap_size)

    echo -e "${BLUE}  ╔═════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${CYAN}${BOLD}               ЧТО БУДЕТ ВЫПОЛНЕНО                     ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╠══════╦══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}  ║${NC} ${DIM} #  ${NC}${BLUE}║${NC}  ${DIM}Операция${NC}                                           ${BLUE}║${NC}"
    echo -e "${BLUE}  ╠══════╬══════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}  ║${NC}  ${GREEN}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "1"  "Обновление системы и пакетов (apt upgrade)"
    printf "${BLUE}  ║${NC}  ${GREEN}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "2"  "Утилиты: curl · wget · git · unzip · speedtest · mtr"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "3"  "SWAP: ${rec_swap}  ·  swappiness=10"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "4"  "BBR · TCP · ECN · очереди · UDP-буферы · sysctl"
    printf "${BLUE}  ║${NC}  ${CYAN}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "5"  "Отключение IPv6 (systemd-сервис)"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "6"  "Диски: TRIM · vm.dirty_*"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "7"  "Память: vfs_cache_pressure · min_free_kbytes"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "8"  "Systemd · journald (500MB / 7d) · logrotate"
    printf "${BLUE}  ║${NC}  ${YELLOW}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "9"  "Лимиты: nofile=65536 · nproc=32768"
    printf "${BLUE}  ║${NC}  ${GREEN}%2s${NC}  ${BLUE}║${NC}  ${NC}%-53s${BLUE}║${NC}\n" "10" "Очистка: пакеты · кеш · ядра · логи · /tmp · корзины"
    echo -e "${BLUE}  ╠══════╩══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}  ║${NC}  ${YELLOW}${WARN}${NC}  Рекомендуется перезагрузка после завершения         ${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if ! confirm "Начать выполнение?"; then
        echo -e "${RED}  Отменено.${NC}"; exit 0
    fi
    FREED_SPACE_BEFORE=$(df / | awk 'NR==2{print $3}')
}

# ─── Итоговый отчёт ───────────────────────────────────────────────────────────
generate_report() {
    local t=$(( $(date +%s) - SCRIPT_START_TIME ))
    local after; after=$(df / | awk 'NR==2{print $3}')
    local freed=$(( FREED_SPACE_BEFORE - after ))

    local swap_info="не настроен"
    if [ -f /swapfile ]; then
        local sb; sb=$(stat -c%s /swapfile 2>/dev/null || echo 0)
        if [ "$sb" -gt 0 ]; then
            swap_info="$(( sb / 1024 / 1024 / 1024 ))GB"
        else
            swap_info=$(swapon --show=SIZE --noheadings /swapfile 2>/dev/null | head -1 || echo "активен")
        fi
    fi

    echo ""
    section_separator
    echo ""
    echo -e "${BLUE}  ╔═════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${CYAN}${BOLD}                  ОТЧЁТ О ВЫПОЛНЕНИИ                   ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╠══════════════════════════════╦══════════════════════════════╣${NC}"
    printf "${BLUE}  ║${NC}  %-28s${BLUE}║${NC}  ${BOLD}%-28s${NC}${BLUE}║${NC}\n" "Установлено утилит:"    "${INSTALLED_UTILS}"
    printf "${BLUE}  ║${NC}  %-28s${BLUE}║${NC}  ${BOLD}%-28s${NC}${BLUE}║${NC}\n" "SWAP:"                  "${swap_info} (swappiness=10)"
    printf "${BLUE}  ║${NC}  %-28s${BLUE}║${NC}  ${BOLD}%-28s${NC}${BLUE}║${NC}\n" "BBR + TCP / sysctl:"    "применены"
    if [ "$freed" -gt 0 ]; then
        local fhr; fhr=$(numfmt --to=iec-i --suffix=B $(( freed * 1024 )) 2>/dev/null || echo "${freed}KB")
        printf "${BLUE}  ║${NC}  %-28s${BLUE}║${NC}  ${BOLD}%-28s${NC}${BLUE}║${NC}\n" "Освобождено места:"   "${fhr}"
    else
        printf "${BLUE}  ║${NC}  %-28s${BLUE}║${NC}  ${BOLD}%-28s${NC}${BLUE}║${NC}\n" "Место на диске:"      "оптимизировано"
    fi
    echo -e "${BLUE}  ╠══════════════════════════════╩══════════════════════════════╣${NC}"
    echo -e "${BLUE}  ║${NC}  ${CYAN}${BOLD}⏱  Время:${NC} ${t}s ${DIM}($(( t / 60 ))m $(( t % 60 ))s)${NC}$(df -h / | awk 'NR==2{printf "   %s из %s (%s)", $3, $2, $5}')         ${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================================
# ЗАПУСК
# ============================================================================
clear
show_menu
show_summary

# ── 1. ОБНОВЛЕНИЕ СИСТЕМЫ ─────────────────────────────────────────────────────
section_start "ОБНОВЛЕНИЕ СИСТЕМЫ"

if [ ! -f /etc/apt/apt.conf.d/99-optimizations ]; then
    cat > /etc/apt/apt.conf.d/99-optimizations <<'EOF'
Acquire::http::MaxConnections "10";
Acquire::http::Pipeline-Depth "5";
Acquire::CompressionTypes::Order:: "gz";
Acquire::http::Timeout "10";
Acquire::ftp::Timeout  "10";
EOF
    echo -e "${GREEN}  ${OK} APT настройки оптимизированы${NC}"
fi

apt-get update -qq > /dev/null 2>&1 &
spinner $! "Обновление списков пакетов"
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -yqq > /dev/null 2>&1 &
spinner $! "Полное обновление системы"

section_end

# ── 2. БАЗОВЫЕ УТИЛИТЫ ───────────────────────────────────────────────────────
section_start "УСТАНОВКА УТИЛИТ"

install_util "curl"          "загрузка файлов из интернета"
install_util "wget"          "альтернатива curl"
install_util "git"           "система контроля версий"
install_util "unzip"         "распаковка ZIP-архивов"
install_util "speedtest-cli" "тест скорости интернета"
install_util "mtr"           "диагностика сети (ping + traceroute)"

section_end

# ── 3. SWAP ───────────────────────────────────────────────────────────────────
section_start "НАСТРОЙКА SWAP"

SWAP_SIZE=$(calculate_swap_size)
RAM_GB=$(free -g | awk '/^Mem:/{print $2}'); [ -z "$RAM_GB" ] && RAM_GB=0
echo -e "${BLUE}  ${INFO} RAM: ${BOLD}${RAM_GB}GB${NC}  →  рекомендуемый SWAP: ${BOLD}${SWAP_SIZE}${NC}"

if [ -f /swapfile ]; then
    echo -e "${YELLOW}  ${WARN} Обнаружен существующий /swapfile.${NC}"
    if confirm "Пересоздать swap-файл (новый размер: ${SWAP_SIZE})?"; then
        if swapon --show | grep -q '/swapfile'; then
            swapoff /swapfile > /dev/null 2>&1
            echo -e "${GREEN}  ${OK} Старый swap отключён${NC}"
        fi
        sed -i '\|/swapfile|d' /etc/fstab 2>/dev/null || true
        rm -f /swapfile
        echo -e "${GREEN}  ${OK} Старый /swapfile удалён${NC}"
        if create_swap_file "$SWAP_SIZE"; then
            echo -e "${GREEN}  ${OK} /swapfile пересоздан (${SWAP_SIZE})${NC}"
        else
            echo -e "${RED}  ${ERR} Ошибка создания swap!${NC}"; exit 1
        fi
    else
        echo -e "${DIM}  ${SKIP} Пересоздание swap пропущено${NC}"
    fi
else
    if confirm "Создать swap-файл (${SWAP_SIZE})?"; then
        if create_swap_file "$SWAP_SIZE"; then
            echo -e "${GREEN}  ${OK} /swapfile создан (${SWAP_SIZE})${NC}"
        else
            echo -e "${RED}  ${ERR} Ошибка создания swap!${NC}"; exit 1
        fi
    else
        echo -e "${DIM}  ${SKIP} Создание swap пропущено${NC}"
    fi
fi

section_end

# ── 4. РАСШИРЕННЫЙ BBR / SYSCTL ───────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ЯДРА: BBR / TCP"

[ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

cat > /etc/sysctl.d/99-custom.conf <<'EOF'
# --- SYSTEM & BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 1000000
net.ipv4.tcp_pacing_ss_ratio = 55
net.ipv4.tcp_pacing_ca_ratio = 120
net.ipv4.tcp_min_rtt_wlen = 200
net.ipv4.tcp_vegas_cong_avoid_limit = 20
net.ipv4.tcp_min_rtt_active = 1

# --- NETWORK QUEUES ---
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_window_scaling = 1

# --- MEMORY BUFFERS ---
net.core.rmem_default = 1048576
net.core.rmem_max = 33554432
net.core.wmem_default = 1048576
net.core.wmem_max = 33554432
net.core.optmem_max = 25165824
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- TIMEOUTS & KEEPALIVE ---
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# --- CONNECTION OPTIMIZATIONS ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_max_tw_buckets = 1440000

# --- NETWORK STACK / NEIGH ---
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.core.message_burst = 20
net.core.message_cost = 16384

# --- CONNTRACK ---
net.netfilter.nf_conntrack_max = 1000000

# --- MTU & DISCOVERY ---
net.ipv4.ip_no_pmtu_disc = 0

# --- PORTS & FILES ---
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152

# --- SWAP / VM ---
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2

# --- DISABLE IPv6 ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || sysctl --system > /dev/null 2>&1 || true
echo -e "${GREEN}  ${OK} Расширенный BBR / TCP / sysctl применены${NC}"

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo -e "${GREEN}  ${OK} BBR активен${NC}"
else
    echo -e "${YELLOW}  ${WARN} BBR не поддерживается текущим ядром${NC}"
fi

section_end

# ── 5. ОТКЛЮЧЕНИЕ IPv6 ────────────────────────────────────────────────────────
section_start "ОТКЛЮЧЕНИЕ IPv6"

if [ ! -f /etc/systemd/system/disable-ipv6.service ]; then
    if confirm "Отключить IPv6 через systemd?"; then
        cat > /etc/systemd/system/disable-ipv6.service <<'EOF'
[Unit]
Description=Disable IPv6
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sysctl -w net.ipv6.conf.all.disable_ipv6=1
ExecStart=/usr/bin/sysctl -w net.ipv6.conf.default.disable_ipv6=1
ExecStart=/usr/bin/sysctl -w net.ipv6.conf.lo.disable_ipv6=1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable --now disable-ipv6.service > /dev/null 2>&1 &
        spinner $! "Активация disable-ipv6.service"
        echo -e "${GREEN}  ${OK} IPv6 отключён через systemd${NC}"
    else
        echo -e "${DIM}  ${SKIP} Отключение IPv6 пропущено${NC}"
    fi
else
    echo -e "${DIM}  ${INFO} disable-ipv6.service уже существует${NC}"
fi

section_end

# ── 6. ДИСКИ ─────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ДИСКОВ"

if confirm "Запустить TRIM для SSD?"; then
    set +e
    TRIM_OUT=$(fstrim -v / 2>&1); TRIM_RC=$?
    set -e
    if [ $TRIM_RC -eq 0 ]; then
        TRIMMED=$(echo "$TRIM_OUT" | grep -oP '\d+(\.\d+)?\s+(GB|MB|KB|bytes)' | head -1)
        echo -e "${GREEN}  ${OK} TRIM выполнен${TRIMMED:+: ${TRIMMED} освобождено}${NC}"
    else
        echo -e "${YELLOW}  ${INFO} TRIM не поддерживается или диск не SSD${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} TRIM пропущен${NC}"
fi

if confirm "Применить дополнительные параметры vm.dirty_*?"; then
    cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# --- DISK I/O (дополнительно) ---
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
EOF
    sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    echo -e "${GREEN}  ${OK} vm.dirty_expire/writeback применены${NC}"
else
    echo -e "${DIM}  ${SKIP} Дополнительные dirty-параметры пропущены${NC}"
fi

section_end

# ── 7. ПАМЯТЬ ────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ПАМЯТИ"

if confirm "Применить дополнительные параметры памяти?"; then
    cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# --- MEMORY ---
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 65536
vm.overcommit_memory = 0
vm.panic_on_oom = 0
EOF
    sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Параметры памяти применены${NC}"
else
    echo -e "${DIM}  ${SKIP} Дополнительная оптимизация памяти пропущена${NC}"
fi

section_end

# ── 8. SYSTEMD / JOURNALD / LOGROTATE ────────────────────────────────────────
section_start "SYSTEMD / JOURNALD / LOGROTATE"

if confirm "Показать топ-10 медленных сервисов при загрузке?"; then
    echo -e "${BLUE}  ${INFO} Анализ времени загрузки systemd:${NC}"
    systemd-analyze blame 2>/dev/null | head -10 | \
        awk '{printf "    %-10s  %s\n", $1, $2}' || true
    echo ""
fi

if confirm "Ограничить journald: 500MB, 7 дней, сжатие?"; then
    JCONF=/etc/systemd/journald.conf
    [ ! -f "${JCONF}.bak" ] && cp "$JCONF" "${JCONF}.bak"
    set_journal_param SystemMaxUse       500M
    set_journal_param SystemKeepFree     100M
    set_journal_param SystemMaxFileSize  50M
    set_journal_param MaxRetentionSec    7day
    set_journal_param MaxFileSec         1day
    set_journal_param Compress           yes
    systemctl restart systemd-journald > /dev/null 2>&1
    echo -e "${GREEN}  ${OK} journald: 500MB / 7 дней / сжатие${NC}"
else
    echo -e "${DIM}  ${SKIP} Настройка journald пропущена${NC}"
fi

if confirm "Настроить ротацию системных и Docker-логов?"; then
    cat > /etc/logrotate.d/custom-optimization <<'EOF'
/var/log/syslog
/var/log/auth.log
/var/log/kern.log
{
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}

/var/lib/docker/containers/*/*.log {
    daily
    rotate 7
    compress
    maxsize 10M
    copytruncate
    missingok
    notifempty
}
EOF
    echo -e "${GREEN}  ${OK} logrotate настроен (системные + Docker)${NC}"
else
    echo -e "${DIM}  ${SKIP} Настройка logrotate пропущена${NC}"
fi

section_end

# ── 9. ЛИМИТЫ ────────────────────────────────────────────────────────────────
section_start "ЛИМИТЫ РЕСУРСОВ (nofile / nproc)"

if confirm "Увеличить лимиты файловых дескрипторов до 65536?"; then
    [ ! -f /etc/security/limits.conf.bak ] && cp /etc/security/limits.conf /etc/security/limits.conf.bak
    if ! grep -q "CUSTOM RESOURCE LIMITS" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<'EOF'

# CUSTOM RESOURCE LIMITS
*     soft  nofile  65536
*     hard  nofile  65536
root  soft  nofile  65536
root  hard  nofile  65536
*     soft  nproc   32768
*     hard  nproc   32768
EOF
    fi
    grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null || \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    ulimit -n 65536 2>/dev/null || true
    ulimit -u 32768 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Лимиты: nofile=65536, nproc=32768${NC}"
    echo -e "${YELLOW}  ${WARN} Постоянное применение — после перезагрузки${NC}"
else
    echo -e "${DIM}  ${SKIP} Настройка лимитов пропущена${NC}"
fi

section_end

# ── 10. ОЧИСТКА ───────────────────────────────────────────────────────────────
section_start "ОЧИСТКА СИСТЕМЫ"

DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

apt-get clean -qq > /dev/null 2>&1 &
spinner $! "Очистка кэша APT"

if confirm "Удалить старые версии ядра?"; then
    CURRENT_KERNEL=$(uname -r)
    set +e
    OLD_KERNELS=$(dpkg --list 2>/dev/null \
        | grep -E '^ii\s+linux-(image|headers)-[0-9]' \
        | awk '{print $2}' \
        | grep -v "$CURRENT_KERNEL" \
        | sort -V \
        | head -n -1)
    set -e
    if [ -n "$OLD_KERNELS" ]; then
        while IFS= read -r k; do
            DEBIAN_FRONTEND=noninteractive apt-get purge -yqq "$k" > /dev/null 2>&1 || true
            echo -e "${GREEN}  ${OK} Удалено ядро: $k${NC}"
        done <<< "$OLD_KERNELS"
        update-grub > /dev/null 2>&1 || true
    else
        echo -e "${DIM}  ${INFO} Старых ядер не обнаружено${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} Очистка ядер пропущена${NC}"
fi

journalctl --vacuum-time=7d --vacuum-size=100M > /dev/null 2>&1 &
spinner $! "Очистка journald (>7 дней или >100MB)"

systemd-tmpfiles --clean > /dev/null 2>&1 || {
    find /tmp     -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    find /var/tmp -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
}
echo -e "${GREEN}  ${OK} Временные файлы очищены${NC}"

TARGET_HOME="${SUDO_USER:+$(eval echo ~"$SUDO_USER")}"
TARGET_HOME="${TARGET_HOME:-$HOME}"
if [ -d "${TARGET_HOME}/.cache/thumbnails" ]; then
    rm -rf "${TARGET_HOME}/.cache/thumbnails"/* 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Кэш миниатюр очищен${NC}"
fi

if confirm "Очистить корзину для всех пользователей?"; then
    _TOTAL_TRASH=0

    # ИСПРАВЛЕНО: _clean_trash определена вне if-блока и возвращает явный 0
    if [ -n "${SUDO_USER:-}" ]; then
        _clean_trash "$(eval echo ~"$SUDO_USER")/.local/share/Trash" "$SUDO_USER"
    fi
    _clean_trash "/root/.local/share/Trash" "root"

    for uhome in /home/*; do
        [ -d "$uhome" ] || continue
        un=$(basename "$uhome")
        if [ "$un" = "${SUDO_USER:-}" ]; then continue; fi
        _clean_trash "$uhome/.local/share/Trash" "$un"
    done

    if [ "${_TOTAL_TRASH:-0}" -gt 0 ]; then
        HR=$(awk "BEGIN{s=$_TOTAL_TRASH;
            if(s>1073741824) printf \"%.2f GB\",s/1073741824;
            else if(s>1048576) printf \"%.2f MB\",s/1048576;
            else if(s>1024)    printf \"%.2f KB\",s/1024;
            else               printf \"%d B\",s;}")
        echo -e "${GREEN}  ${CLEAN} Итого освобождено: ${BOLD}${HR}${NC}"
    else
        echo -e "${DIM}  ${INFO} Корзины уже пустые${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} Очистка корзин пропущена${NC}"
fi

section_end

# ── Итоговый отчёт ────────────────────────────────────────────────────────────
generate_report
echo -e "${GREEN}${BOLD}  ✔  ВСЁ ГОТОВО!${NC}"
echo ""

# ── Перезагрузка с обратным отсчётом ─────────────────────────────────────────
if confirm "Перезагрузить систему сейчас?"; then
    for i in 5 4 3 2 1; do
        printf "\r${YELLOW}  >> Перезагрузка через ${RED}${BOLD}${i}${NC}${YELLOW} сек...  ${DIM}(Ctrl+C для отмены)${NC}"
        sleep 1
    done
    printf "\r${GREEN}  >> Перезагружаем систему...                              ${NC}\n"
    reboot
else
    echo -e "${YELLOW}  ${WARN} Перезагрузка отложена.${NC}"
    echo -e "${CYAN}  Команда для перезагрузки: ${BOLD}sudo reboot${NC}"
fi
