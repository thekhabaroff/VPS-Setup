#!/bin/bash

# ============================================================================
#  UBUNTU SERVER OPTIMIZATION SCRIPT  v3.0
#  Fixes: цвета, dd-своп, APT-кеш, tcp_fack/low_latency, overcommit,
#         Docker GPG, install_util, journald sed, spinner TTY, очистка tmp
# ============================================================================

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "Ошибка: требуются права root. Запустите: sudo $0"
    exit 1
fi

set -eo pipefail

# ── Цвета (ANSI C quoting — единственный корректный способ в bash) ──────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ── Иконки ───────────────────────────────────────────────────────────────────
OK="[OK]"
WARN="[!!]"
ERR="[XX]"
INFO="[ii]"
SKIP="[>>]"
CLEAN="[**]"
PLUS="[++]"
LOCK="[##]"

# ── Статистика ────────────────────────────────────────────────────────────────
INSTALLED_UTILS=0
DISABLED_SERVICES=0
FREED_SPACE_BEFORE=0
SCRIPT_START_TIME=$(date +%s)
CURRENT_SECTION=0
SECTION_START_TIME=0
TOTAL_SECTIONS=14        # полный режим; перезаписывается для minimal
AUTO_MODE=false
MINIMAL_MODE=false

# Проверяем интерактивный терминал (для spinner и tput)
IS_TTY=false
[ -t 1 ] && IS_TTY=true

# ── Spinner ───────────────────────────────────────────────────────────────────
spinner() {
    local pid=$1 msg=$2
    local chars='|/-\' i=0 elapsed=0
    local t0; t0=$(date +%s)

    if [ "$IS_TTY" = true ]; then
        tput civis 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            elapsed=$(( $(date +%s) - t0 ))
            printf "\r${YELLOW}  ${chars:$(( i % 4 )):1} ${msg} ${CYAN}[${elapsed}s]${NC}"
            i=$(( i + 1 ))
            sleep 0.15
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

# ── Подтверждение ─────────────────────────────────────────────────────────────
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

# ── Прогресс-бар ──────────────────────────────────────────────────────────────
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

# ── Начало / конец секции ─────────────────────────────────────────────────────
section_start() {
    CURRENT_SECTION=$(( CURRENT_SECTION + 1 ))
    SECTION_START_TIME=$(date +%s)
    echo ""
    printf "${BLUE}  ══════════════════════════════════════════════════════════${NC}\n"
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
    printf "${BLUE}  ══════════════════════════════════════════════════════════${NC}\n"
}

# ── Оптимальный размер SWAP ───────────────────────────────────────────────────
calculate_swap_size() {
    local ram_gb; ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    [ -z "$ram_gb" ] || [ "$ram_gb" -eq 0 ] && { echo "4G"; return; }

    if   [ "$ram_gb" -lt 2  ]; then
        local s=$(( ram_gb * 2 )); [ "$s" -lt 2 ] && s=2; echo "${s}G"
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

# ── Создание SWAP-файла ───────────────────────────────────────────────────────
create_swap_file() {
    local swap_size=$1
    local swap_gb; swap_gb=$(echo "$swap_size" | sed 's/G$//')

    # Проверка свободного места (+512MB запас)
    local avail_kb; avail_kb=$(df / | awk 'NR==2{print $4}')
    local need_kb=$(( swap_gb * 1024 * 1024 + 524288 ))
    if [ "$avail_kb" -lt "$need_kb" ]; then
        echo -e "${RED}  ${ERR} Недостаточно места! Нужно ~${swap_gb}GB + 512MB," \
                "доступно: $(df -h / | awk 'NR==2{print $4}')${NC}"
        return 1
    fi

    # fallocate (быстрый способ)
    set +e
    fallocate -l "$swap_size" /swapfile > /dev/null 2>&1 &
    local fpid=$!
    spinner $fpid "Создание /swapfile ${swap_size} (fallocate)"
    wait $fpid; local frc=$?
    set -e

    if [ $frc -ne 0 ]; then
        echo -e "${YELLOW}  ${WARN} fallocate не поддерживается — используем dd...${NC}"
        # ИСПРАВЛЕНО: count = GB × 1024 (мегабайты), а не просто число GB
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

# ── install_util: таблица пакет → команда ─────────────────────────────────────
# ИСПРАВЛЕНО: проверяем фактическую команду, а не имя пакета
declare -A PKG_CMD=(
    [net-tools]="ifconfig"
    [speedtest-cli]="speedtest"
    [mtr-tiny]="mtr"
    [traceroute]="traceroute"
)

install_util() {
    local pkg=$1 desc=$2
    local cmd="${PKG_CMD[$pkg]:-$pkg}"
    if ! command -v "$cmd" &>/dev/null; then
        if confirm "Установить ${BOLD}${pkg}${NC} — ${desc}?"; then
            set +e
            DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$pkg" > /dev/null 2>&1 &
            local pid=$!
            spinner $pid "Установка ${pkg}"
            wait $pid; local rc=$?
            set -e
            if [ $rc -eq 0 ]; then
                echo -e "${GREEN}  ${OK} ${pkg} установлен${NC}"
                INSTALLED_UTILS=$(( INSTALLED_UTILS + 1 ))
            else
                echo -e "${RED}  ${ERR} Ошибка установки ${pkg} (код: ${rc})${NC}"
                confirm "Продолжить несмотря на ошибку?" || exit 1
            fi
        else
            echo -e "${DIM}  ${SKIP} ${pkg} пропущен${NC}"
        fi
    else
        echo -e "${DIM}  ${INFO} ${pkg} уже установлен${NC}"
    fi
}

# ── Функция для идемпотентной правки journald.conf ────────────────────────────
set_journal_param() {
    local key=$1 val=$2 file=/etc/systemd/journald.conf
    # ИСПРАВЛЕНО: один проход вместо двух (раньше было два дублирующих sed)
    if grep -qE "^#?${key}=" "$file"; then
        sed -i "s|^#\?${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# ── Меню ──────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo ""
    echo -e "${BLUE}  ╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${NC}  ${CYAN}${BOLD}  UBUNTU SERVER OPTIMIZATION  v3.0               ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ║${NC}  ${DIM}  Комплексная оптимизация Ubuntu Server           ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Выберите режим:${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}1)${NC}  Автоматический   ${DIM}— всё по умолчанию, без вопросов (~5-10 мин)${NC}"
    echo -e "  ${BOLD}${YELLOW}2)${NC}  Интерактивный    ${DIM}— подтверждение каждого шага (~10-15 мин)${NC}"
    echo -e "  ${BOLD}${BLUE}3)${NC}  Минимальный      ${DIM}— только обновления и BBR (~3-5 мин)${NC}"
    echo ""
    printf "  ${MAGENTA}Ваш выбор ${CYAN}[1-3]: ${NC}"
    read -r MODE
    case $MODE in
        1) AUTO_MODE=true ;;
        2) AUTO_MODE=false ;;
        3) MINIMAL_MODE=true; AUTO_MODE=true; TOTAL_SECTIONS=3 ;;
        *) echo -e "${RED}  ${ERR} Неверный выбор.${NC}"; exit 1 ;;
    esac
    echo ""
}

# ── Сводка ────────────────────────────────────────────────────────────────────
show_summary() {
    local rec_swap; rec_swap=$(calculate_swap_size)
    echo ""
    echo -e "${BLUE}  ╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${NC}  ${CYAN}${BOLD}           ЧТО БУДЕТ ВЫПОЛНЕНО                  ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [ "$MINIMAL_MODE" = false ]; then
        echo -e "  ${OK}    Обновление системы и пакетов"
        echo -e "  ${OK}    Установка Docker (GPG-верификация) + утилиты"
        echo -e "  ${PLUS}    SWAP: ${BOLD}${rec_swap}${NC}, swappiness=10"
        echo -e "  ${PLUS}    Ядро: BBR, TCP, ECN, sysctl"
        echo -e "  ${LOCK}    Отключение IPv6"
        echo -e "  ${PLUS}    Диски: TRIM + vm.dirty_*"
        echo -e "  ${PLUS}    Память: vfs_cache_pressure, min_free_kbytes"
        echo -e "  ${PLUS}    Systemd: сервисы, journald (500MB/7d)"
        echo -e "  ${OK}    Logrotate: сжатие, 7 дней, Docker"
        echo -e "  ${PLUS}    Лимиты: nofile=65536, nproc=32768"
        echo -e "  ${PLUS}    TCP расширенный: fin_timeout, conntrack"
        echo -e "  ${CLEAN}    Очистка: пакеты, кеш, ядра, логи, корзина"
    else
        echo -e "  ${OK}    Обновление системы"
        echo -e "  ${PLUS}    BBR + базовые sysctl"
        echo -e "  ${CLEAN}    Очистка системы"
    fi
    echo ""
    echo -e "  ${YELLOW}${WARN}${NC}  После завершения рекомендуется ${BOLD}sudo reboot${NC}"
    echo ""
    confirm "Начать выполнение?" || { echo -e "${RED}  Отменено.${NC}"; exit 0; }
    FREED_SPACE_BEFORE=$(df / | awk 'NR==2{print $3}')
}

# ── Итоговый отчёт ────────────────────────────────────────────────────────────
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
    echo -e "${BLUE}  ╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║${NC}  ${CYAN}${BOLD}            ОТЧЁТ О ВЫПОЛНЕНИИ                  ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}  ╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${INFO}  Установлено утилит:     ${BOLD}${INSTALLED_UTILS}${NC}"
    echo -e "  ${INFO}  SWAP:                   ${BOLD}${swap_info}${NC} (swappiness=10)"
    echo -e "  ${INFO}  BBR + TCP:              ${BOLD}применены${NC}"
    echo -e "  ${INFO}  Отключено сервисов:     ${BOLD}${DISABLED_SERVICES}${NC}"
    if [ "$freed" -gt 0 ]; then
        local fhr; fhr=$(numfmt --to=iec-i --suffix=B $(( freed * 1024 )) 2>/dev/null || echo "${freed}KB")
        echo -e "  ${INFO}  Освобождено места:      ${BOLD}${fhr}${NC}"
    else
        echo -e "  ${INFO}  Место на диске:         ${BOLD}оптимизировано${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}${BOLD}⏱  Время выполнения:${NC} ${t}s ${DIM}($(( t / 60 ))m $(( t % 60 ))s)${NC}"
    echo ""
    echo -e "${BLUE}  Использование диска:${NC}"
    df -h / | awk 'NR==2{printf "    %s из %s (%s)\n", $3, $2, $5}'
    echo ""
    section_separator
}

# ============================================================================
#  ЗАПУСК
# ============================================================================
clear
show_menu
show_summary

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 1 — ОБНОВЛЕНИЕ СИСТЕМЫ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОБНОВЛЕНИЕ СИСТЕМЫ"

# ИСПРАВЛЕНО: убрано "No-Cache true" — оно отключало кеш и замедляло APT
if [ ! -f /etc/apt/apt.conf.d/99-optimizations ]; then
    cat > /etc/apt/apt.conf.d/99-optimizations <<'EOF'
# Параллельные соединения (ускоряет загрузку пакетов)
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

if [ "$MINIMAL_MODE" = false ]; then

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 2 — DOCKER
# ─────────────────────────────────────────────────────────────────────────────
section_start "УСТАНОВКА / ОБНОВЛЕНИЕ DOCKER"

if ! command -v docker &>/dev/null; then
    if confirm "Установить Docker (официальный репозиторий с GPG-ключом)?"; then
        # ИСПРАВЛЕНО: установка через verified apt-репозиторий, не через sh get-docker.sh
        DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
            ca-certificates curl gnupg lsb-release > /dev/null 2>&1

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.asc

        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -qq > /dev/null 2>&1

        DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1 &
        spinner $! "Установка Docker CE + Compose Plugin"

        [ -n "${SUDO_USER:-}" ] && usermod -aG docker "$SUDO_USER" > /dev/null 2>&1 \
            && echo -e "${GREEN}  ${OK} Пользователь ${SUDO_USER} добавлен в группу docker${NC}"

        echo -e "${GREEN}  ${OK} Docker успешно установлен${NC}"
    else
        echo -e "${DIM}  ${SKIP} Установка Docker пропущена${NC}"
    fi
else
    echo -e "${DIM}  ${INFO} Docker уже установлен${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-compose-plugin > /dev/null 2>&1 &
    spinner $! "Обновление Docker Compose Plugin"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 3 — УТИЛИТЫ
# ─────────────────────────────────────────────────────────────────────────────
section_start "УСТАНОВКА УТИЛИТ"

install_util "curl"          "загрузка файлов из интернета"
install_util "wget"          "альтернатива curl"
install_util "git"           "система контроля версий"
install_util "unzip"         "распаковка ZIP-архивов"
install_util "zip"           "создание ZIP-архивов"
install_util "htop"          "интерактивный монитор процессов"
install_util "speedtest-cli" "тест скорости интернета"
install_util "net-tools"     "сетевые утилиты: ifconfig, netstat"
install_util "mtr-tiny"      "диагностика сети (ping + traceroute)"
install_util "traceroute"    "трассировка маршрута"
install_util "nmap"          "сканер сети и портов"
install_util "fail2ban"      "защита от брутфорса"
install_util "ufw"           "упрощённый firewall"

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 4 — SWAP
# ─────────────────────────────────────────────────────────────────────────────
section_start "НАСТРОЙКА SWAP"

SWAP_SIZE=$(calculate_swap_size)
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')

echo -e "${BLUE}  ${INFO} RAM: ${BOLD}${RAM_GB}GB${NC}  →  рекомендуемый SWAP: ${BOLD}${SWAP_SIZE}${NC}"

if [ -f /swapfile ]; then
    echo -e "${YELLOW}  ${WARN} Обнаружен существующий /swapfile.${NC}"
    if confirm "Пересоздать swap-файл (новый размер: ${SWAP_SIZE})?"; then
        swapon --show | grep -q '/swapfile' && swapoff /swapfile > /dev/null 2>&1 \
            && echo -e "${GREEN}  ${OK} Старый swap отключён${NC}"
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
fi # MINIMAL_MODE

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 5 (или 2 в minimal) — ОПТИМИЗАЦИЯ ЯДРА
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ЯДРА (BBR + SYSCTL)"

[ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

# ИСПРАВЛЕНО:
#   - убраны tcp_low_latency (удалён в ядре 4.14)
#   - убраны tcp_fack (legacy, нет эффекта с ядра 5.5+)
#   - убраны busy_read/busy_poll (вредят CPU без специального HW)
#   - tcp_ecn=1 (включён: снижает потери пакетов)
#   - tcp_max_tw_buckets=131072 (разумное значение вместо 1440000)
cat > /etc/sysctl.d/99-custom.conf <<'EOF'
# ── BBR Congestion Control ───────────────────────────────────────────────────
net.core.default_qdisc             = fq
net.ipv4.tcp_congestion_control    = bbr

# ── Network Queues ───────────────────────────────────────────────────────────
net.core.netdev_max_backlog        = 2000
net.core.somaxconn                 = 4096
net.ipv4.tcp_max_syn_backlog       = 4096

# ── Socket Buffers ───────────────────────────────────────────────────────────
net.core.rmem_default              = 262144
net.core.rmem_max                  = 8388608
net.core.wmem_default              = 262144
net.core.wmem_max                  = 8388608
net.core.optmem_max                = 65536
net.ipv4.tcp_rmem                  = 4096 131072 8388608
net.ipv4.tcp_wmem                  = 4096 131072 8388608

# ── TCP Keepalive ────────────────────────────────────────────────────────────
net.ipv4.tcp_keepalive_time        = 300
net.ipv4.tcp_keepalive_intvl       = 15
net.ipv4.tcp_keepalive_probes      = 3

# ── TCP Connections ──────────────────────────────────────────────────────────
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.ip_no_pmtu_disc           = 0

# ── ECN: уменьшает потери пакетов в датацентрах ──────────────────────────────
net.ipv4.tcp_ecn                   = 1

# ── Ports & Files ────────────────────────────────────────────────────────────
net.ipv4.ip_local_port_range       = 1024 65535
fs.file-max                        = 1000000
EOF

sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || sysctl --system > /dev/null 2>&1
echo -e "${GREEN}  ${OK} BBR и базовые sysctl применены${NC}"

# Проверка BBR
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo -e "${GREEN}  ${OK} BBR активен${NC}"
else
    echo -e "${YELLOW}  ${WARN} BBR не поддерживается текущим ядром (требуется 4.9+)${NC}"
fi

section_end

if [ "$MINIMAL_MODE" = false ]; then

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 6 — ОТКЛЮЧЕНИЕ IPv6
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОТКЛЮЧЕНИЕ IPv6"

if [ ! -f /etc/systemd/system/disable-ipv6.service ]; then
    if confirm "Отключить IPv6 через systemd?"; then
        # ИСПРАВЛЕНО: используем /usr/bin/sysctl (корректный путь) и два ExecStart
        cat > /etc/systemd/system/disable-ipv6.service <<'EOF'
[Unit]
Description=Disable IPv6
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sysctl -w net.ipv6.conf.all.disable_ipv6=1
ExecStart=/usr/bin/sysctl -w net.ipv6.conf.default.disable_ipv6=1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable --now disable-ipv6.service > /dev/null 2>&1 &
        spinner $! "Активация disable-ipv6.service"
        echo -e "${GREEN}  ${OK} IPv6 отключён${NC}"
    else
        echo -e "${DIM}  ${SKIP} Отключение IPv6 пропущено${NC}"
    fi
else
    echo -e "${DIM}  ${INFO} disable-ipv6.service уже существует${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 7 — ОПТИМИЗАЦИЯ ДИСКОВ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ДИСКОВ"

if confirm "Запустить TRIM для SSD?"; then
    set +e
    TRIM_OUT=$(fstrim -v / 2>&1); TRIM_RC=$?
    set -e
    if [ $TRIM_RC -eq 0 ]; then
        TRIMMED=$(echo "$TRIM_OUT" | grep -oP '\d+(\.\d+)?\s+(GB|MB|KB|bytes)' | head -1)
        echo -e "${GREEN}  ${OK} TRIM выполнен${TRIMMED:+: ${TRIMMED} освобождено}${NC}"
    else
        echo -e "${YELLOW}  ${INFO} TRIM не поддерживается (не SSD или нет прав)${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} TRIM пропущен${NC}"
fi

if confirm "Оптимизировать параметры записи (vm.dirty_*)?"; then
    cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# ── Disk I/O ─────────────────────────────────────────────────────────────────
vm.dirty_ratio                     = 10
vm.dirty_background_ratio          = 5
vm.dirty_expire_centisecs          = 3000
vm.dirty_writeback_centisecs       = 500
EOF
    sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    echo -e "${GREEN}  ${OK} vm.dirty_* применены${NC}"
else
    echo -e "${DIM}  ${SKIP} Оптимизация дисков пропущена${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 8 — ОПТИМИЗАЦИЯ ПАМЯТИ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ ПАМЯТИ"

if confirm "Применить оптимизацию параметров памяти?"; then
    # ИСПРАВЛЕНО:
    #   - overcommit_memory=0 (безопаснее чем 1; ядро проверяет доступность)
    #   - убран overcommit_ratio (работает только при overcommit_memory=2)
    cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# ── Memory ───────────────────────────────────────────────────────────────────
vm.vfs_cache_pressure              = 50
vm.min_free_kbytes                 = 65536
vm.overcommit_memory               = 0
vm.panic_on_oom                    = 0
EOF
    sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Параметры памяти применены${NC}"
else
    echo -e "${DIM}  ${SKIP} Оптимизация памяти пропущена${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 9 — SYSTEMD СЕРВИСЫ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ SYSTEMD — СЕРВИСЫ"

if confirm "Показать топ-10 медленных сервисов при загрузке?"; then
    echo -e "${BLUE}  ${INFO} Анализ времени загрузки systemd:${NC}"
    systemd-analyze blame 2>/dev/null | head -10 | awk '{printf "    %-10s %s\n", $1, $2}' || true
    echo ""
fi

if confirm "Отключить ненужные системные сервисы?"; then
    for svc in bluetooth.service cups.service cups-browsed.service \
               ModemManager.service avahi-daemon.service; do
        if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
            systemctl disable --now "$svc" > /dev/null 2>&1
            echo -e "${GREEN}  ${OK} ${svc} отключён${NC}"
            DISABLED_SERVICES=$(( DISABLED_SERVICES + 1 ))
        else
            echo -e "${DIM}  ${INFO} ${svc} не активен${NC}"
        fi
    done
else
    echo -e "${DIM}  ${SKIP} Отключение сервисов пропущено${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 10 — JOURNALD
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОПТИМИЗАЦИЯ JOURNALD"

if confirm "Ограничить journal: 500MB, 7 дней, сжатие?"; then
    JCONF=/etc/systemd/journald.conf
    [ ! -f "${JCONF}.bak" ] && cp "$JCONF" "${JCONF}.bak"

    # ИСПРАВЛЕНО: единая функция set_journal_param — один проход на параметр,
    # не два дублирующих sed как было раньше
    set_journal_param SystemMaxUse      500M
    set_journal_param SystemKeepFree   100M
    set_journal_param SystemMaxFileSize 50M
    set_journal_param MaxRetentionSec  7day
    set_journal_param MaxFileSec       1day
    set_journal_param Compress         yes

    systemctl restart systemd-journald > /dev/null 2>&1
    echo -e "${GREEN}  ${OK} journald: 500MB / 7 дней / сжатие${NC}"
else
    echo -e "${DIM}  ${SKIP} Настройка journald пропущена${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 11 — LOGROTATE
# ─────────────────────────────────────────────────────────────────────────────
section_start "НАСТРОЙКА LOGROTATE"

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
    echo -e "${GREEN}  ${OK} logrotate: 7 дней, сжатие, Docker${NC}"
else
    echo -e "${DIM}  ${SKIP} Настройка logrotate пропущена${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 12 — ЛИМИТЫ РЕСУРСОВ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ЛИМИТЫ РЕСУРСОВ (nofile, nproc)"

if confirm "Увеличить лимиты файловых дескрипторов до 65536?"; then
    [ ! -f /etc/security/limits.conf.bak ] && cp /etc/security/limits.conf /etc/security/limits.conf.bak

    # Идемпотентное добавление — не дублируем при повторном запуске
    if ! grep -q "# CUSTOM RESOURCE LIMITS" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<'EOF'

# ── CUSTOM RESOURCE LIMITS ───────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 13 — РАСШИРЕННАЯ ОПТИМИЗАЦИЯ TCP
# ─────────────────────────────────────────────────────────────────────────────
section_start "РАСШИРЕННАЯ ОПТИМИЗАЦИЯ TCP"

if confirm "Применить расширенные TCP-настройки и connection tracking?"; then
    # ИСПРАВЛЕНО: tcp_max_tw_buckets=131072 (было 1440000 — избыточно, ест RAM)
    cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# ── Advanced TCP ─────────────────────────────────────────────────────────────
net.ipv4.tcp_fin_timeout           = 15
net.ipv4.tcp_max_tw_buckets        = 131072
net.ipv4.tcp_synack_retries        = 2
net.ipv4.tcp_syn_retries           = 2
net.ipv4.tcp_timestamps            = 1
net.ipv4.tcp_window_scaling        = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_max_orphans           = 262144
net.ipv4.tcp_orphan_retries        = 1
EOF

    if modprobe nf_conntrack > /dev/null 2>&1; then
        echo -e "${GREEN}  ${OK} Модуль nf_conntrack загружен${NC}"
        cat >> /etc/sysctl.d/99-custom.conf <<'EOF'

# ── Connection Tracking ──────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max                     = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
EOF
    fi

    sysctl -q -p /etc/sysctl.d/99-custom.conf 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Расширенная TCP-оптимизация применена${NC}"
else
    echo -e "${DIM}  ${SKIP} Расширенная TCP-оптимизация пропущена${NC}"
fi

section_end
fi # MINIMAL_MODE

# ─────────────────────────────────────────────────────────────────────────────
# СЕКЦИЯ 14 (или 3 в minimal) — ОЧИСТКА СИСТЕМЫ
# ─────────────────────────────────────────────────────────────────────────────
section_start "ОЧИСТКА СИСТЕМЫ"

DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

apt-get clean -qq > /dev/null 2>&1 &
spinner $! "Очистка кэша APT"

# Старые ядра
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
            DEBIAN_FRONTEND=noninteractive apt-get purge -yqq "$k" > /dev/null 2>&1
            echo -e "${GREEN}  ${OK} Удалено ядро: $k${NC}"
        done <<< "$OLD_KERNELS"
        update-grub > /dev/null 2>&1 || true
    else
        echo -e "${DIM}  ${INFO} Старых ядер не обнаружено${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} Очистка ядер пропущена${NC}"
fi

# Журналы
journalctl --vacuum-time=7d --vacuum-size=100M > /dev/null 2>&1 &
spinner $! "Очистка journald (>7 дней или >100MB)"

# ИСПРАВЛЕНО: используем systemd-tmpfiles --clean (безопасно)
# вместо rm -rf /tmp/* (мог убить сокеты работающих процессов)
systemd-tmpfiles --clean > /dev/null 2>&1 || {
    find /tmp     -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    find /var/tmp -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
}
echo -e "${GREEN}  ${OK} Временные файлы очищены (безопасный метод)${NC}"

# Кэш миниатюр
TARGET_HOME="${SUDO_USER:+$(eval echo ~"$SUDO_USER")}"
TARGET_HOME="${TARGET_HOME:-$HOME}"
if [ -d "${TARGET_HOME}/.cache/thumbnails" ]; then
    rm -rf "${TARGET_HOME}/.cache/thumbnails"/* 2>/dev/null || true
    echo -e "${GREEN}  ${OK} Кэш миниатюр очищен${NC}"
fi

# Корзина
if confirm "Очистить корзину для всех пользователей?"; then
    TOTAL_TRASH=0

    _clean_trash() {
        local path=$1 uname=$2
        [ -d "$path" ] || return
        local sz; sz=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        [ "${sz:-0}" -le 4096 ] && return
        local hr; hr=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        TOTAL_TRASH=$(( TOTAL_TRASH + sz ))
        rm -rf "${path}/files" "${path}/info" 2>/dev/null || true
        mkdir -p "${path}/files" "${path}/info"  2>/dev/null || true
        echo -e "${GREEN}  ${CLEAN} ${uname}: ${hr}${NC}"
    }

    [ -n "${SUDO_USER:-}" ] && \
        _clean_trash "$(eval echo ~"$SUDO_USER")/.local/share/Trash" "$SUDO_USER"
    _clean_trash "/root/.local/share/Trash" "root"

    for uhome in /home/*; do
        un=$(basename "$uhome")
        [ "$un" = "${SUDO_USER:-}" ] && continue
        _clean_trash "$uhome/.local/share/Trash" "$un"
    done

    if [ "$TOTAL_TRASH" -gt 0 ]; then
        HR=$(awk "BEGIN{s=$TOTAL_TRASH;
            if(s>1073741824) printf \"%.2f GB\",s/1073741824;
            else if(s>1048576) printf \"%.2f MB\",s/1048576;
            else if(s>1024)    printf \"%.2f KB\",s/1024;
            else               printf \"%d B\",s;}")
        echo -e "${GREEN}  ${CLEAN} Итого освобождено: ${BOLD}${HR}${NC}"
    else
        echo -e "${DIM}  ${INFO} Корзины уже пустые${NC}"
    fi
else
    echo -e "${DIM}  ${SKIP} Очистка корзины пропущена${NC}"
fi

section_end

# ─────────────────────────────────────────────────────────────────────────────
# ИТОГОВЫЙ ОТЧЁТ
# ─────────────────────────────────────────────────────────────────────────────
generate_report
echo -e "${GREEN}${BOLD}  ✔  ВСЁ ГОТОВО!${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# ПЕРЕЗАГРУЗКА
# ─────────────────────────────────────────────────────────────────────────────
if confirm "Перезагрузить систему сейчас?"; then
    for i in 5 4 3 2 1; do
        printf "\r${YELLOW}  >> Перезагрузка через ${RED}${BOLD}${i}${NC}${YELLOW} сек...  ${DIM}(Ctrl+C для отмены)${NC}"
        sleep 1
    done
    printf "\r${GREEN}  >> Перезагружаем систему...                             ${NC}\n"
    reboot
else
    echo -e "${YELLOW}  ${WARN} Перезагрузка отложена.${NC}"
    echo -e "${CYAN}  Команда: ${BOLD}sudo reboot${NC}"
fi
