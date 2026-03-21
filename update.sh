#!/bin/bash

# ============================================================================
#  UBUNTU SERVER OPTIMIZATION SCRIPT v3.0
#  Комплексная оптимизация и настройка сервера
# ============================================================================

# Проверка прав доступа (требуется root или sudo)
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "Ошибка: Этот скрипт требует прав root или sudo."
    echo "Запустите скрипт с sudo: sudo $0"
    exit 1
fi

# Проверка ОС (только Ubuntu/Debian)
if [ ! -f /etc/debian_version ]; then
    echo "Ошибка: Этот скрипт предназначен только для Ubuntu/Debian."
    exit 1
fi

# Останавливаем выполнение скрипта при ошибке команд
set -eo pipefail

# --- Настройки цветов и стилей ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Переменные для статистики ---
INSTALLED_UTILS=0
DISABLED_SERVICES=0
FREED_SPACE_BEFORE=0
SCRIPT_START_TIME=$(date +%s)
TOTAL_SECTIONS=11
CURRENT_SECTION=0
SECTION_START_TIME=0
AUTO_MODE=false

# ============================================================================
# ФУНКЦИИ ИНТЕРФЕЙСА
# ============================================================================

# --- Универсальное arrow-key меню ---
# Использование: select_option "Заголовок" option1 option2 ...
# Возвращает индекс выбранного пункта (0-based) в переменной SELECTED
select_option() {
    local title="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local current=0

    # Сохраняем настройки терминала
    local saved_tty
    saved_tty=$(stty -g 2>/dev/null)

    # Скрываем курсор
    printf '\033[?25l'

    # Функция отрисовки меню
    _draw_menu() {
        # Переходим вверх на count+1 строк и очищаем
        local i
        for ((i = 0; i < count + 1; i++)); do
            printf '\033[A'
        done
        printf '\r'

        # Заголовок
        printf '\033[2K'
        echo -e "${CYAN}${title}${NC}"

        # Опции
        for ((i = 0; i < count; i++)); do
            printf '\033[2K'
            if [ $i -eq $current ]; then
                echo -e "  ${WHITE}${BOLD}\u25b8 ${options[$i]}${NC}"
            else
                echo -e "  ${DIM}  ${options[$i]}${NC}"
            fi
        done
    }

    # Первая отрисовка (резервируем место)
    echo -e "${CYAN}${title}${NC}"
    local i
    for ((i = 0; i < count; i++)); do
        if [ $i -eq $current ]; then
            echo -e "  ${WHITE}${BOLD}\u25b8 ${options[$i]}${NC}"
        else
            echo -e "  ${DIM}  ${options[$i]}${NC}"
        fi
    done

    while true; do
        # Читаем один символ через stty raw + dd
        local char
        stty raw -echo 2>/dev/null
        char=$(dd bs=1 count=1 2>/dev/null)
        stty "$saved_tty" 2>/dev/null

        if [[ "$char" == $'\x1b' ]]; then
            # Читаем ещё 2 символа escape-последовательности
            local seq
            stty raw -echo 2>/dev/null
            seq=$(dd bs=1 count=2 2>/dev/null)
            stty "$saved_tty" 2>/dev/null

            case "$seq" in
                '[A') ((current > 0)) && current=$((current - 1)); _draw_menu ;;
                '[B') ((current < count - 1)) && current=$((current + 1)); _draw_menu ;;
            esac
        elif [[ "$char" == "" || "$char" == $'\n' || "$char" == $'\r' ]]; then
            break
        fi
    done

    # Показываем курсор
    printf '\033[?25h'
    SELECTED=$current
}

# --- Подтверждение Да/Нет стрелочками ---
# Возвращает 0 (Да) или 1 (Нет)
confirm_arrow() {
    if [ "$AUTO_MODE" = true ]; then
        return 0
    fi

    local prompt="$1"
    select_option "$prompt" "Да" "Нет"
    return "$SELECTED"
}

# --- Функция спиннера ---
spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_len=${#spin}
    local i=0
    local start_time
    start_time=$(date +%s)

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        i=$(( (i+1) % spin_len ))
        printf "\r${YELLOW}  %s %s ${CYAN}[%ss]${NC}" "$message" "${spin:$i:1}" "$elapsed"
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    local total_time=$(($(date +%s) - start_time))
    printf "\r${GREEN}  %s ✓ ${DIM}(%ss)${NC}\n" "$message" "$total_time"
}

# --- Функция прогресс-бара ---
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))

    echo -ne "${BLUE}["
    printf "%${filled}s" | tr ' ' '='
    printf "%$((width - filled))s" | tr ' ' '-'
    echo -e "] ${BOLD}${percentage}%%${NC} ${DIM}(${current}/${total})${NC}"
}

# --- Функция начала секции ---
section_start() {
    CURRENT_SECTION=$((CURRENT_SECTION + 1))
    SECTION_START_TIME=$(date +%s)

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    show_progress $CURRENT_SECTION $TOTAL_SECTIONS
    echo -e "${GREEN}${BOLD}>>> $1 <<<${NC}"
    echo ""
}

# --- Функция завершения секции ---
section_end() {
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - SECTION_START_TIME))
    echo -e "${DIM}  ── Выполнено за ${duration}s${NC}"
}

# --- Функция разделителя ---
section_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

# --- Определение размера SWAP ---
calculate_swap_size() {
    local ram_gb
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')

    if [ -z "$ram_gb" ] || [ "$ram_gb" -eq 0 ]; then
        echo "4G"
        return
    fi

    if [ "$ram_gb" -lt 2 ]; then
        local swap_gb=$((ram_gb * 2))
        [ "$swap_gb" -lt 2 ] && swap_gb=2
        echo "${swap_gb}G"
    elif [ "$ram_gb" -lt 4 ]; then
        local swap_gb=$ram_gb
        [ "$swap_gb" -lt 4 ] && swap_gb=4
        echo "${swap_gb}G"
    elif [ "$ram_gb" -lt 8 ]; then
        local swap_gb=$((ram_gb / 2))
        [ "$swap_gb" -lt 4 ] && swap_gb=4
        [ "$swap_gb" -gt 8 ] && swap_gb=8
        echo "${swap_gb}G"
    elif [ "$ram_gb" -lt 16 ]; then
        echo "8G"
    else
        echo "16G"
    fi
}

# --- Создание SWAP файла ---
create_swap_file() {
    local swap_size=$1

    local available_space_kb
    available_space_kb=$(df / | tail -1 | awk '{print $4}')
    local swap_size_kb
    swap_size_kb=$(echo "$swap_size" | sed 's/G$//')
    swap_size_kb=$((swap_size_kb * 1024 * 1024))
    local required_space_kb=$((swap_size_kb + 500000))

    if [ "$available_space_kb" -lt "$required_space_kb" ]; then
        echo -e "${RED}  ✗ Недостаточно места на диске!${NC}"
        return 1
    fi

    echo -e "${DIM}  Создание swap-файла размером $swap_size...${NC}"
    set +e
    sudo fallocate -l "$swap_size" /swapfile > /dev/null 2>&1 &
    local fallocate_pid=$!
    spinner $fallocate_pid "Создание swap-файла $swap_size"
    wait $fallocate_pid
    local fallocate_status=$?
    set -e

    if [ $fallocate_status -ne 0 ]; then
        echo -e "${DIM}  fallocate не поддерживается, используем dd...${NC}"
        local swap_gb
        swap_gb=$(echo "$swap_size" | sed 's/G$//')
        sudo dd if=/dev/zero of=/swapfile bs=1M count=$((swap_gb * 1024)) > /dev/null 2>&1 &
        spinner $! "Создание swap-файла $swap_size (dd)"
    fi

    sudo chmod 600 /swapfile
    echo -e "${GREEN}  ✓ Права доступа установлены${NC}"

    if sudo mkswap /swapfile > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Swap-файл отформатирован${NC}"
    else
        echo -e "${RED}  ✗ Ошибка форматирования swap-файла!${NC}"
        sudo rm -f /swapfile
        return 1
    fi

    if sudo swapon /swapfile; then
        echo -e "${GREEN}  ✓ Swap активирован${NC}"
    else
        echo -e "${RED}  ✗ Ошибка активации swap!${NC}"
        sudo rm -f /swapfile
        return 1
    fi

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        echo -e "${GREEN}  ✓ Swap добавлен в fstab${NC}"
    fi

    sudo sysctl vm.swappiness=10 > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Swappiness установлен на 10${NC}"

    return 0
}

# --- Установка утилиты ---
install_package() {
    local package=$1
    local cmd_name=${2:-$1}

    if ! command -v "$cmd_name" &> /dev/null; then
        set +e
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$package" > /dev/null 2>&1 &
        local install_pid=$!
        spinner $install_pid "Установка $package"
        wait $install_pid
        local install_status=$?
        set -e

        if [ $install_status -eq 0 ]; then
            echo -e "${GREEN}  ✓ $package установлен${NC}"
            INSTALLED_UTILS=$((INSTALLED_UTILS + 1))
        else
            echo -e "${RED}  ✗ Ошибка установки $package${NC}"
        fi
    else
        echo -e "${DIM}  · $package уже установлен${NC}"
    fi
}

# ============================================================================
# ГЛАВНОЕ МЕНЮ
# ============================================================================

show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}${BOLD}       UBUNTU SERVER OPTIMIZATION SCRIPT v3.0        ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    select_option "Выберите режим работы:" \
        "Автоматический — всё по умолчанию, без вопросов (~5-10 мин)" \
        "Интерактивный  — подтверждение каждого действия (~10-15 мин)"

    case $SELECTED in
        0) AUTO_MODE=true ;;
        1) AUTO_MODE=false ;;
    esac
}

# --- Раздел "Что будет сделано" ---
show_summary() {
    local recommended_swap
    recommended_swap=$(calculate_swap_size)

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}${BOLD}                  ЧТО БУДЕТ СДЕЛАНО                    ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}→${NC} Обновление системы и пакетов"
    echo -e "  ${WHITE}→${NC} Установка / обновление Docker"
    echo -e "  ${WHITE}→${NC} Установка ядра XanMod (BBRv3, low-latency)"
    echo -e "  ${WHITE}→${NC} Установка утилит (curl, wget, git, ping, unzip, mtr)"
    echo -e "  ${WHITE}→${NC} Создание SWAP файла (${recommended_swap}, swappiness=10)"
    echo -e "  ${WHITE}→${NC} Оптимизация ядра и сети (BBR, TCP, буферы, IPv6)"
    echo -e "  ${WHITE}→${NC} Оптимизация systemd и journal"
    echo -e "  ${WHITE}→${NC} Настройка logrotate"
    echo -e "  ${WHITE}→${NC} Увеличение лимитов ресурсов"
    echo -e "  ${WHITE}→${NC} Очистка системы"
    echo ""
    echo -e "${YELLOW}  ⚠ Рекомендуется перезагрузка после завершения${NC}"
    echo ""

    select_option "Начать выполнение?" "Да, начать" "Отмена"

    if [ "$SELECTED" -eq 1 ]; then
        echo -e "${RED}  Скрипт отменён.${NC}"
        exit 0
    fi

    FREED_SPACE_BEFORE=$(df / | tail -1 | awk '{print $3}')
}

# --- Итоговый отчёт ---
generate_report() {
    local script_end_time
    script_end_time=$(date +%s)
    local total_time=$((script_end_time - SCRIPT_START_TIME))
    local freed_space_after
    freed_space_after=$(df / | tail -1 | awk '{print $3}')
    local freed_space=$((FREED_SPACE_BEFORE - freed_space_after))

    echo ""
    section_separator
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}${BOLD}                 ОТЧЁТ О ВЫПОЛНЕНИИ                    ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local swap_size_info="не настроен"
    if [ -f /swapfile ]; then
        local swap_size_bytes
        swap_size_bytes=$(stat -c%s /swapfile 2>/dev/null || echo "0")
        if [ "$swap_size_bytes" != "0" ] && [ -n "$swap_size_bytes" ]; then
            local swap_size_gb=$((swap_size_bytes / 1024 / 1024 / 1024))
            swap_size_info="${swap_size_gb}GB"
        else
            local swap_info
            swap_info=$(swapon --show=SIZE --noheadings /swapfile 2>/dev/null | head -1)
            if [ -n "$swap_info" ]; then
                swap_size_info="$swap_info"
            fi
        fi
    fi

    echo -e "  ${GREEN}✓${NC} Установлено утилит: ${BOLD}$INSTALLED_UTILS${NC}"
    echo -e "  ${GREEN}✓${NC} SWAP: ${BOLD}${swap_size_info}${NC} (swappiness=10)"
    echo -e "  ${GREEN}✓${NC} BBR и TCP оптимизации: ${BOLD}применены${NC}"
    echo -e "  ${GREEN}✓${NC} Отключено сервисов: ${BOLD}$DISABLED_SERVICES${NC}"

    if [ $freed_space -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} Освобождено места: ${BOLD}$(numfmt --to=iec-i --suffix=B $((freed_space * 1024)) 2>/dev/null || echo "${freed_space}KB")${NC}"
    else
        echo -e "  ${GREEN}✓${NC} Место на диске: ${BOLD}оптимизировано${NC}"
    fi

    echo ""
    echo -e "  Время выполнения: ${BOLD}${total_time}s${NC} ${DIM}($(($total_time / 60))m $(($total_time % 60))s)${NC}"
    echo ""
    echo -e "  Использование диска:"
    df -h / | tail -n 1 | awk '{print "  " $3 " из " $2 " (" $5 ")"}'
    echo ""
    section_separator
}

# ============================================================================
# НАЧАЛО СКРИПТА
# ============================================================================

clear
show_menu
show_summary

# --- 1. Обновление базовой системы ---
section_start "ОБНОВЛЕНИЕ СИСТЕМЫ"

if [ ! -f /etc/apt/apt.conf.d/99-optimizations ]; then
    cat <<'EOF' | sudo tee /etc/apt/apt.conf.d/99-optimizations > /dev/null
Acquire::http::MaxConnections "10";
Acquire::http::Pipeline-Depth "5";
Acquire::CompressionTypes::Order:: "gz";
Acquire::http::Timeout "10";
Acquire::ftp::Timeout "10";
EOF
    echo -e "${GREEN}  ✓ Настройки APT оптимизированы${NC}"
fi

sudo apt-get update -qq > /dev/null 2>&1 &
spinner $! "Обновление списка пакетов"

sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -yqq > /dev/null 2>&1 &
spinner $! "Полное обновление системы"
section_end

# --- 2. Docker ---
section_start "DOCKER"

install_docker() {
    if ! command -v docker &> /dev/null; then
        # Docker не установлен — устанавливаем
        echo -e "${DIM}  Docker не найден, устанавливаем...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null
        sudo sh /tmp/get-docker.sh > /dev/null 2>&1 &
        spinner $! "Установка Docker"
        rm -f /tmp/get-docker.sh
        sudo usermod -aG docker "${SUDO_USER:-$USER}" > /dev/null 2>&1
        echo -e "${GREEN}  ✓ Docker установлен${NC}"
    else
        # Docker установлен — проверяем обновления
        local current_version
        current_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        echo -e "${DIM}  Docker ${current_version} установлен, проверяем обновления...${NC}"

        set +e
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq --only-upgrade docker-ce docker-ce-cli > /dev/null 2>&1 &
        spinner $! "Проверка обновлений Docker"
        set -e

        local new_version
        new_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        if [ "$current_version" = "$new_version" ]; then
            echo -e "${DIM}  · Docker ${current_version} — последняя версия${NC}"
        else
            echo -e "${GREEN}  ✓ Docker обновлён: ${current_version} → ${new_version}${NC}"
        fi
    fi

    # Docker Compose плагин
    if command -v docker &> /dev/null; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-compose-plugin > /dev/null 2>&1 &
        spinner $! "Docker Compose плагин"
    fi
}

install_docker
section_end

# --- 3. Ядро XanMod ---
section_start "ЯДРО XANMOD"

install_xanmod() {
    # Проверяем архитектуру
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${DIM}  · XanMod поддерживает только x86_64, пропущено${NC}"
        return 0
    fi

    # Проверяем, не установлено ли уже
    if uname -r | grep -qi xanmod; then
        echo -e "${DIM}  · XanMod ядро уже установлено ($(uname -r))${NC}"
        return 0
    fi

    # Зависимости
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
        curl wget gnupg lsb-release ca-certificates > /dev/null 2>&1 &
    spinner $! "Зависимости для XanMod"

    # GPG-ключ
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://dl.xanmod.org/archive.key \
        | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
    echo -e "${GREEN}  ✓ GPG-ключ XanMod добавлен${NC}"

    # Репозиторий
    local CODENAME
    CODENAME=$(lsb_release -sc 2>/dev/null || echo "noble")
    cat > /etc/apt/sources.list.d/xanmod-release.sources <<XANMOD_REPO
Types: deb
URIs: https://deb.xanmod.org
Suites: ${CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
XANMOD_REPO
    echo -e "${GREEN}  ✓ Репозиторий XanMod добавлен (${CODENAME})${NC}"

    # Определение уровня x86-64
    local CPU_LEVEL
    CPU_LEVEL=$(awk -f <(wget -qO - https://dl.xanmod.org/check_x86-64_psabi.sh) 2>/dev/null \
        | grep -oP 'x86-64-v\K[0-9]' | head -1 || true)

    if [ -z "$CPU_LEVEL" ]; then
        CPU_LEVEL=3
        echo -e "${DIM}  · Не удалось определить уровень CPU, используется v${CPU_LEVEL}${NC}"
    else
        echo -e "${GREEN}  ✓ CPU поддерживает x86-64-v${CPU_LEVEL}${NC}"
    fi

    # Обновление списков
    sudo apt-get update -qq > /dev/null 2>&1 &
    spinner $! "Обновление списков пакетов"

    # Установка ядра
    local PACKAGE="linux-xanmod-edge-x64v${CPU_LEVEL}"
    if apt-cache show "$PACKAGE" > /dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$PACKAGE" > /dev/null 2>&1 &
        spinner $! "Установка ${PACKAGE}"
        echo -e "${GREEN}  ✓ Ядро ${PACKAGE} установлено${NC}"
    else
        echo -e "${DIM}  · ${PACKAGE} не найден, пробуем x64v2...${NC}"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq linux-xanmod-edge-x64v2 > /dev/null 2>&1 &
        spinner $! "Установка linux-xanmod-edge-x64v2"
        echo -e "${GREEN}  ✓ Ядро linux-xanmod-edge-x64v2 установлено${NC}"
    fi

    echo -e "${YELLOW}  ⚠ XanMod + BBRv3 активируется после перезагрузки${NC}"
}

if confirm_arrow "Установить ядро XanMod (BBRv3, low-latency)?"; then
    install_xanmod
else
    echo -e "${DIM}  · Установка XanMod пропущена${NC}"
fi

section_end

# --- 4. Установка утилит ---
section_start "УСТАНОВКА УТИЛИТ"

install_package "curl" "curl"
install_package "wget" "wget"
install_package "git" "git"
install_package "iputils-ping" "ping"
install_package "unzip" "unzip"
install_package "mtr" "mtr"

section_end

# --- 4. Настройка SWAP ---
section_start "НАСТРОЙКА SWAP"

SWAP_SIZE=$(calculate_swap_size)
RAM_SIZE=$(free -g | awk '/^Mem:/{print $2}')

echo -e "${DIM}  RAM: ${RAM_SIZE}GB | Рекомендуемый SWAP: ${SWAP_SIZE}${NC}"

if [ -f /swapfile ]; then
    echo -e "${DIM}  Обнаружен существующий swap-файл${NC}"
    if confirm_arrow "Перезаписать swap-файл (новый размер: ${SWAP_SIZE})?"; then
        if swapon --show | grep -q '/swapfile'; then
            sudo swapoff -v /swapfile > /dev/null 2>&1
        fi
        if grep -q '/swapfile' /etc/fstab; then
            sudo sed -i '\|/swapfile|d' /etc/fstab
        fi
        sudo rm -f /swapfile

        if create_swap_file "$SWAP_SIZE"; then
            echo -e "${GREEN}  ✓ Swap-файл пересоздан${NC}"
        else
            echo -e "${RED}  ✗ Ошибка создания swap-файла${NC}"
        fi
    else
        echo -e "${DIM}  · Перезапись swap пропущена${NC}"
    fi
else
    if confirm_arrow "Создать swap-файл размером ${SWAP_SIZE}?"; then
        if create_swap_file "$SWAP_SIZE"; then
            echo -e "${GREEN}  ✓ Swap-файл создан${NC}"
        else
            echo -e "${RED}  ✗ Ошибка создания swap-файла${NC}"
        fi
    else
        echo -e "${DIM}  · Создание swap пропущено${NC}"
    fi
fi

section_end

# --- 5. Оптимизация ядра и сети ---
section_start "ОПТИМИЗАЦИЯ ЯДРА И СЕТИ"

# Удаляем старый файл если остался от предыдущих версий
sudo rm -f /etc/sysctl.d/99-custom.conf 2>/dev/null

# Загружаем nf_conntrack до применения sysctl
if ! lsmod | grep -q nf_conntrack; then
    sudo modprobe nf_conntrack > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Модуль nf_conntrack загружен${NC}"
fi

cat <<'EOF' | sudo tee /etc/sysctl.conf > /dev/null
# --- BBR & CONGESTION CONTROL ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_ecn=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_pacing_ss_ratio=100
net.ipv4.tcp_pacing_ca_ratio=120
net.ipv4.tcp_min_rtt_wlen=200
net.ipv4.tcp_min_rtt_active=1
net.ipv4.tcp_vegas_cong_avoid_limit=20

# --- NETWORK QUEUES ---
net.core.netdev_max_backlog=65536
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_window_scaling=1
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
net.core.dev_weight=64

# --- MEMORY BUFFERS ---
net.core.rmem_default=1048576
net.core.rmem_max=33554432
net.core.wmem_default=1048576
net.core.wmem_max=33554432
net.core.optmem_max=25165824
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536
net.ipv4.udp_mem=262144 327680 393216

# --- VIRTUAL MEMORY ---
vm.vfs_cache_pressure=50
vm.min_free_kbytes=65536
vm.overcommit_memory=0
vm.swappiness=10
vm.dirty_ratio=30
vm.dirty_background_ratio=2

# --- TCP TIMEOUTS & KEEPALIVE ---
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_orphan_retries=1
net.ipv4.tcp_max_tw_buckets=1440000

# --- CONNECTION OPTIMIZATIONS ---
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_early_retrans=3

# --- TCP RELIABILITY ---
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_limit_output_bytes=131072
net.ipv4.tcp_challenge_ack_limit=1000

# --- THIN STREAMS (GAMING) ---
net.ipv4.tcp_thin_linear_timeouts=1
net.ipv4.tcp_thin_dupack=1

# --- NETWORK STACK ---
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
net.core.message_burst=20
net.core.message_cost=16384
net.netfilter.nf_conntrack_max=1000000

# --- ROUTING ---
net.ipv4.ip_no_pmtu_disc=0
net.ipv4.route.gc_timeout=100

# --- PORTS & FILES ---
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=2097152

# --- CPU SCHEDULER ---
kernel.sched_min_granularity_ns=1000000
kernel.sched_wakeup_granularity_ns=1500000

# --- LOW LATENCY ---
kernel.timer_migration=0
kernel.nmi_watchdog=0
net.core.busy_poll=50
net.core.busy_read=50

# --- IP FORWARDING ---
net.ipv4.ip_forward=1

# --- DISABLE IPv6 ---
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

# Применяем параметры по одному, пропуская неподдерживаемые ядром
SYSCTL_ERRORS=0
while IFS= read -r line; do
    # Пропускаем комментарии и пустые строки
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! sudo sysctl -w "$line" > /dev/null 2>&1; then
        SYSCTL_ERRORS=$((SYSCTL_ERRORS + 1))
        param_name=$(echo "$line" | cut -d'=' -f1)
        echo -e "${DIM}  · ${param_name} — не поддерживается ядром, пропущен${NC}"
    fi
done < /etc/sysctl.conf

if [ $SYSCTL_ERRORS -eq 0 ]; then
    echo -e "${GREEN}  ✓ Все параметры применены${NC}"
else
    echo -e "${GREEN}  ✓ Параметры применены${NC} ${DIM}($SYSCTL_ERRORS пропущено)${NC}"
fi

section_end

# --- 9. Оптимизация systemd ---
section_start "ОПТИМИЗАЦИЯ SYSTEMD"

# Отключаем "Last login" в SSH
if grep -q '^PrintLastLog yes' /etc/ssh/sshd_config 2>/dev/null || ! grep -q '^PrintLastLog' /etc/ssh/sshd_config 2>/dev/null; then
    sudo sed -i 's/^PrintLastLog yes/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null
    if ! grep -q '^PrintLastLog' /etc/ssh/sshd_config 2>/dev/null; then
        echo 'PrintLastLog no' | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
    echo -e "${GREEN}  ✓ SSH PrintLastLog отключен${NC}"
fi

# Отключаем стандартный Ubuntu MOTD (дублирующий system info)
if [ -d /etc/update-motd.d ]; then
    sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    echo -e "${GREEN}  ✓ Ubuntu MOTD отключен${NC}"
fi
if [ -f /etc/motd ]; then
    sudo truncate -s 0 /etc/motd 2>/dev/null
fi

# Устанавливаем наш статус системы как MOTD при SSH-входе
cat << 'MOTD_SCRIPT' | sudo tee /etc/profile.d/server-status.sh > /dev/null
#!/bin/bash
# Server status — выводится при SSH-входе
[ -z "$PS1" ] && return  # только интерактивные сессии

L() { printf " %-22s: %s\n" "$1" "$2"; }

_s1=$(grep '^cpu ' /proc/stat); sleep 0.3; _s2=$(grep '^cpu ' /proc/stat)
read -r CPU_PCT IOW_PCT < <(awk -v s1="$_s1" -v s2="$_s2" 'BEGIN{
    gsub(/ +/," ",s1); gsub(/ +/," ",s2)
    sub(/^cpu /,"",s1); sub(/^cpu /,"",s2)
    split(s1,a," "); split(s2,b," ")
    dt=(b[1]+b[2]+b[3]+b[4]+b[5])-(a[1]+a[2]+a[3]+a[4]+a[5])
    if(dt>0) print int(((dt-(b[4]-a[4]))*100)/dt), int(((b[5]-a[5])*100)/dt)
    else print "0 0"
}')

IP=$(hostname -I | awk '{print $1}')
CORES=$(nproc)
LOAD=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
KERNEL=$(uname -r)
OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)

MEM_TOTAL_KB=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
MEM_USED_MB=$(( (MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024 ))
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_PCT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))

SWAP_TOTAL_KB=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
SWAP_FREE_KB=$( awk '/^SwapFree/{print $2}'  /proc/meminfo)
SWAP_USED_MB=$(( (SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024 ))
SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
SWAP_PCT=0
[ "$SWAP_TOTAL_MB" -gt 0 ] && SWAP_PCT=$(( SWAP_USED_MB * 100 / SWAP_TOTAL_MB ))

read -r _ DISK_SZ DISK_USED _ DISK_PCT _ < <(df -h / | tail -1)

read -r PROC_TOTAL PROC_RUN PROC_ZOMBIE < <(ps --no-headers aux 2>/dev/null | awk '
    {t++} $8~/^R/{r++} $8~/^Z/{z++}
    END{print t+0, r+0, z+0}')

NET_STR="-"
if command -v vnstat &>/dev/null; then
    NET_STR=$(vnstat --json 2>/dev/null | python3 -c "
import sys, json
try:
    tr = json.load(sys.stdin)['interfaces'][0]['traffic']
    def h(b):
        return f'{b/1024**3:.2f} GiB' if b >= 1073741824 else f'{b/1024**2:.0f} MiB'
    d = (tr.get('day') or [{}])[-1]; m = (tr.get('month') or [{}])[-1]
    print(f\"Day: [{h(d.get('rx',0))} / {h(d.get('tx',0))}] | Month: [{h(m.get('rx',0))} / {h(m.get('tx',0))}]\")
except: print('-')
" 2>/dev/null || echo "-")
fi

DOCKER_STR="-"
if command -v docker &>/dev/null; then
    D_RUN=$(docker ps -q 2>/dev/null | wc -l)
    D_STOP=$(docker ps -aq --filter status=exited 2>/dev/null | wc -l)
    DOCKER_STR="${D_RUN} running / ${D_STOP} stopped"
fi

BAN_STR="-"
command -v fail2ban-client &>/dev/null && BAN_STR="fail2ban"

FW_STR="-"
if command -v ufw &>/dev/null; then
    ufw status 2>/dev/null | grep -q "Status: active" && FW_STR="ufw"
fi

SSH_PORT=$(grep -m1 '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
[ -z "$SSH_PORT" ] && SSH_PORT="22"
SSH_SESS=$(who 2>/dev/null | wc -l)
SSH_IPS=$(who 2>/dev/null | awk '{print $5}' | tr -d '()' | sort -u | paste -sd ' ' -)
[ -z "$SSH_IPS" ] && SSH_IPS="local"

APT_UPD=0
if [ -f /var/lib/update-notifier/updates-available ]; then
    APT_UPD=$(grep -oP '^\d+' /var/lib/update-notifier/updates-available 2>/dev/null | head -1 || echo 0)
fi
AUTO_UPD="disabled"
grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && AUTO_UPD="enabled"

echo ""
L "IP Address"   "$IP"
L "OS"           "$OS"
L "Kernel"       "$KERNEL"
L "Load Average" "Cores: $CORES [$LOAD]"
L "CPU"          "${CPU_PCT}%"
L "RAM"          "${MEM_PCT}% [${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB]"
L "SWAP"         "${SWAP_PCT}% [${SWAP_USED_MB}MB / ${SWAP_TOTAL_MB}MB]"
L "Disk"         "${DISK_PCT} [${DISK_USED} / ${DISK_SZ}]"
L "Processes"    "${PROC_TOTAL} total, ${PROC_RUN} running, ${PROC_ZOMBIE} zombie"
L "I/O Wait"     "${IOW_PCT}%"
L "Net Traffic"  "$NET_STR"
L "Docker"       "$DOCKER_STR"
echo " ~~~~~~ Security ~~~~~~"
L "Ban Systems"  "$BAN_STR"
L "Firewall"     "$FW_STR"
L "SSH Port"     "$SSH_PORT"
L "SSH Sessions" "$SSH_SESS"
L "SSH IPs"      "$SSH_IPS"
echo " ~~~~~~~~~~~~~~~~~~~~~"
L "Apt Updates"  "${APT_UPD} package(s) can be updated"
L "Auto Updates" "$AUTO_UPD"
echo ""
MOTD_SCRIPT
sudo chmod +x /etc/profile.d/server-status.sh
echo -e "${GREEN}  ✓ MOTD статус системы установлен${NC}"

if confirm_arrow "Отключить ненужные системные сервисы?"; then
    SERVICES_TO_DISABLE=(
        "bluetooth.service"
        "cups.service"
        "cups-browsed.service"
        "ModemManager.service"
        "avahi-daemon.service"
    )

    for service in "${SERVICES_TO_DISABLE[@]}"; do
        if systemctl is-enabled "$service" &> /dev/null; then
            sudo systemctl disable --now "$service" > /dev/null 2>&1
            echo -e "${GREEN}  ✓ $service отключен${NC}"
            DISABLED_SERVICES=$((DISABLED_SERVICES + 1))
        fi
    done

    if [ $DISABLED_SERVICES -eq 0 ]; then
        echo -e "${DIM}  · Ненужных сервисов не найдено${NC}"
    fi
else
    echo -e "${DIM}  · Отключение сервисов пропущено${NC}"
fi

section_end

# --- 9.5. Оптимизация systemd journal ---
section_start "ОПТИМИЗАЦИЯ JOURNAL"

if confirm_arrow "Оптимизировать systemd journal?"; then
    if [ ! -f /etc/systemd/journald.conf.bak ]; then
        sudo cp /etc/systemd/journald.conf /etc/systemd/journald.conf.bak
    fi

    sudo sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
    sudo sed -i 's/^#SystemKeepFree=.*/SystemKeepFree=100M/' /etc/systemd/journald.conf
    sudo sed -i 's/^#SystemMaxFileSize=.*/SystemMaxFileSize=50M/' /etc/systemd/journald.conf
    sudo sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=7day/' /etc/systemd/journald.conf
    sudo sed -i 's/^#MaxFileSec=.*/MaxFileSec=1day/' /etc/systemd/journald.conf
    sudo sed -i 's/^#Compress=.*/Compress=yes/' /etc/systemd/journald.conf

    sudo sed -i 's/^SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
    sudo sed -i 's/^SystemKeepFree=.*/SystemKeepFree=100M/' /etc/systemd/journald.conf
    sudo sed -i 's/^SystemMaxFileSize=.*/SystemMaxFileSize=50M/' /etc/systemd/journald.conf
    sudo sed -i 's/^MaxRetentionSec=.*/MaxRetentionSec=7day/' /etc/systemd/journald.conf
    sudo sed -i 's/^MaxFileSec=.*/MaxFileSec=1day/' /etc/systemd/journald.conf
    sudo sed -i 's/^Compress=.*/Compress=yes/' /etc/systemd/journald.conf

    sudo systemctl restart systemd-journald > /dev/null 2>&1
    echo -e "${GREEN}  ✓ Journal оптимизирован (макс. 500MB, 7 дней)${NC}"
else
    echo -e "${DIM}  · Оптимизация journal пропущена${NC}"
fi

section_end

# --- 10. Настройка logrotate ---
section_start "НАСТРОЙКА LOGROTATE"

if confirm_arrow "Оптимизировать ротацию логов?"; then
    cat <<'EOF' | sudo tee /etc/logrotate.d/custom-optimization > /dev/null
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
        systemctl reload rsyslog 2>/dev/null || invoke-rc.d rsyslog rotate 2>/dev/null || true
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

    echo -e "${GREEN}  ✓ Logrotate настроен${NC}"
else
    echo -e "${DIM}  · Настройка logrotate пропущена${NC}"
fi

section_end

# --- 11. Лимиты ресурсов ---
section_start "ЛИМИТЫ РЕСУРСОВ"

if confirm_arrow "Увеличить лимиты файловых дескрипторов?"; then
    if [ ! -f /etc/security/limits.conf.bak ]; then
        sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak
    fi

    if ! grep -q 'CUSTOM RESOURCE LIMITS' /etc/security/limits.conf 2>/dev/null; then
        cat <<'EOF' | sudo tee -a /etc/security/limits.conf > /dev/null

# --- CUSTOM RESOURCE LIMITS ---
*               soft    nofile          65536
*               hard    nofile          65536
root            soft    nofile          65536
root            hard    nofile          65536
*               soft    nproc           32768
*               hard    nproc           32768
EOF
    fi

    if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session > /dev/null
    fi

    ulimit -n 65536 2>/dev/null || true
    ulimit -u 32768 2>/dev/null || true

    echo -e "${GREEN}  ✓ Лимиты увеличены (nofile=65536, nproc=32768)${NC}"
else
    echo -e "${DIM}  · Настройка лимитов пропущена${NC}"
fi

section_end

# --- 9. Очистка ---
section_start "ОЧИСТКА СИСТЕМЫ"

sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

sudo apt-get clean -qq > /dev/null 2>&1 &
spinner $! "Очистка кэша пакетов"

if confirm_arrow "Удалить старые версии ядра?"; then
    CURRENT_KERNEL=$(uname -r | sed 's/-generic//')

    set +e
    OLD_KERNELS=$(dpkg --list 2>/dev/null | \
                  grep -E 'linux-image-[0-9]' | \
                  grep -v "$CURRENT_KERNEL" | \
                  awk '{print $2}' | \
                  grep -E '^linux-image-[0-9]' | \
                  sort -V | \
                  head -n -1)
    set -e

    if [ -n "$OLD_KERNELS" ] && [ "$(echo "$OLD_KERNELS" | wc -l)" -gt 0 ]; then
        echo "$OLD_KERNELS" | while read -r kernel; do
            sudo apt-get purge -yqq "$kernel" > /dev/null 2>&1
        done &
        spinner $! "Удаление старых ядер"
    else
        echo -e "${DIM}  · Старых ядер не найдено${NC}"
    fi
else
    echo -e "${DIM}  · Очистка ядер пропущена${NC}"
fi

sudo journalctl --vacuum-time=7d --vacuum-size=100M > /dev/null 2>&1 &
spinner $! "Очистка журналов (>7 дней / >100MB)"

# Удаляем только старые файлы
sudo find /tmp -type f -atime +1 -delete 2>/dev/null || true
sudo find /var/tmp -type f -atime +1 -delete 2>/dev/null || true
echo -e "${GREEN}  ✓ Временные файлы очищены${NC}"

if confirm_arrow "Очистить корзину для всех пользователей?"; then
    TOTAL_TRASH_SIZE=0

    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(eval echo ~"$SUDO_USER")

        if [ -d "$USER_HOME/.local/share/Trash" ]; then
            TRASH_SIZE=$(du -sb "$USER_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            TRASH_SIZE_HR=$(du -sh "$USER_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
            sudo rm -rf "$USER_HOME/.local/share/Trash"/{files,info}/* 2>/dev/null
            echo -e "${GREEN}  ✓ $SUDO_USER: $TRASH_SIZE_HR${NC}"
        fi
    fi

    if [ -d /root/.local/share/Trash ]; then
        TRASH_SIZE=$(du -sb /root/.local/share/Trash 2>/dev/null | awk '{print $1}')
        if [ "$TRASH_SIZE" -gt 4096 ]; then
            TRASH_SIZE_HR=$(du -sh /root/.local/share/Trash 2>/dev/null | awk '{print $1}')
            TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
            sudo rm -rf /root/.local/share/Trash/{files,info}/* 2>/dev/null
            echo -e "${GREEN}  ✓ root: $TRASH_SIZE_HR${NC}"
        fi
    fi

    for user_home in /home/*; do
        if [ -d "$user_home/.local/share/Trash" ]; then
            username=$(basename "$user_home")
            [ "$username" = "${SUDO_USER:-}" ] && continue

            TRASH_SIZE=$(du -sb "$user_home/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            if [ "$TRASH_SIZE" -gt 4096 ]; then
                TRASH_SIZE_HR=$(du -sh "$user_home/.local/share/Trash" 2>/dev/null | awk '{print $1}')
                TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
                sudo rm -rf "$user_home/.local/share/Trash"/{files,info}/* 2>/dev/null
                echo -e "${GREEN}  ✓ $username: $TRASH_SIZE_HR${NC}"
            fi
        fi
    done

    if [ "$TOTAL_TRASH_SIZE" -eq 0 ]; then
        echo -e "${DIM}  · Корзины пустые${NC}"
    fi
else
    echo -e "${DIM}  · Очистка корзины пропущена${NC}"
fi

section_end

# --- Итоговый отчёт ---
generate_report

# --- Статус системы ---
show_system_status() {
    # Отключаем set -e для сбора статуса — многие команды могут возвращать ненулевой код
    set +e
    echo ""
    section_separator
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}${BOLD}                  СТАТУС СИСТЕМЫ                    ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    _L() { printf "  %-22s: %s\n" "$1" "$2"; }

    # CPU
    local _s1 _s2
    _s1=$(grep '^cpu ' /proc/stat); sleep 0.3; _s2=$(grep '^cpu ' /proc/stat)
    local CPU_PCT IOW_PCT
    read -r CPU_PCT IOW_PCT < <(awk -v s1="$_s1" -v s2="$_s2" 'BEGIN{
        gsub(/ +/," ",s1); gsub(/ +/," ",s2)
        sub(/^cpu /,"",s1); sub(/^cpu /,"",s2)
        split(s1,a," "); split(s2,b," ")
        dt=(b[1]+b[2]+b[3]+b[4]+b[5])-(a[1]+a[2]+a[3]+a[4]+a[5])
        if(dt>0) print int(((dt-(b[4]-a[4]))*100)/dt), int(((b[5]-a[5])*100)/dt)
        else print "0 0"
    }')

    local IP CORES LOAD_AVG KERNEL OS_NAME
    IP=$(hostname -I | awk '{print $1}')
    CORES=$(nproc)
    LOAD_AVG=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
    KERNEL=$(uname -r)
    OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)

    # Memory
    local MEM_TOTAL_KB MEM_AVAIL_KB MEM_USED_MB MEM_TOTAL_MB MEM_PCT
    MEM_TOTAL_KB=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
    MEM_AVAIL_KB=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
    MEM_USED_MB=$(( (MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024 ))
    MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
    MEM_PCT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))

    # Swap
    local SWAP_TOTAL_KB SWAP_FREE_KB SWAP_USED_MB SWAP_TOTAL_MB SWAP_PCT
    SWAP_TOTAL_KB=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
    SWAP_FREE_KB=$(awk '/^SwapFree/{print $2}' /proc/meminfo)
    SWAP_USED_MB=$(( (SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024 ))
    SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
    SWAP_PCT=0
    [ "$SWAP_TOTAL_MB" -gt 0 ] && SWAP_PCT=$(( SWAP_USED_MB * 100 / SWAP_TOTAL_MB ))

    # Disk
    local DISK_SZ DISK_USED DISK_PCT
    read -r _ DISK_SZ DISK_USED _ DISK_PCT _ < <(df -h / | tail -1)

    # Processes
    local PROC_TOTAL PROC_RUN PROC_ZOMBIE
    read -r PROC_TOTAL PROC_RUN PROC_ZOMBIE < <(ps --no-headers aux 2>/dev/null | awk '
        {t++} $8~/^R/{r++} $8~/^Z/{z++}
        END{print t+0, r+0, z+0}')

    # Network traffic
    local NET_STR="-"
    if command -v vnstat &>/dev/null; then
        NET_STR=$(vnstat --json 2>/dev/null | python3 -c "
import sys, json
try:
    tr = json.load(sys.stdin)['interfaces'][0]['traffic']
    def h(b):
        return f'{b/1024**3:.2f} GiB' if b >= 1073741824 else f'{b/1024**2:.0f} MiB'
    d = (tr.get('day') or [{}])[-1]; m = (tr.get('month') or [{}])[-1]
    print(f\"Day: [{h(d.get('rx',0))} / {h(d.get('tx',0))}] \u2502 Month: [{h(m.get('rx',0))} / {h(m.get('tx',0))}]\")
except: print('-')
" 2>/dev/null || echo "-")
    fi

    # Docker
    local DOCKER_STR="-"
    if command -v docker &>/dev/null; then
        local D_RUN D_STOP
        D_RUN=$(docker ps -q 2>/dev/null | wc -l)
        D_STOP=$(docker ps -aq --filter status=exited 2>/dev/null | wc -l)
        DOCKER_STR="${D_RUN} running / ${D_STOP} stopped"
    fi

    # Security
    local BAN_STR="-" FW_STR="-"
    command -v fail2ban-client &>/dev/null && BAN_STR="fail2ban"
    if command -v ufw &>/dev/null; then
        ufw status 2>/dev/null | grep -q "Status: active" && FW_STR="ufw"
    fi

    local SSH_PORT SSH_SESS SSH_IPS
    SSH_PORT=$(grep -m1 '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$SSH_PORT" ] && SSH_PORT="22"
    SSH_SESS=$(who 2>/dev/null | wc -l)
    SSH_IPS=$(who 2>/dev/null | awk '{print $5}' | tr -d '()' | sort -u | paste -sd ' ' -)
    [ -z "$SSH_IPS" ] && SSH_IPS="local"

    # Updates
    local APT_UPD=0 AUTO_UPD="disabled"
    if [ -f /var/lib/update-notifier/updates-available ]; then
        APT_UPD=$(grep -oP '^\d+' /var/lib/update-notifier/updates-available 2>/dev/null | head -1 || echo 0)
    fi
    grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && AUTO_UPD="enabled"

    _L "IP Address"   "$IP"
    _L "OS"           "$OS_NAME"
    _L "Kernel"       "$KERNEL"
    _L "Load Average" "Cores: $CORES [$LOAD_AVG]"
    _L "CPU"          "${CPU_PCT}%"
    _L "RAM"          "${MEM_PCT}% [${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB]"
    _L "SWAP"         "${SWAP_PCT}% [${SWAP_USED_MB}MB / ${SWAP_TOTAL_MB}MB]"
    _L "Disk"         "${DISK_PCT} [${DISK_USED} / ${DISK_SZ}]"
    _L "Processes"    "${PROC_TOTAL} total, ${PROC_RUN} running, ${PROC_ZOMBIE} zombie"
    _L "I/O Wait"     "${IOW_PCT}%"
    _L "Net Traffic"  "$NET_STR"
    _L "Docker"       "$DOCKER_STR"
    echo -e "  ${DIM}~~~~~~ Security ~~~~~~${NC}"
    _L "Ban Systems"  "$BAN_STR"
    _L "Firewall"     "$FW_STR"
    _L "SSH Port"     "$SSH_PORT"
    _L "SSH Sessions" "$SSH_SESS"
    _L "SSH IPs"      "$SSH_IPS"
    echo -e "  ${DIM}~~~~~~~~~~~~~~~~~~~~~${NC}"
    _L "Apt Updates"  "${APT_UPD} package(s) can be updated"
    _L "Auto Updates" "$AUTO_UPD"
    echo ""
    set -e
}

show_system_status

echo -e "${GREEN}${BOLD}  === ВСЁ ГОТОВО! ===${NC}"
echo ""

# --- Перезагрузка ---
select_option "Перезагрузить систему?" "Да, перезагрузить" "Нет, позже"

if [ "$SELECTED" -eq 0 ]; then
    echo ""
    for i in {5..1}; do
        printf "\r${YELLOW}  Перезагрузка через ${RED}%s${YELLOW} сек... ${DIM}(Ctrl+C для отмены)${NC}" "$i"
        sleep 1
    done
    printf "\r${GREEN}  Перезагружаем...                                        ${NC}\n"
    sudo reboot
else
    echo ""
    echo -e "${YELLOW}  Рекомендуется перезагрузить вручную: ${BOLD}sudo reboot${NC}"
fi
