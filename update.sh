#!/bin/bash

# ============================================================================
#  UBUNTU SERVER OPTIMIZATION SCRIPT v2.0
#  Комплексная оптимизация и настройка сервера
# ============================================================================

# --- Настройки цветов и стилей ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Иконки статусов ---
SUCCESS="✅"
WARNING="⚠️"
ERROR="❌"
INFO="ℹ️"
SKIP="⏭️"
CLEAN="🧹"
SPEED="⚡"
SECURE="🔒"

# --- Переменные для статистики ---
INSTALLED_UTILS=0
DISABLED_SERVICES=0
FREED_SPACE_BEFORE=0
SCRIPT_START_TIME=$(date +%s)
TOTAL_SECTIONS=14
CURRENT_SECTION=0
SECTION_START_TIME=0
AUTO_MODE=false
MINIMAL_MODE=false

# --- Функция спиннера ---
spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    local start_time=$(date +%s)
    
    tput civis
    while kill -0 $pid 2>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        i=$(( (i+1) %10 ))
        printf "\r${YELLOW}${message} ${spin:$i:1} ${CYAN}[${elapsed}s]${NC}"
        sleep 0.1
    done
    tput cnorm
    local total_time=$(($(date +%s) - start_time))
    printf "\r${GREEN}${message} ${SUCCESS} ${DIM}(${total_time}s)${NC}\n"
}

# --- Функция для запроса подтверждения ---
confirm() {
    if [ "$AUTO_MODE" = true ]; then
        return 0
    fi
    
    while true; do
        read -p "$(echo -e ${MAGENTA}$1 ${CYAN}[y/n]:${NC} )" yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "${YELLOW}Пожалуйста, введите y или n.${NC}";;
        esac
    done
}

# --- Функция прогресс-бара ---
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    
    echo -ne "${BLUE}["
    printf "%${filled}s" | tr ' ' '█'
    printf "%$((width - filled))s" | tr ' ' '░'
    echo -e "] ${BOLD}${percentage}%%${NC} ${DIM}(${current}/${total})${NC}"
}

# --- Функция начала секции ---
section_start() {
    CURRENT_SECTION=$((CURRENT_SECTION + 1))
    SECTION_START_TIME=$(date +%s)
    
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    show_progress $CURRENT_SECTION $TOTAL_SECTIONS
    echo -e "${GREEN}${BOLD}=== $1 ===${NC}"
}

# --- Функция завершения секции ---
section_end() {
    local end_time=$(date +%s)
    local duration=$((end_time - SECTION_START_TIME))
    echo -e "${DIM}⏱  Выполнено за ${duration}s${NC}"
}

# --- Функция разделителя ---
section_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# --- Функция для установки утилиты с подтверждением ---
install_util() {
    local package=$1
    local description=$2
    
    if ! command -v $package &> /dev/null; then
        if confirm "Установить $package ($description)?"; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq $package > /dev/null 2>&1 &
            spinner $! "Установка $package"
            INSTALLED_UTILS=$((INSTALLED_UTILS + 1))
        else
            echo -e "${YELLOW}${SKIP} Установка $package пропущена.${NC}"
        fi
    else
        echo -e "${DIM}${INFO} $package уже установлен.${NC}"
    fi
}

# --- Функция интерактивного меню ---
show_menu() {
    clear
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${CYAN}${BOLD}    UBUNTU SERVER OPTIMIZATION SCRIPT v2.0          ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Выберите режим работы:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} ${GREEN}Быстрая настройка${NC}"
    echo -e "     ${DIM}Всё по умолчанию, без подтверждений (~5-10 мин)${NC}"
    echo ""
    echo -e "  ${BOLD}2)${NC} ${YELLOW}Интерактивный режим${NC}"
    echo -e "     ${DIM}С подтверждениями для каждой операции (~10-15 мин)${NC}"
    echo ""
    echo -e "  ${BOLD}3)${NC} ${BLUE}Минимальная установка${NC}"
    echo -e "     ${DIM}Только обновления и базовые настройки (~3-5 мин)${NC}"
    echo ""
    read -p "$(echo -e ${MAGENTA}Ваш выбор ${CYAN}[1-3]:${NC} )" MODE
    
    case $MODE in
        1) AUTO_MODE=true ;;
        2) AUTO_MODE=false ;;
        3) MINIMAL_MODE=true; AUTO_MODE=true ;;
        *) echo -e "${RED}${ERROR} Неверный выбор${NC}"; exit 1 ;;
    esac
    
    echo ""
}

# --- Функция сводки ---
show_summary() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${CYAN}${BOLD}                  ЧТО БУДЕТ СДЕЛАНО                    ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [ "$MINIMAL_MODE" = false ]; then
        echo -e "  ${SUCCESS} Обновление системы и пакетов"
        echo -e "  ${SUCCESS} Установка/обновление Docker + утилит"
        echo -e "  ${SPEED} Создание SWAP файла (4GB, swappiness=10)"
        echo -e "  ${SPEED} Оптимизация сети (BBR, TCP параметры)"
        echo -e "  ${SECURE} Отключение IPv6"
        echo -e "  ${SPEED} Оптимизация дисков и памяти"
        echo -e "  ${SPEED} Оптимизация systemd сервисов"
        echo -e "  ${SUCCESS} Настройка logrotate"
        echo -e "  ${SPEED} Увеличение лимитов ресурсов"
        echo -e "  ${CLEAN} Очистка системы и корзины"
    else
        echo -e "  ${SUCCESS} Обновление системы"
        echo -e "  ${SPEED} Базовая оптимизация ядра"
        echo -e "  ${CLEAN} Очистка системы"
    fi
    
    echo ""
    echo -e "${YELLOW}${WARNING} Рекомендуется перезагрузка после завершения${NC}"
    echo ""
    
    if ! confirm "Начать выполнение?"; then
        echo -e "${RED}${ERROR} Скрипт отменён пользователем.${NC}"
        exit 0
    fi
    
    FREED_SPACE_BEFORE=$(df / | tail -1 | awk '{print $3}')
}

# --- Функция итогового отчёта ---
generate_report() {
    local script_end_time=$(date +%s)
    local total_time=$((script_end_time - SCRIPT_START_TIME))
    local freed_space_after=$(df / | tail -1 | awk '{print $3}')
    local freed_space=$((FREED_SPACE_BEFORE - freed_space_after))
    
    echo ""
    section_separator
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${CYAN}${BOLD}                ОТЧЁТ О ВЫПОЛНЕНИИ                     ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}✅ Выполненные операции:${NC}"
    echo -e "  ${INFO} Установлено утилит: ${BOLD}$INSTALLED_UTILS${NC}"
    echo -e "  ${SUCCESS} SWAP: ${BOLD}4GB${NC} (swappiness=10)"
    echo -e "  ${SPEED} BBR и TCP оптимизации: ${BOLD}применены${NC}"
    echo -e "  ${SECURE} Отключено сервисов: ${BOLD}$DISABLED_SERVICES${NC}"
    
    if [ $freed_space -gt 0 ]; then
        echo -e "  ${CLEAN} Освобождено места: ${BOLD}$(numfmt --to=iec-i --suffix=B $((freed_space * 1024)) 2>/dev/null || echo "${freed_space}KB")${NC}"
    else
        echo -e "  ${INFO} Место на диске: ${BOLD}оптимизировано${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}${BOLD}⏱  Общее время выполнения:${NC} ${total_time}s ${DIM}($(($total_time / 60))m $(($total_time % 60))s)${NC}"
    echo ""
    echo -e "${BLUE}>>> Текущее использование диска:${NC}"
    df -h / | tail -n 1 | awk '{print "  Использовано: " $3 " из " $2 " (" $5 ")"}'
    echo ""
    section_separator
}

# ============================================================================
# НАЧАЛО СКРИПТА
# ============================================================================

clear
show_menu
show_summary

# Останавливаем выполнение скрипта при ошибке команд
set -eo pipefail

# --- 1. Обновление базовой системы ---
section_start "ОБНОВЛЕНИЕ СИСТЕМЫ"
sudo apt-get update -qq > /dev/null 2>&1 &
spinner $! "Обновление списка пакетов"

sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -yqq > /dev/null 2>&1 &
spinner $! "Полное обновление системы"
section_end

if [ "$MINIMAL_MODE" = false ]; then

# --- 2. Docker ---
section_start "УСТАНОВКА | ОБНОВЛЕНИЕ DOCKER"
if ! command -v docker &> /dev/null; then
    if confirm "Docker не установлен. Установить Docker?"; then
        curl -fsSL https://get.docker.com -o get-docker.sh 2>&1 | grep -v "^%" || true
        sudo sh get-docker.sh > /dev/null 2>&1 &
        spinner $! "Установка Docker"
        rm get-docker.sh
        sudo usermod -aG docker $USER > /dev/null 2>&1
        echo -e "${GREEN}${SUCCESS} Docker успешно установлен.${NC}"
    else
        echo -e "${YELLOW}${SKIP} Установка Docker пропущена.${NC}"
    fi
else
    echo -e "${DIM}${INFO} Docker уже установлен.${NC}"
fi

if command -v docker &> /dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-compose-plugin > /dev/null 2>&1 &
    spinner $! "Установка Docker Compose плагина"
fi
section_end

# --- 3. Установка утилит ---
section_start "УСТАНОВКА УТИЛИТ"

install_util "curl" "загрузка файлов из интернета"
install_util "wget" "альтернатива curl для загрузки файлов"
install_util "git" "система контроля версий"
install_util "unzip" "распаковка ZIP архивов"
install_util "zip" "создание ZIP архивов"
install_util "htop" "интерактивный монитор процессов"
install_util "speedtest-cli" "тест скорости интернета"
install_util "net-tools" "сетевые утилиты (ifconfig, netstat)"
install_util "mtr" "диагностика сети (ping + traceroute)"
install_util "traceroute" "трассировка маршрута"
install_util "nmap" "сканер сети и портов"
install_util "fail2ban" "защита от брутфорса"
install_util "ufw" "упрощённый firewall"

section_end

# --- 4. Настройка SWAP ---
section_start "НАСТРОЙКА SWAP"

if [ -f /swapfile ]; then
    echo -e "${YELLOW}${INFO} Обнаружен существующий swap-файл.${NC}"
    if confirm "Перезаписать существующий swap-файл?"; then
        if swapon --show | grep -q '/swapfile'; then
            sudo swapoff -v /swapfile > /dev/null 2>&1
            echo -e "${GREEN}${SUCCESS} Старый swap отключен${NC}"
        fi
        
        if grep -q '/swapfile' /etc/fstab; then
            sudo sed -i '\|/swapfile|d' /etc/fstab
            echo -e "${GREEN}${SUCCESS} Запись удалена из fstab${NC}"
        fi
        
        sudo rm -f /swapfile
        echo -e "${GREEN}${SUCCESS} Старый swap-файл удален${NC}"
        
        AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
        REQUIRED_SPACE=$((4 * 1024 * 1024 + 500000))
        
        if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
            echo -e "${RED}${ERROR} Ошибка: Недостаточно места на диске!${NC}"
            echo -e "${RED}Требуется: ~4.5GB, доступно: $(df -h / | tail -1 | awk '{print $4}')${NC}"
            exit 1
        fi
        
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        sudo chmod 600 /swapfile
        
        if sudo mkswap /swapfile > /dev/null 2>&1; then
            echo -e "${GREEN}${SUCCESS} Swap-файл отформатирован${NC}"
        else
            echo -e "${RED}${ERROR} Ошибка форматирования swap-файла!${NC}"
            exit 1
        fi
        
        if sudo swapon /swapfile; then
            echo -e "${GREEN}${SUCCESS} Swap активирован${NC}"
        else
            echo -e "${RED}${ERROR} Ошибка активации swap!${NC}"
            exit 1
        fi
        
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        echo -e "${GREEN}${SUCCESS} Swap добавлен в fstab${NC}"
        
        if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
        else
            sudo sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
        fi
        sudo sysctl vm.swappiness=10 > /dev/null 2>&1
        echo -e "${GREEN}${SUCCESS} Swappiness установлен на 10${NC}"
    else
        echo -e "${YELLOW}${SKIP} Перезапись swap пропущена.${NC}"
    fi
else
    if confirm "Создать swap-файл размером 4 ГБ?"; then
        AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
        REQUIRED_SPACE=$((4 * 1024 * 1024 + 500000))
        
        if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
            echo -e "${RED}${ERROR} Ошибка: Недостаточно места на диске!${NC}"
            echo -e "${RED}Требуется: ~4.5GB, доступно: $(df -h / | tail -1 | awk '{print $4}')${NC}"
            exit 1
        fi
        
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        sudo chmod 600 /swapfile
        
        if sudo mkswap /swapfile > /dev/null 2>&1; then
            echo -e "${GREEN}${SUCCESS} Swap-файл отформатирован${NC}"
        else
            echo -e "${RED}${ERROR} Ошибка форматирования swap-файла!${NC}"
            exit 1
        fi
        
        if sudo swapon /swapfile; then
            echo -e "${GREEN}${SUCCESS} Swap активирован${NC}"
        else
            echo -e "${RED}${ERROR} Ошибка активации swap!${NC}"
            exit 1
        fi
        
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
            echo -e "${GREEN}${SUCCESS} Swap добавлен в fstab${NC}"
        fi
        
        if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl vm.swappiness=10 > /dev/null 2>&1
            echo -e "${GREEN}${SUCCESS} Swappiness установлен на 10${NC}"
        fi
    else
        echo -e "${YELLOW}${SKIP} Создание swap пропущено.${NC}"
    fi
fi

section_end

fi # Конец блока MINIMAL_MODE

# --- 5. Оптимизация сети и ядра (BBR + Sysctl) ---
section_start "ОПТИМИЗАЦИЯ ЯДРА"

if [ ! -f /etc/sysctl.conf.bak ]; then
    sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak
fi

cat <<'EOF' | sudo tee /etc/sysctl.d/99-custom.conf > /dev/null
# --- SYSTEM & BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- NETWORK QUEUES ---
net.core.netdev_max_backlog = 2000
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 4096

# --- MEMORY BUFFERS ---
net.core.rmem_default = 212992
net.core.rmem_max = 6291456
net.core.wmem_default = 212992
net.core.wmem_max = 6291456
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 6291456
net.ipv4.tcp_wmem = 4096 131072 6291456

# --- TIMEOUTS & FAST OPEN ---
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# --- CONNECTION OPTIMIZATIONS ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_low_latency = 1

# --- MTU & DISCOVERY ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_no_pmtu_disc = 0

# --- PORTS & FILES ---
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 100000

# --- SOCKET POLLING ---
net.core.busy_read = 50
net.core.busy_poll = 50
EOF

sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
echo -e "${GREEN}${SUCCESS} BBR и базовые оптимизации применены${NC}"

section_end

if [ "$MINIMAL_MODE" = false ]; then

# --- 6. Отключение IPv6 ---
section_start "ОТКЛЮЧЕНИЕ IPv6"

if [ ! -f /etc/systemd/system/disable-ipv6.service ]; then
    if confirm "Отключить IPv6 через systemd сервис?"; then
        cat << 'EOF' | sudo tee /etc/systemd/system/disable-ipv6.service > /dev/null
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1

[Install]
WantedBy=multi-user.target
EOF
        
        sudo systemctl daemon-reload > /dev/null 2>&1
        sudo systemctl enable --now disable-ipv6.service > /dev/null 2>&1 &
        spinner $! "Включение сервиса отключения IPv6"
        echo -e "${GREEN}${SUCCESS} IPv6 отключен через systemd${NC}"
    else
        echo -e "${YELLOW}${SKIP} Отключение IPv6 пропущено.${NC}"
    fi
else
    echo -e "${DIM}${INFO} Сервис disable-ipv6 уже существует.${NC}"
fi

section_end

# --- 7. Оптимизация дисковой подсистемы ---
section_start "ОПТИМИЗАЦИЯ ДИСКОВ"

if confirm "Запустить TRIM для SSD (если установлен)?"; then
    set +e
    TRIM_OUTPUT=$(sudo fstrim -v / 2>&1)
    TRIM_STATUS=$?
    set -e
    
    if [ $TRIM_STATUS -eq 0 ]; then
        TRIMMED=$(echo "$TRIM_OUTPUT" | grep -oP '\d+(\.\d+)?\s+(GB|MB|KB|bytes)' | head -1)
        if [ ! -z "$TRIMMED" ]; then
            echo -e "${GREEN}${SUCCESS} TRIM выполнен: освобождено $TRIMMED${NC}"
        else
            echo -e "${GREEN}${SUCCESS} TRIM выполнен успешно${NC}"
        fi
    else
        echo -e "${YELLOW}${INFO} TRIM не поддерживается или диск не SSD${NC}"
    fi
else
    echo -e "${YELLOW}${SKIP} TRIM пропущен.${NC}"
fi

if confirm "Оптимизировать параметры записи на диск?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- DISK I/O OPTIMIZATION ---
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}${SUCCESS} Параметры дисковой подсистемы оптимизированы${NC}"
else
    echo -e "${YELLOW}${SKIP} Оптимизация дисков пропущена.${NC}"
fi

section_end

# --- 8. Оптимизация памяти ---
section_start "ОПТИМИЗАЦИЯ ПАМЯТИ"

if confirm "Применить оптимизацию параметров памяти?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- MEMORY OPTIMIZATION ---
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 65536
vm.overcommit_memory = 1
vm.panic_on_oom = 0
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}${SUCCESS} Параметры памяти оптимизированы${NC}"
else
    echo -e "${YELLOW}${SKIP} Оптимизация памяти пропущена.${NC}"
fi

section_end

# --- 9. Оптимизация systemd ---
section_start "ОПТИМИЗАЦИЯ SYSTEMD"

if confirm "Показать анализ времени загрузки systemd?"; then
    echo -e "${BLUE}${INFO} Топ-10 самых медленных сервисов:${NC}"
    systemd-analyze blame | head -n 10
    echo ""
fi

if confirm "Отключить ненужные системные сервисы?"; then
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
            echo -e "${GREEN}${SUCCESS} $service отключен${NC}"
            DISABLED_SERVICES=$((DISABLED_SERVICES + 1))
        fi
    done
else
    echo -e "${YELLOW}${SKIP} Отключение сервисов пропущено.${NC}"
fi

section_end

# --- 10. Настройка logrotate ---
section_start "НАСТРОЙКА LOGROTATE"

if confirm "Оптимизировать настройки ротации логов?"; then
    cat <<'EOF' | sudo tee /etc/logrotate.d/custom-optimization > /dev/null
# Оптимизация системных логов
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

# Docker логи (если Docker установлен)
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
    
    echo -e "${GREEN}${SUCCESS} Настройки logrotate оптимизированы${NC}"
else
    echo -e "${YELLOW}${SKIP} Настройка logrotate пропущена.${NC}"
fi

section_end

# --- 11. Увеличение лимитов ресурсов ---
section_start "НАСТРОЙКА ЛИМИТОВ РЕСУРСОВ"

if confirm "Увеличить лимиты файловых дескрипторов?"; then
    if [ ! -f /etc/security/limits.conf.bak ]; then
        sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak
    fi
    
    cat <<'EOF' | sudo tee -a /etc/security/limits.conf > /dev/null

# --- CUSTOM RESOURCE LIMITS ---
*               soft    nofile          65536
*               hard    nofile          65536
root            soft    nofile          65536
root            hard    nofile          65536
*               soft    nproc           32768
*               hard    nproc           32768
EOF
    
    if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session > /dev/null
    fi
    
    echo -e "${GREEN}${SUCCESS} Лимиты файловых дескрипторов увеличены${NC}"
    echo -e "${YELLOW}${WARNING} Требуется перезагрузка для применения изменений${NC}"
else
    echo -e "${YELLOW}${SKIP} Настройка лимитов пропущена.${NC}"
fi

section_end

# --- 12. Дополнительная оптимизация TCP ---
section_start "ДОПОЛНИТЕЛЬНАЯ ОПТИМИЗАЦИЯ TCP"

if confirm "Применить расширенную оптимизацию TCP?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- ADVANCED TCP OPTIMIZATION ---
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 1
EOF
    
    if ! lsmod | grep -q nf_conntrack; then
        sudo modprobe nf_conntrack > /dev/null 2>&1
        echo -e "${GREEN}${SUCCESS} Модуль nf_conntrack загружен${NC}"
    fi
    
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- CONNECTION TRACKING ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}${SUCCESS} Расширенная оптимизация TCP применена${NC}"
else
    echo -e "${YELLOW}${SKIP} Дополнительная оптимизация TCP пропущена.${NC}"
fi

section_end

fi # Конец блока MINIMAL_MODE

# --- 13. Очистка ---
section_start "ОЧИСТКА СИСТЕМЫ"

sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

sudo apt-get clean -qq > /dev/null 2>&1 &
spinner $! "Полная очистка кэша пакетов"

if confirm "Удалить старые версии ядра Linux?"; then
    CURRENT_KERNEL=$(uname -r | sed 's/-generic//')
    ALL_KERNELS=$(dpkg --list | grep -E 'linux-image-[0-9]' | grep -v "$CURRENT_KERNEL" | awk '{print $2}' | grep -E '^linux-image-[0-9]' | sort -V)
    KERNEL_COUNT=$(echo "$ALL_KERNELS" | grep -c '^linux-image' || echo 0)
    
    if [ $KERNEL_COUNT -gt 1 ]; then
        OLD_KERNELS=$(echo "$ALL_KERNELS" | head -n -1)
        
        if [ ! -z "$OLD_KERNELS" ]; then
            echo "$OLD_KERNELS" | xargs sudo apt-get purge -yqq > /dev/null 2>&1 &
            spinner $! "Удаление старых версий ядра"
        fi
    else
        echo -e "${DIM}${INFO} Старых версий ядра не обнаружено.${NC}"
    fi
else
    echo -e "${YELLOW}${SKIP} Очистка ядер пропущена.${NC}"
fi

sudo journalctl --vacuum-time=7d --vacuum-size=100M > /dev/null 2>&1 &
spinner $! "Очистка журналов (>7 дней или >100MB)"

sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null
echo -e "${GREEN}${SUCCESS} Временные файлы удалены${NC}"

if [ ! -z "${SUDO_USER:-}" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    if [ -d "$USER_HOME/.cache/thumbnails" ]; then
        rm -rf "$USER_HOME/.cache/thumbnails"/* 2>/dev/null
        echo -e "${GREEN}${SUCCESS} Кэш миниатюр очищен${NC}"
    fi
elif [ -d ~/.cache/thumbnails ]; then
    rm -rf ~/.cache/thumbnails/* 2>/dev/null
    echo -e "${GREEN}${SUCCESS} Кэш миниатюр очищен${NC}"
fi

if confirm "Очистить корзину для всех пользователей?"; then
    echo -e "${BLUE}${CLEAN} Очистка корзины:${NC}"
    TOTAL_TRASH_SIZE=0
    
    if [ ! -z "${SUDO_USER:-}" ]; then
        USER_HOME=$(eval echo ~$SUDO_USER)
        
        if [ -d "$USER_HOME/.local/share/Trash" ]; then
            TRASH_SIZE=$(du -sb "$USER_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            TRASH_SIZE_HR=$(du -sh "$USER_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
            sudo rm -rf "$USER_HOME/.local/share/Trash"/{files,info}/* 2>/dev/null
            echo -e "${GREEN}  ├─ Пользователь $SUDO_USER: $TRASH_SIZE_HR ${SUCCESS}${NC}"
        fi
        
        if [ -d "$USER_HOME/Desktop/Trash" ]; then
            sudo rm -rf "$USER_HOME/Desktop/Trash"/* 2>/dev/null
        fi
    fi
    
    if [ -d /root/.local/share/Trash ]; then
        TRASH_SIZE=$(du -sb /root/.local/share/Trash 2>/dev/null | awk '{print $1}')
        TRASH_SIZE_HR=$(du -sh /root/.local/share/Trash 2>/dev/null | awk '{print $1}')
        if [ "$TRASH_SIZE" -gt 4096 ]; then
            TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
            sudo rm -rf /root/.local/share/Trash/{files,info}/* 2>/dev/null
            echo -e "${GREEN}  ├─ Пользователь root: $TRASH_SIZE_HR ${SUCCESS}${NC}"
        fi
    fi
    
    for user_home in /home/*; do
        if [ -d "$user_home/.local/share/Trash" ]; then
            username=$(basename "$user_home")
            
            if [ "$username" = "${SUDO_USER:-}" ]; then
                continue
            fi
            
            TRASH_SIZE=$(du -sb "$user_home/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            TRASH_SIZE_HR=$(du -sh "$user_home/.local/share/Trash" 2>/dev/null | awk '{print $1}')
            
            if [ "$TRASH_SIZE" -gt 4096 ]; then
                TOTAL_TRASH_SIZE=$((TOTAL_TRASH_SIZE + TRASH_SIZE))
                sudo rm -rf "$user_home/.local/share/Trash"/{files,info}/* 2>/dev/null
                echo -e "${GREEN}  ├─ Пользователь $username: $TRASH_SIZE_HR ${SUCCESS}${NC}"
            fi
        fi
    done
    
    if [ $TOTAL_TRASH_SIZE -gt 0 ]; then
        TOTAL_TRASH_HR=$(echo "$TOTAL_TRASH_SIZE" | awk '{
            if ($1 > 1073741824) printf "%.2f GB", $1/1073741824;
            else if ($1 > 1048576) printf "%.2f MB", $1/1048576;
            else if ($1 > 1024) printf "%.2f KB", $1/1024;
            else printf "%d bytes", $1;
        }')
        echo -e "${GREEN}  └─ Итого освобождено: $TOTAL_TRASH_HR ${SUCCESS}${NC}"
    else
        echo -e "${YELLOW}  └─ Корзины пустые${NC}"
    fi
else
    echo -e "${YELLOW}${SKIP} Очистка корзины пропущена.${NC}"
fi

section_end

# --- Генерация итогового отчёта ---
generate_report

echo -e "${BLUE}${BOLD}=== ВСЁ ГОТОВО! ===${NC}"
echo ""

# --- 14. Перезагрузка ---
if confirm "Перезагрузить систему сейчас?"; then
    echo -e "${GREEN}=== ПЕРЕЗАГРУЗКА СИСТЕМЫ ===${NC}"
    
    for i in {5..1}; do
        printf "\r${YELLOW}⏱  Перезагрузка через ${RED}$i${YELLOW} секунд... ${DIM}(Ctrl+C для отмены)${NC}"
        sleep 1
    done
    
    printf "\r${GREEN}🔄 Перезагружаем систему...                                ${NC}\n"
    sudo reboot
else
    echo -e "${YELLOW}${WARNING} Перезагрузка отложена. Рекомендуется перезагрузить систему вручную.${NC}"
    echo -e "${CYAN}Команда для перезагрузки: ${BOLD}sudo reboot${NC}"
fi
