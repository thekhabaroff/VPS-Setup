#!/bin/bash

# ============================================================================
#  MOTD DASHBOARD INSTALLER
#  Красивый дашборд состояния сервера при SSH-входе
#  Выделено из VPS-Setup (update.sh)
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
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

MOTD_SCRIPT_PATH="/etc/profile.d/server-status.sh"

header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}${BOLD}               MOTD DASHBOARD INSTALLER               ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================================
# 1. Отключение штатного Ubuntu MOTD
# ============================================================================
disable_default_motd() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}>>> ОТКЛЮЧЕНИЕ ШТАТНОГО MOTD <<<${NC}"
    echo ""

    # Отключаем повтор "last login" при SSH-входе, чтобы не дублировать дашборд
    if grep -q '^PrintLastLog yes' /etc/ssh/sshd_config 2>/dev/null || ! grep -q '^PrintLastLog' /etc/ssh/sshd_config 2>/dev/null; then
        sudo sed -i 's/^PrintLastLog yes/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null
        if ! grep -q '^PrintLastLog' /etc/ssh/sshd_config 2>/dev/null; then
            echo 'PrintLastLog no' | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
        echo -e "${GREEN}  ✓ SSH PrintLastLog отключен${NC}"
    else
        echo -e "${DIM}  · SSH PrintLastLog уже отключен${NC}"
    fi

    if [ -d /etc/update-motd.d ]; then
        sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
        echo -e "${GREEN}  ✓ Ubuntu MOTD отключен${NC}"
    fi
    if [ -f /etc/motd ]; then
        sudo truncate -s 0 /etc/motd 2>/dev/null
        echo -e "${GREEN}  ✓ /etc/motd очищен${NC}"
    fi
}

# ============================================================================
# 2. Установка дашборда состояния сервера
# ============================================================================
install_dashboard() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}>>> УСТАНОВКА ДАШБОРДА <<<${NC}"
    echo ""

    cat << 'MOTD_SCRIPT' | sudo tee "$MOTD_SCRIPT_PATH" > /dev/null
#!/bin/bash
[ -z "$PS1" ] && return

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

IPV4=$(hostname -I | awk '{print $1}')
IPV6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d'/' -f1 | head -1)
[ -z "$IPV6" ] && IPV6="disabled"
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
SWAP_FREE_KB=$(awk '/^SwapFree/{print $2}' /proc/meminfo)
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
L "IP Address"   "$IPV4"
L "IPv6"         "$IPV6"
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
    sudo chmod +x "$MOTD_SCRIPT_PATH"
    echo -e "${GREEN}  ✓ MOTD дашборд установлен → ${MOTD_SCRIPT_PATH}${NC}"
}

# ============================================================================
# ГЛАВНАЯ ЛОГИКА
# ============================================================================
clear
header
disable_default_motd
install_dashboard

echo ""
echo -e "${GREEN}${BOLD}  === ГОТОВО! ===${NC}"
echo -e "${DIM}  Дашборд появится при следующем SSH-входе.${NC}"
echo -e "${DIM}  Предпросмотр сейчас: ${WHITE}bash ${MOTD_SCRIPT_PATH}${NC}"
echo ""
