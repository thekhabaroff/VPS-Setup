#!/bin/bash

# Останавливаем выполнение скрипта при ошибке любой из команд
set -e

echo "--- Обновление списков пакетов ---"
sudo apt update

echo "--- Полное обновление системы ---"
sudo apt full-upgrade -y

echo "--- Обновление Snap пакетов ---"
sudo snap refresh

echo "--- Установка Flatpak (если не установлен) ---"
sudo apt install -y flatpak

echo "--- Обновление Flatpak пакетов ---"
flatpak update -y

echo "--- Установка/Обновление Docker ---"
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

echo "--- Очистка неиспользуемых пакетов ---"
sudo apt autoremove -y

echo "--- Очистка кэша apt ---"
sudo apt autoclean

echo "--- Очистка логов journald (старше 1 недели) ---"
sudo journalctl --vacuum-time=1week

echo "--- Перезагрузка системы... ---"
sudo reboot
