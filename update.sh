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

# Останавливаем выполнение скрипта при ошибке любой из команд
set -euo pipefail

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
        
        # Создаем новый swap-файл
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        # Настраиваем права
        sudo chmod 600 /swapfile
        
        # Форматируем как swap
        sudo mkswap /swapfile > /dev/null 2>&1
        echo -e "${GREEN}>>> Swap-файл отформатирован ✓${NC}"
        
        # Включаем swap
        sudo swapon /swapfile
        echo -e "${GREEN}>>> Swap активирован ✓${NC}"
        
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
        # Создаем swap-файл
        sudo fallocate -l 4G /swapfile > /dev/null 2>&1 &
        spinner $! "Создание swap-файла 4 ГБ"
        
        # Настраиваем права
        sudo chmod 600 /swapfile
        
        # Форматируем как swap
        sudo mkswap /swapfile > /dev/null 2>&1
        echo -e "${GREEN}>>> Swap-файл отформатирован ✓${NC}"
        
        # Включаем swap
        sudo swapon /swapfile
        echo -e "${GREEN}>>> Swap активирован ✓${NC}"
        
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
    CURRENT_KERNEL=$(uname -r)
    OLD_KERNELS=$(dpkg --list | grep -E 'linux-image-[0-9]' | grep -v "$CURRENT_KERNEL" | awk '{print $2}' | sort -V | head -n -1)
    
    if [ ! -z "$OLD_KERNELS" ]; then
        echo "$OLD_KERNELS" | xargs sudo apt-get purge -yqq > /dev/null 2>&1 &
        spinner $! "Удаление старых версий ядра"
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
if [ -d ~/.cache/thumbnails ]; then
    rm -rf ~/.cache/thumbnails/* 2>/dev/null
    echo -e "${GREEN}>>> Кэш миниатюр очищен ✓${NC}"
fi

# Показываем освобожденное место
echo -e "${BLUE}>>> Свободное место на диске:${NC}"
df -h / | tail -n 1 | awk '{print "  Использовано: " $3 " из " $2 " (" $5 ")"}'

echo -e "${BLUE}=== ВСЕ ГОТОВО! ===${NC}"

# --- 7. Перезагрузка ---
if confirm "Перезагрузить систему сейчас?"; then
    echo -e "${GREEN}=== ПЕРЕЗАГРУЗКА СИСТЕМЫ ЧЕРЕЗ 5 СЕКУНД ===${NC}"
    sleep 5
    sudo reboot
else
    echo -e "${YELLOW}>>> Перезагрузка отложена. Рекомендуется перезагрузить систему вручную.${NC}"
fi
