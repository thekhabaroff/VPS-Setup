#!/bin/bash

# --- Настройки цветов ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

echo -e "${BLUE}=== ЗАПУСК СКРИПТА ===${NC}"

# Останавливаем выполнение скрипта при ошибке любой из команд
set -euo pipefail

# --- 1. Обновление базовой системы ---
echo -e "${GREEN}=== ОБНОВЛЕНИЕ ПАКЕТОВ ===${NC}"
sudo apt update

echo -e "${GREEN}=== ПОЛНОЕ ОБНОВЛЕНИЕ СИСТЕМЫ ===${NC}"
sudo apt full-upgrade -y

# --- 2. Обновление менеджеров пакетов ---
echo -e "${GREEN}=== ОБНОВЛЕНИЕ SNAP ===${NC}"
if command -v snap &> /dev/null; then
    sudo snap refresh
else
    echo -e "${YELLOW}>>> Snap не установлен, пропускаем.${NC}"
fi

echo -e "${GREEN}=== УСТАНОВКА FLATPAK (ЕСЛИ НЕ УСТАНОВЛЕН) ===${NC}"
if ! command -v flatpak &> /dev/null; then
    echo -e "${YELLOW}>>> Установка Flatpak...${NC}"
    sudo apt install -y flatpak
fi

echo -e "${GREEN}=== ОБНОВЛЕНИЕ FLATPAK ===${NC}"
sudo flatpak update -y

# --- 3. Docker ---
echo -e "${GREEN}=== УСТАНОВКА | ОБНОВЛЕНИЕ DOCKER ===${NC}"
if ! command -v docker &> /dev/null; then
    if confirm "Docker не установлен. Установить Docker?"; then
        echo -e "${YELLOW}>>> Установка Docker...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        # Добавляем текущего пользователя в группу docker (чтобы не писать sudo docker)
        sudo usermod -aG docker $USER
        echo -e "${GREEN}>>> Docker успешно установлен.${NC}"
    else
        echo -e "${YELLOW}>>> Установка Docker пропущена.${NC}"
    fi
else
    echo -e "${YELLOW}>>> Docker уже установлен.${NC}"
fi

# Убедимся, что стоит плагин Compose (только если Docker установлен)
if command -v docker &> /dev/null; then
    sudo apt install -y docker-compose-plugin
fi

# --- 4. Установка полезных утилит ---
echo -e "${GREEN}>>> УСТАНОВКА УТИЛИТ (curl, wget, git, htop, speedtest, fail2ban and unzip)${NC}"
sudo apt install -y curl wget git htop fail2ban unzip speedtest-cli

# --- 5. Оптимизация сети и ядра (BBR + Sysctl) ---
echo -e "${GREEN}>>> Настройка ядра (BBR и оптимизация)...${NC}"

# Бэкап конфига
if [ ! -f /etc/sysctl.conf.bak ]; then
    sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak
fi

cat <<EOF | sudo tee /etc/sysctl.d/99-custom.conf > /dev/null
# --- SYSTEM & BBR ---
# Включаем BBR (стабилизация пинга)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- NETWORK QUEUES (Очереди) ---
# Увеличиваем очереди, чтобы пакеты не дропались при микро-спайках трафика
net.core.netdev_max_backlog = 2000
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 2048

# --- MEMORY BUFFERS (Буферы) ---
# Самое важное для ИГР (UDP). Ставим большие буферы (33MB).
# Если VPS имеет < 1GB RAM, уменьшите до 16777216 (16MB).
net.core.rmem_default = 212992
net.core.rmem_max = 6291456
net.core.wmem_default = 212992
net.core.wmem_max = 6291456
net.core.optmem_max = 65536

# Буферы для TCP
net.ipv4.tcp_rmem = 4096 131072 6291456
net.ipv4.tcp_wmem = 4096 131072 6291456

# --- TIMEOUTS & FAST OPEN ---
# Быстро убиваем зависшие соединения
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# --- CONNECTION OPTIMIZATIONS ---
# Ускоряем повторные подключения (Fast Open & Reuse)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_low_latency = 1

# --- MTU & DISCOVERY ---
# Включаем обнаружение MTU, полезно если пакеты дропаются где-то на магистрали
net.ipv4.tcp_mtu_probing = 1
# Стандартный режим PMTU Discovery (0 = включено)
net.ipv4.ip_no_pmtu_disc = 0

# --- PORTS & FILES ---
# Разрешаем системе использовать больше портов
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 100000

# --- OTHER OPTIMIZATIONS (DISABLE IPV6) ---
# Полное отключение IPv6  — рекомендуется, если провайдер не выдает IPv6, (чтобы система не тратила время на попытки резолва AAAA записей)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Читать сокеты в цикле 50 микросекунд (рекомендуемое значение)
net.core.busy_read = 50
net.core.busy_poll = 50
EOF

# Применяем настройки
sudo sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null
echo -e "${YELLOW}>>> BBR и оптимизации применены.${NC}"

echo -e "${GREEN}=== ОЧИСТКА НЕИСПОЛЬЗУЕМЫХ ПАКЕТОВ ===${NC}"
sudo apt autoremove -y

echo -e "${GREEN}=== ОЧИСТКА КЭША ===${NC}"
sudo apt autoclean

echo -e "${GREEN}=== ОЧИСТКА ЛОГОВ ===${NC}"
sudo journalctl --vacuum-time=1week

echo -e "${BLUE}=== ВСЕ ГОТОВО! ===${NC}"

if confirm "Перезагрузить систему сейчас?"; then
    echo -e "${GREEN}=== ПЕРЕЗАГРУЗКА СИСТЕМЫ ЧЕРЕЗ 5 СЕКУНД ===${NC}"
    sleep 5
    sudo reboot
else
    echo -e "${YELLOW}>>> Перезагрузка отложена. Рекомендуется перезагрузить систему вручную для применения всех изменений.${NC}"
fi
