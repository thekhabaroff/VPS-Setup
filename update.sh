#!/bin/bash

# --- Настройки цветов ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Функция спиннера ---
spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    tput civis # Скрываем курсор
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %10 ))
        printf "\r${YELLOW}${message} ${spin:$i:1}${NC}"
        sleep 0.1
    done
    tput cnorm # Возвращаем курсор
    printf "\r${GREEN}${message} ✓${NC}\n"
}

# --- Функция для запроса подтверждения ---
confirm() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "${YELLOW}Пожалуйста, введите y (да) или n (нет).${NC}";;
        esac
    done
}

# --- Функция для установки утилиты с подтверждением ---
install_util() {
    local package=$1
    local description=$2
    
    if ! command -v $package &> /dev/null; then
        if confirm "Установить $package ($description)?"; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq $package > /dev/null 2>&1 &
            spinner $! "Установка $package"
        else
            echo -e "${YELLOW}>>> Установка $package пропущена.${NC}"
        fi
    else
        echo -e "${YELLOW}>>> $package уже установлен.${NC}"
    fi
}

echo -e "${BLUE}=== ЗАПУСК СКРИПТА ===${NC}"

# Останавливаем выполнение скрипта при ошибке команд, но разрешаем нормальные выходы функций
set -eo pipefail

# --- 1. Обновление базовой системы ---
echo -e "${GREEN}=== ОБНОВЛЕНИЕ СИСТЕМЫ ===${NC}"
sudo apt-get update -qq > /dev/null 2>&1 &
spinner $! "Обновление списка пакетов"

sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -yqq > /dev/null 2>&1 &
spinner $! "Полное обновление системы"

# --- 2. Docker ---
echo -e "${GREEN}=== УСТАНОВКА | ОБНОВЛЕНИЕ DOCKER ===${NC}"
if ! command -v docker &> /dev/null; then
    if confirm "Docker не установлен. Установить Docker?"; then
        curl -fsSL https://get.docker.com -o get-docker.sh 2>&1 | grep -v "^%" || true
        sudo sh get-docker.sh > /dev/null 2>&1 &
        spinner $! "Установка Docker"
        rm get-docker.sh
        sudo usermod -aG docker $USER > /dev/null 2>&1
        echo -e "${GREEN}>>> Docker успешно установлен.${NC}"
    else
        echo -e "${YELLOW}>>> Установка Docker пропущена.${NC}"
    fi
else
    echo -e "${YELLOW}>>> Docker уже установлен.${NC}"
fi

# Убедимся, что стоит плагин Compose (только если Docker установлен)
if command -v docker &> /dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq docker-compose-plugin > /dev/null 2>&1 &
    spinner $! "Установка Docker Compose плагина"
fi

# --- 3. Установка утилит ---
echo -e "${GREEN}=== УСТАНОВКА УТИЛИТ ===${NC}"

# Базовые утилиты
install_util "curl" "загрузка файлов из интернета"
install_util "wget" "альтернатива curl для загрузки файлов"
install_util "git" "система контроля версий"
install_util "unzip" "распаковка ZIP архивов"
install_util "zip" "создание ZIP архивов"

# Мониторинг
install_util "htop" "интерактивный монитор процессов"

# Сеть
install_util "speedtest-cli" "тест скорости интернета"
install_util "net-tools" "сетевые утилиты (ifconfig, netstat)"
install_util "mtr" "диагностика сети (ping + traceroute)"
install_util "traceroute" "трассировка маршрута"
install_util "nmap" "сканер сети и портов"

# Безопасность
install_util "fail2ban" "защита от брутфорса"
install_util "ufw" "упрощённый firewall"

# --- 4. Настройка SWAP ---
echo -e "${GREEN}=== НАСТРОЙКА SWAP ===${NC}"

# Проверяем, существует ли уже swap-файл
if [ -f /swapfile ]; then
    echo -e "${YELLOW}>>> Обнаружен существующий swap-файл.${NC}"
    if confirm "Перезаписать существующий swap-файл?"; then
        # Отключаем текущий swap
        if swapon --show | grep -q '/swapfile'; then
            sudo swapoff -v /swapfile > /dev/null 2>&1
            echo -e "${GREEN}>>> Старый swap отключен ✓${NC}"
        fi
        
        # Удаляем запись из fstab
        if grep -q '/swapfile' /etc/fstab; then
            sudo sed -i '\|/swapfile|d' /etc/fstab
            echo -e "${GREEN}>>> Запись удалена из fstab ✓${NC}"
        fi
        
        # Удаляем старый файл
        sudo rm -f /swapfile
        echo -e "${GREEN}>>> Старый swap-файл удален ✓${NC}"
        
        # Проверяем свободное место (нужно минимум 4GB + 500MB буфер)
        AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
        REQUIRED_SPACE=$((4 * 1024 * 1024 + 500000)) # 4GB + 500MB в KB
        
        if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
            echo -e "${RED}>>> Ошибка: Недостаточно места на диске!${NC}"
            echo -e "${RED}>>> Требуется: ~4.5GB, доступно: $(df -h / | tail -1 | awk '{print $4}')${NC}"
            exit 1
        fi
        
        # Создаем новый swap-файл
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        # Настраиваем права
        sudo chmod 600 /swapfile
        
        # Форматируем как swap
        if sudo mkswap /swapfile > /dev/null 2>&1; then
            echo -e "${GREEN}>>> Swap-файл отформатирован ✓${NC}"
        else
            echo -e "${RED}>>> Ошибка форматирования swap-файла!${NC}"
            exit 1
        fi
        
        # Включаем swap
        if sudo swapon /swapfile; then
            echo -e "${GREEN}>>> Swap активирован ✓${NC}"
        else
            echo -e "${RED}>>> Ошибка активации swap!${NC}"
            exit 1
        fi
        
        # Добавляем в fstab
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        echo -e "${GREEN}>>> Swap добавлен в fstab ✓${NC}"
        
        # Настраиваем swappiness
        if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
        else
            sudo sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
        fi
        sudo sysctl vm.swappiness=10 > /dev/null 2>&1
        echo -e "${GREEN}>>> Swappiness установлен на 10 ✓${NC}"
    else
        echo -e "${YELLOW}>>> Перезапись swap пропущена.${NC}"
    fi
else
    # Swap-файл не существует, создаем новый
    if confirm "Создать swap-файл размером 4 ГБ?"; then
        # Проверяем свободное место (нужно минимум 4GB + 500MB буфер)
        AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
        REQUIRED_SPACE=$((4 * 1024 * 1024 + 500000)) # 4GB + 500MB в KB
        
        if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
            echo -e "${RED}>>> Ошибка: Недостаточно места на диске!${NC}"
            echo -e "${RED}>>> Требуется: ~4.5GB, доступно: $(df -h / | tail -1 | awk '{print $4}')${NC}"
            exit 1
        fi
        
        # Создаем swap-файл
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        # Настраиваем права
        sudo chmod 600 /swapfile
        
        # Форматируем как swap
        if sudo mkswap /swapfile > /dev/null 2>&1; then
            echo -e "${GREEN}>>> Swap-файл отформатирован ✓${NC}"
        else
            echo -e "${RED}>>> Ошибка форматирования swap-файла!${NC}"
            exit 1
        fi
        
        # Включаем swap
        if sudo swapon /swapfile; then
            echo -e "${GREEN}>>> Swap активирован ✓${NC}"
        else
            echo -e "${RED}>>> Ошибка активации swap!${NC}"
            exit 1
        fi
        
        # Добавляем в fstab
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
            echo -e "${GREEN}>>> Swap добавлен в fstab ✓${NC}"
        fi
        
        # Настраиваем swappiness
        if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl vm.swappiness=10 > /dev/null 2>&1
            echo -e "${GREEN}>>> Swappiness установлен на 10 ✓${NC}"
        fi
    else
        echo -e "${YELLOW}>>> Создание swap пропущено.${NC}"
    fi
fi

# --- 5. Оптимизация сети и ядра (BBR + Sysctl) ---
echo -e "${GREEN}=== ОПТИМИЗАЦИЯ ЯДРА ===${NC}"

# Бэкап конфига
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
net.ipv4.tcp_max_syn_backlog = 2048

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
echo -e "${GREEN}>>> BBR и оптимизации применены ✓${NC}"

# --- Отключение IPv6 через systemd ---
echo -e "${GREEN}=== ОТКЛЮЧЕНИЕ IPv6 ===${NC}"

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
        echo -e "${GREEN}>>> IPv6 отключен через systemd ✓${NC}"
    else
        echo -e "${YELLOW}>>> Отключение IPv6 пропущено.${NC}"
    fi
else
    echo -e "${YELLOW}>>> Сервис disable-ipv6 уже существует.${NC}"
fi

# --- 5.5. Оптимизация дисковой подсистемы ---
echo -e "${GREEN}=== ОПТИМИЗАЦИЯ ДИСКОВ ===${NC}"

# TRIM для SSD
if confirm "Запустить TRIM для SSD (если установлен)?"; then
    if sudo fstrim -v / > /dev/null 2>&1; then
        echo -e "${GREEN}>>> TRIM выполнен успешно ✓${NC}"
    else
        echo -e "${YELLOW}>>> TRIM не поддерживается или диск не SSD${NC}"
    fi
else
    echo -e "${YELLOW}>>> TRIM пропущен.${NC}"
fi

# Настройка параметров дисковой подсистемы в sysctl
if confirm "Оптимизировать параметры записи на диск?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- DISK I/O OPTIMIZATION ---
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}>>> Параметры дисковой подсистемы оптимизированы ✓${NC}"
else
    echo -e "${YELLOW}>>> Оптимизация дисков пропущена.${NC}"
fi

# --- 5.6. Оптимизация памяти ---
echo -e "${GREEN}=== ОПТИМИЗАЦИЯ ПАМЯТИ ===${NC}"

if confirm "Применить оптимизацию параметров памяти?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- MEMORY OPTIMIZATION ---
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 65536
vm.overcommit_memory = 1
vm.panic_on_oom = 0
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}>>> Параметры памяти оптимизированы ✓${NC}"
else
    echo -e "${YELLOW}>>> Оптимизация памяти пропущена.${NC}"
fi

# --- 5.7. Оптимизация systemd ---
echo -e "${GREEN}=== ОПТИМИЗАЦИЯ SYSTEMD ===${NC}"

if confirm "Показать анализ времени загрузки systemd?"; then
    echo -e "${BLUE}>>> Топ-10 самых медленных сервисов:${NC}"
    systemd-analyze blame | head -n 10
    echo ""
fi

if confirm "Отключить ненужные системные сервисы?"; then
    # Список потенциально ненужных сервисов для серверов
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
            echo -e "${GREEN}>>> $service отключен ✓${NC}"
        fi
    done
else
    echo -e "${YELLOW}>>> Отключение сервисов пропущено.${NC}"
fi

# --- 5.8. Настройка logrotate ---
echo -e "${GREEN}=== НАСТРОЙКА LOGROTATE ===${NC}"

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
    
    echo -e "${GREEN}>>> Настройки logrotate оптимизированы ✓${NC}"
else
    echo -e "${YELLOW}>>> Настройка logrotate пропущена.${NC}"
fi

# --- 5.9. Увеличение лимитов ресурсов ---
echo -e "${GREEN}=== НАСТРОЙКА ЛИМИТОВ РЕСУРСОВ ===${NC}"

if confirm "Увеличить лимиты файловых дескрипторов?"; then
    # Бэкап оригинального файла
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
    
    # Также добавляем в pam.d
    if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session > /dev/null
    fi
    
    echo -e "${GREEN}>>> Лимиты файловых дескрипторов увеличены ✓${NC}"
    echo -e "${YELLOW}>>> Требуется перезагрузка для применения изменений${NC}"
else
    echo -e "${YELLOW}>>> Настройка лимитов пропущена.${NC}"
fi

# --- 5.10. Дополнительная оптимизация TCP ---
echo -e "${GREEN}=== ДОПОЛНИТЕЛЬНАЯ ОПТИМИЗАЦИЯ TCP ===${NC}"

if confirm "Применить расширенную оптимизацию TCP?"; then
    cat <<'EOF' | sudo tee -a /etc/sysctl.d/99-custom.conf > /dev/null

# --- ADVANCED TCP OPTIMIZATION ---
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 1

# --- CONNECTION TRACKING ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
EOF
    
    sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
    echo -e "${GREEN}>>> Расширенная оптимизация TCP применена ✓${NC}"
else
    echo -e "${YELLOW}>>> Дополнительная оптимизация TCP пропущена.${NC}"
fi

# --- 6. Очистка ---
echo -e "${GREEN}=== ОЧИСТКА СИСТЕМЫ ===${NC}"

# Удаление неиспользуемых пакетов с зависимостями
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

# Полная очистка кэша пакетов (освобождает больше места)
sudo apt-get clean -qq > /dev/null 2>&1 &
spinner $! "Полная очистка кэша пакетов"

# Очистка старых версий ядра (оставляем только текущее и предыдущее)
if confirm "Удалить старые версии ядра Linux?"; then
    CURRENT_KERNEL=$(uname -r | sed 's/-generic//')
    
    # Получаем список всех установленных ядер, исключаем текущее
    ALL_KERNELS=$(dpkg --list | grep -E 'linux-image-[0-9]' | grep -v "$CURRENT_KERNEL" | awk '{print $2}' | grep -E '^linux-image-[0-9]' | sort -V)
    
    # Считаем количество ядер (текущее + остальные)
    KERNEL_COUNT=$(echo "$ALL_KERNELS" | grep -c '^linux-image' || echo 0)
    
    # Оставляем 1 предыдущее ядро, удаляем все остальные старые
    if [ $KERNEL_COUNT -gt 1 ]; then
        OLD_KERNELS=$(echo "$ALL_KERNELS" | head -n -1)
        
        if [ ! -z "$OLD_KERNELS" ]; then
            echo "$OLD_KERNELS" | xargs sudo apt-get purge -yqq > /dev/null 2>&1 &
            spinner $! "Удаление старых версий ядра"
        fi
    else
        echo -e "${YELLOW}>>> Старых версий ядра не обнаружено.${NC}"
    fi
else
    echo -e "${YELLOW}>>> Очистка ядер пропущена.${NC}"
fi

# Очистка журналов systemd (комбинация времени и размера)
sudo journalctl --vacuum-time=7d --vacuum-size=100M > /dev/null 2>&1 &
spinner $! "Очистка журналов (>7 дней или >100MB)"

# Очистка временных файлов
sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null
echo -e "${GREEN}>>> Временные файлы удалены ✓${NC}"

# Очистка кэша thumbnails (если это десктоп)
if [ ! -z "${SUDO_USER:-}" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    if [ -d "$USER_HOME/.cache/thumbnails" ]; then
        rm -rf "$USER_HOME/.cache/thumbnails"/* 2>/dev/null
        echo -e "${GREEN}>>> Кэш миниатюр очищен ✓${NC}"
    fi
elif [ -d ~/.cache/thumbnails ]; then
    rm -rf ~/.cache/thumbnails/* 2>/dev/null
    echo -e "${GREEN}>>> Кэш миниатюр очищен ✓${NC}"
fi

# Показываем освобожденное место
echo -e "${BLUE}>>> Свободное место на диске:${NC}"
df -h / | tail -n 1 | awk '{print "  Использовано: " $3 " из " $2 " (" $5 ")"}'

echo -e "${BLUE}=== ВСЕ ГОТОВО! ===${NC}"

# --- 7. Перезагрузка ---
if confirm "Перезагрузить систему сейчас?"; then
    echo -e "${GREEN}=== ПЕРЕЗАГРУЗКА СИСТЕМЫ ===${NC}"
    
    # Отсчет с визуализацией
    for i in {5..1}; do
        printf "\r${YELLOW}⏱  Перезагрузка через ${RED}$i${YELLOW} секунд... (Ctrl+C для отмены)${NC}"
        sleep 1
    done
    
    printf "\r${GREEN}🔄 Перезагружаем систему...                                ${NC}\n"
    sudo reboot
else
    echo -e "${YELLOW}>>> Перезагрузка отложена. Рекомендуется перезагрузить систему вручную.${NC}"
fi
