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

# --- DISABLE IPV6 ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# --- SOCKET POLLING ---
net.core.busy_read = 50
net.core.busy_poll = 50
EOF

sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1
echo -e "${GREEN}>>> BBR и оптимизации применены ✓${NC}"

# --- 6. Очистка ---
echo -e "${GREEN}=== ОЧИСТКА СИСТЕМЫ ===${NC}"
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -yqq > /dev/null 2>&1 &
spinner $! "Удаление неиспользуемых пакетов"

sudo apt-get autoclean -qq > /dev/null 2>&1 &
spinner $! "Очистка кэша пакетов"

sudo journalctl --vacuum-time=1week > /dev/null 2>&1 &
spinner $! "Очистка старых логов"

echo -e "${BLUE}=== ВСЕ ГОТОВО! ===${NC}"

# --- 7. Перезагрузка ---
if confirm "Перезагрузить систему сейчас?"; then
    echo -e "${GREEN}=== ПЕРЕЗАГРУЗКА СИСТЕМЫ ЧЕРЕЗ 5 СЕКУНД ===${NC}"
    sleep 5
    sudo reboot
else
    echo -e "${YELLOW}>>> Перезагрузка отложена. Рекомендуется перезагрузить систему вручную.${NC}"
fi
