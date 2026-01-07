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
        echo -e "${GREEN}>>> Docker успешно установ
