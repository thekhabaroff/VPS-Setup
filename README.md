VPS-Setup

# 🚀 Ubuntu Server Optimization Script v3.0

<div align="center">

![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%2B-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-11%2B-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-3.0-brightgreen?style=for-the-badge)

**Комплексная автоматическая оптимизация Ubuntu/Debian сервера одной командой**

[Быстрый старт](#-быстрый-старт) • [Что делает скрипт](#-что-делает-скрипт) • [Режимы работы](#-режимы-работы) • [Требования](#-требования)

</div>

---

## 📋 Описание

Полноценный bash-скрипт для настройки и оптимизации свежего или рабочего Ubuntu/Debian сервера. Автоматически устанавливает инструменты, настраивает параметры ядра, Docker, ядро XanMod с BBRv3 и приводит систему в оптимальное состояние для production-нагрузок.

Красивый интерактивный TUI с меню на стрелочках, прогресс-баром и спиннером. Оба режима — **автоматический** и **интерактивный**.

---

## ⚡ Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/optimize.sh | sudo bash

# Или вручную
wget https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/optimize.sh
chmod +x optimize.sh
sudo ./optimize.sh
```

> **⚠ Важно:** требует прав `root` или `sudo`. Рекомендуется на свежей системе.

---

## 🔧 Что делает скрипт

| № | Секция | Описание |
|---|--------|----------|
| 1 | **Обновление системы** | `apt full-upgrade`, оптимизация APT |
| 2 | **Docker** | Установка/обновление Docker CE + Compose Plugin |
| 3 | **Ядро XanMod** | `linux-xanmod-edge` с BBRv3 и low-latency |
| 4 | **Утилиты** | curl, wget, git, ping, unzip, mtr, speedtest |
| 5 | **SWAP** | Умный расчёт по RAM, swappiness=10 |
| 6 | **Оптимизация ядра/сети** | ~50 параметров sysctl: BBR, TCP, conntrack |
| 7 | **Systemd** | Отключение bluetooth, cups, avahi и др. |
| 8 | **Journal** | Лимиты journald: 500MB / 7 дней / сжатие |
| 9 | **Logrotate** | Ротация syslog, auth.log, логов Docker |
| 10 | **Лимиты ресурсов** | nofile=65536, nproc=32768 |
| 11 | **Очистка** | autoremove, apt clean, tmp, корзина |

### 📊 MOTD Dashboard при SSH-входе

```
 IP Address            : 192.168.1.1
 OS                    : Ubuntu 24.04.1 LTS
 Kernel                : 6.12.0-xanmod1
 CPU                   : 3%
 RAM                   : 24% [490MB / 2048MB]
 SWAP                  : 8% [200MB / 2048MB]
 Docker                : 3 running / 1 stopped
 ~~~~~~ Security ~~~~~~
 Firewall              : ufw
 SSH Sessions          : 1
```

### 💾 Умный расчёт SWAP

| RAM | SWAP |
|-----|------|
| < 1 GB | 2× RAM (мин 1G) |
| 1–2 GB | 2× RAM |
| 2–4 GB | 1× RAM |
| 4–8 GB | RAM/2 (мин 2G) |
| > 8 GB | 4 GB |

---

## 🖥 Режимы работы

| Режим | Описание | Время |
|-------|----------|-------|
| **Автоматический** | Всё без вопросов, идеально для CI | ~5–10 мин |
| **Интерактивный** | Каждый шаг подтверждается через меню | ~10–15 мин |

---

## 📦 Требования

- **ОС:** Ubuntu 20.04+ / Debian 11+ (x86_64)
- **Права:** root или sudo
- **Интернет:** требуется
- **Bash:** 4.0+
- **Место:** минимум 2 GB свободного

---

## 🔄 После установки

```bash
sudo reboot  # применить ядро XanMod

uname -r     # проверить ядро
sysctl net.ipv4.tcp_congestion_control  # должно быть bbr
```

---

## 📁 Изменяемые файлы

```
/etc/sysctl.conf
/etc/security/limits.conf
/etc/systemd/journald.conf
/etc/logrotate.d/custom-optimization
/etc/profile.d/server-status.sh
/etc/apt/apt.conf.d/99-optimizations
/swapfile
```

---

## 🛡 Безопасность

- Не меняет пароли и не создаёт пользователей
- Оригинальные конфиги сохраняются с `.bak`
- Неподдерживаемые параметры sysctl пропускаются автоматически

---

## 🤝 Contributing

1. Fork репозитория
2. `git checkout -b feature/my-feature`
3. `git commit -m 'Add my feature'`
4. `git push origin feature/my-feature`
5. Открой Pull Request

---

## 📄 Лицензия

[MIT](LICENSE)

---
<div align="center">Если скрипт оказался полезным — поставь ⭐ звезду!</div>


```bash
wget https://raw.githubusercontent.com/thekhabaroff/VPS-Setup/refs/heads/main/update.sh
chmod +x update.sh
bash update.sh
```
