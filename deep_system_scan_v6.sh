#!/usr/bin/env bash
#===============================================================================
# DEEP SYSTEM SCAN v6.0 - Безопасная диагностика Linux для ИИ-анализа
# ТОЛЬКО ЧТЕНИЕ: Никаких изменений в системе (кроме опциональной установки пакетов)
# Объединённая версия на основе v4, v5, v5.1, v5.2
#===============================================================================

set -o pipefail
# set -e намеренно НЕ используется для гибкой обработки ошибок

#-------------------------------------------------------------------------------
# КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
readonly VERSION="6.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly HOSTNAME="$(hostname)"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly DEFAULT_OUTPUT_DIR="$HOME/Desktop"
OUTPUT_FILE=""
SCAN_LEVEL=0

# Уровни сканирования
readonly LEVEL_MINIMAL=1
readonly LEVEL_MEDIUM=2
readonly LEVEL_TOTAL=3
readonly LEVEL_PROFILING=4

# Цвета для терминала
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # Без цвета

# Счётчики проблем
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()

# Статус инструментов
declare -A TOOLS_STATUS=()

# Флаги
AUTO_INSTALL=false
FORCE_PROFILING=false

#-------------------------------------------------------------------------------
# УНИВЕРСАЛЬНЫЕ ЗАПРЕТЫ
#-------------------------------------------------------------------------------
declare -a UNIVERSAL_PROHIBITIONS=(
    "[НЕ ДЕЛАТЬ] Менять права на /etc рекурсивно | Риск нарушения работы системы | Использовать точечные chmod"
    "[НЕ ДЕЛАТЬ] Отключать systemd-resolved без fallback DNS | Потеря сетевого доступа | Настроить альтернативный DNS"
    "[НЕ ДЕЛАТЬ] Чистить /var/log вручную через rm | Нарушение логирования | Использовать logrotate или journalctl --vacuum"
    "[НЕ ДЕЛАТЬ] Удалять dkms пакеты без проверки зависимостей | Поломка модулей ядра | Проверить: dkms status"
    "[НЕ ДЕЛАТЬ] Запускать fsck на смонтированном корне | Риск повреждения ФС | Загрузиться с LiveUSB"
    "[НЕ ДЕЛАТЬ] Удалять /lib/modules/\$(uname -r) | Система не загрузится | Использовать autoremove"
    "[НЕ ДЕЛАТЬ] Игнорировать SMART ошибки дисков | Потеря данных | Срочно сделать backup"
)

#-------------------------------------------------------------------------------
# ФУНКЦИИ БЕЗОПАСНОСТИ
#-------------------------------------------------------------------------------

# Обработка прерывания
trap 'echo -e "\n⚠️  Сканирование прервано пользователем."; exit 1' INT TERM

# Безопасное выполнение команды с таймаутом
safe_cmd() {
    local cmd="$*"
    if command -v timeout &>/dev/null; then
        timeout 15 bash -c "$cmd" 2>/dev/null || true
    else
        bash -c "$cmd" 2>/dev/null || true
    fi
}

# Безопасное выполнение с sudo (без интерактивного запроса)
safe_sudo_cmd() {
    local cmd="$*"
    if [[ $EUID -eq 0 ]]; then
        timeout 30 bash -c "$cmd" 2>/dev/null || true
    elif command -v sudo &>/dev/null; then
        timeout 30 sudo -n bash -c "$cmd" 2>/dev/null || true
    else
        echo "[NEEDS_ROOT]"
        return 1
    fi
}

# Проверка наличия утилиты
check_tool() {
    local tool="$1"
    command -v "$tool" &>/dev/null
}

# Добавление проблем
add_critical() {
    CRITICAL_ISSUES+=("$1")
}

add_warning() {
    WARNING_ISSUES+=("$1")
}

add_info() {
    INFO_ISSUES+=("$1")
}

add_prohibition() {
    STRICT_PROHIBITIONS+=("$1")
}

#-------------------------------------------------------------------------------
# ЛОГИРОВАНИЕ
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_critical() {
    echo -e "${RED}[CRITICAL]${NC} $*" >&2
}

log_section() {
    echo -e "\n${CYAN}=== $* ===${NC}" >&2
}

#-------------------------------------------------------------------------------
# ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
#-------------------------------------------------------------------------------
detect_pkg_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

PKG_MANAGER="$(detect_pkg_manager)"

#-------------------------------------------------------------------------------
# ПОДГОТОВКА ДИРЕКТОРИИ ВЫВОДА
#-------------------------------------------------------------------------------
prepare_output_dir() {
    local desktop_dirs=("$HOME/Desktop" "$HOME/Рабочий_стол" "$HOME")
    local target_dir=""
    
    for dir in "${desktop_dirs[@]}"; do
        if [[ -d "$dir" && -w "$dir" ]]; then
            target_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$target_dir" ]]; then
        target_dir="$HOME/Desktop"
        if mkdir -p "$target_dir" 2>/dev/null; then
            log_info "Создана директория: $target_dir"
        else
            target_dir="$HOME"
            log_warning "Не удалось создать Desktop, используем: $target_dir"
        fi
    fi
    
    OUTPUT_FILE="${target_dir}/DEEP_SCAN_${HOSTNAME}_${TIMESTAMP}.log"
    echo "📁 Отчёт будет сохранён: $OUTPUT_FILE" >&2
}

#-------------------------------------------------------------------------------
# БАННЕР
#-------------------------------------------------------------------------------
show_banner() {
    cat << EOF
╔══════════════════════════════════════════════════════════════╗
║          DEEP SYSTEM SCAN v${VERSION} - Диагностика Linux           ║
║              Безопасный сканер только для чтения             ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

#-------------------------------------------------------------------------------
# МЕНЮ НА РУССКОМ
#-------------------------------------------------------------------------------
show_scan_menu() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║      DEEP SYSTEM SCAN v6.0 - Выбор уровня диагностики        ║
╠══════════════════════════════════════════════════════════════╣
║  [1] Минимальный: ядро, CPU/RAM, базовые логи, uptime        ║
║      (~30 секунд)                                            ║
║  [2] Средний: + службы, пакеты, сеть, SMART, пользователи    ║
║      (~2 минуты)                                             ║
║  [3] Тотальный: + безопасность, валидация, контейнеры        ║
║      (~5 минут)                                              ║
║  [4] Профилирование: + стресс-тесты, тяжёлые метрики         ║
║      (~10 минут, ТРЕБУЕТ подтверждения!)                     ║
╚══════════════════════════════════════════════════════════════╝
EOF
    
    while true; do
        read -rp "Выберите уровень сканирования [1-4] (по умолчанию 1): " choice
        case "$choice" in
            "") choice=1 ;;
            1) SCAN_LEVEL=1; echo "✅ Выбран режим: МИНИМАЛЬНЫЙ"; break ;;
            2) SCAN_LEVEL=2; echo "✅ Выбран режим: СРЕДНИЙ"; break ;;
            3) SCAN_LEVEL=3; echo "✅ Выбран режим: ТОТАЛЬНЫЙ"; break ;;
            4) 
                echo -e "${YELLOW}⚠️  Режим 4 включает стресс-тесты!${NC}"
                read -rp "Продолжить? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    SCAN_LEVEL=4
                    echo "✅ Выбран режим: ПРОФИЛИРОВАНИЕ И СТРЕСС-ТЕСТЫ"
                    break
                else
                    echo "❌ Выбор отменён."
                fi
                ;;
            *) echo "❌ Неверный выбор. Введите 1, 2, 3 или 4." ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# ПРОВЕРКА И УСТАНОВКА ИНСТРУМЕНТОВ
#-------------------------------------------------------------------------------
check_and_install_tools() {
    log_section "Проверка необходимых инструментов"
    
    local -a missing_tools=()
    
    # Основные инструменты
    declare -A tool_packages=(
        ["smartctl"]="smartmontools"
        ["sensors"]="lm-sensors"
        ["dmidecode"]="dmidecode"
        ["lsof"]="lsof"
        ["ss"]="iproute2"
        ["pciutils"]="pciutils"
        ["usbutils"]="usbutils"
        ["hwinfo"]="hwinfo"
        ["inxi"]="inxi"
        ["powertop"]="powertop"
        ["stress-ng"]="stress-ng"
        ["fio"]="fio"
        ["edac-util"]="edac-utils"
        ["ras-mc-ctl"]="rasdaemon"
    )
    
    echo ""
    for tool in "${!tool_packages[@]}"; do
        if check_tool "$tool"; then
            TOOLS_STATUS["$tool"]="installed"
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            TOOLS_STATUS["$tool"]="missing"
            missing_tools+=("${tool_packages[$tool]}")
            echo -e "  ${RED}✗${NC} $tool [TOOL_MISSING: $tool]"
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo ""
        log_warning "Отсутствуют инструменты: ${missing_tools[*]}"
        
        if [[ "$AUTO_INSTALL" == true ]] || [[ "$SCAN_LEVEL" -ge $LEVEL_TOTAL ]]; then
            if [[ "$PKG_MANAGER" != "unknown" ]]; then
                echo ""
                if [[ "$AUTO_INSTALL" != true ]]; then
                    read -rp "Установить отсутствующие пакеты? (y/N): " confirm
                else
                    confirm="y"
                fi
                
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    log_info "Установка пакетов через $PKG_MANAGER..."
                    
                    local install_cmd=""
                    case "$PKG_MANAGER" in
                        apt)
                            install_cmd="sudo apt update && sudo apt install -y ${missing_tools[*]}"
                            ;;
                        dnf|yum)
                            install_cmd="sudo $PKG_MANAGER install -y ${missing_tools[*]}"
                            ;;
                        pacman)
                            install_cmd="sudo pacman -S --noconfirm ${missing_tools[*]}"
                            ;;
                        zypper)
                            install_cmd="sudo zypper install -y ${missing_tools[*]}"
                            ;;
                    esac
                    
                    if eval "$install_cmd" 2>/dev/null; then
                        log_success "Пакеты установлены успешно"
                        echo -e "${GREEN}📦 Установлены:${NC} ${missing_tools[*]}"
                        echo -e "${YELLOW}Для удаления:${NC} sudo $PKG_MANAGER remove ${missing_tools[*]}"
                        
                        # Повторная проверка
                        for tool in "${!tool_packages[@]}"; do
                            if check_tool "$tool"; then
                                TOOLS_STATUS["$tool"]="installed"
                            fi
                        done
                    else
                        log_warning "Не удалось установить пакеты"
                    fi
                fi
            fi
        fi
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# УТИЛИТЫ ВЫВОДА
#-------------------------------------------------------------------------------
print_section_header() {
    local output=""
    output+="\n## [$1]\n\n"
    echo -e "$output" | tee -a "$OUTPUT_FILE"
}

print_subsection() {
    local output="### [$1]"
    echo "$output" | tee -a "$OUTPUT_FILE"
}

print_status() {
    local output="• STATUS: $1"
    echo "$output" | tee -a "$OUTPUT_FILE"
}

print_data() {
    local output="• DATA: $1"
    echo "$output" | tee -a "$OUTPUT_FILE"
}

print_issues() {
    if [[ -n "$1" ]]; then
        local output="• ISSUES_FOUND: $1"
        echo "$output" | tee -a "$OUTPUT_FILE"
    fi
}

print_raw_logs() {
    if [[ -n "$1" ]]; then
        echo "• RAW_LOGS:" | tee -a "$OUTPUT_FILE"
        echo "$1" | head -20 | tee -a "$OUTPUT_FILE"
    fi
}

#-------------------------------------------------------------------------------
# ЗАГОЛОВОК ОТЧЁТА
#-------------------------------------------------------------------------------
write_report_header() {
    {
        echo "========================================"
        echo "DEEP SYSTEM SCAN v${VERSION}"
        echo "Host: ${HOSTNAME}"
        echo "Date: ${TIMESTAMP}"
        echo "Level: ${SCAN_LEVEL}"
        echo "Package Manager: ${PKG_MANAGER}"
        echo "========================================"
        echo ""
    } >> "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: CPU
#-------------------------------------------------------------------------------
scan_cpu() {
    print_section_header "CPU_INFO"
    
    local cpu_model cpu_cores cpu_freq
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'Unknown')"
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 'Unknown')"
    cpu_freq="$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    
    print_data "Model: $cpu_model"
    print_data "Cores: $cpu_cores"
    print_data "Frequency: ${cpu_freq} MHz"
    
    # Загрузка CPU
    local load_avg
    load_avg="$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    print_data "Load Average (1/5/15 min): $load_avg"
    
    # Температура CPU
    print_subsection "CPU_THERMAL"
    local cpu_temp=""
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            local zone_name zone_type temp_val temp_c
            zone_type="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Unknown")"
            if [[ "$zone_type" =~ [Cc][Pp][Uu] ]]; then
                temp_val="$(cat "$zone" 2>/dev/null)"
                temp_c=$((temp_val / 1000))
                cpu_temp="$temp_c"
                
                if [[ $temp_c -gt 85 ]]; then
                    add_warning "Высокая температура CPU: ${temp_c}°C | Проверьте систему охлаждения"
                    print_data "Temperature: ${temp_c}°C [HIGH]"
                else
                    print_data "Temperature: ${temp_c}°C"
                fi
                break
            fi
        fi
    done
    
    if [[ -z "$cpu_temp" ]]; then
        print_data "Temperature: N/A (sensor not found)"
    fi
    
    # Microcode
    print_subsection "CPU_MICROCODE"
    local microcode
    microcode="$(grep -i 'microcode' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
    print_data "Microcode: $microcode"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: RAM
#-------------------------------------------------------------------------------
scan_ram() {
    print_section_header "MEMORY_INFO"
    
    local mem_total mem_avail mem_used mem_percent
    mem_total="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    mem_avail="$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    mem_used=$((mem_total - mem_avail))
    mem_percent=$((mem_used * 100 / (mem_total > 0 ? mem_total : 1)))
    
    print_data "Total: ${mem_total} MB"
    print_data "Available: ${mem_avail} MB"
    print_data "Used: ${mem_used} MB (${mem_percent}%)"
    
    if [[ $mem_percent -gt 90 ]]; then
        add_critical "Критическое использование RAM: ${mem_percent}% | Проверьте процессы"
        print_issues "High memory usage (>90%)"
    elif [[ $mem_percent -gt 80 ]]; then
        add_warning "Высокое использование RAM: ${mem_percent}% | Рекомендуется мониторинг"
    fi
    
    # Swap
    print_subsection "SWAP_INFO"
    local swap_total swap_free swap_used
    swap_total="$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    swap_free="$(grep SwapFree /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    swap_used=$((swap_total - swap_free))
    
    print_data "Swap Total: ${swap_total} MB"
    print_data "Swap Used: ${swap_used} MB"
    
    if [[ $swap_total -gt 0 && $swap_used -gt 0 ]]; then
        local swap_percent=$((swap_used * 100 / swap_total))
        print_data "Swap Usage: ${swap_percent}%"
        if [[ $swap_percent -gt 50 ]]; then
            add_warning "Высокое использование swap: ${swap_percent}% | Возможно недостаточно RAM"
        fi
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: DISK
#-------------------------------------------------------------------------------
scan_storage() {
    print_section_header "STORAGE_INFO"
    
    print_subsection "DISK_SPACE"
    local disk_info
    disk_info="$(df -h 2>/dev/null | grep -E '^/dev/' | head -10)"
    if [[ -n "$disk_info" ]]; then
        echo "$disk_info" | tee -a "$OUTPUT_FILE"
    fi
    
    # Проверка заполненности
    local high_usage
    high_usage="$(df -h 2>/dev/null | awk 'NR>1 {gsub(/%/,""); if($5>90) print $6" at "$5"%"}')"
    if [[ -n "$high_usage" ]]; then
        add_critical "Критическое заполнение диска: $high_usage | Освободите место"
        print_issues "High disk usage (>90%)"
    fi
    
    print_subsection "INODE_USAGE"
    local inode_info
    inode_info="$(df -i 2>/dev/null | head -5)"
    if [[ -n "$inode_info" ]]; then
        echo "$inode_info" | tee -a "$OUTPUT_FILE"
    fi
    
    # SMART статус
    print_subsection "SMART_DISK_STATUS"
    if check_tool smartctl; then
        local disks
        disks="$(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/(sd|nvme|hd)' | head -5)"
        local disk_issues=""
        
        for disk in $disks; do
            local smart_data
            smart_data="$(safe_sudo_cmd "smartctl -A $disk" 2>/dev/null)"
            if [[ "$smart_data" != "[NEEDS_ROOT]" && -n "$smart_data" ]]; then
                local reallocated pending udma
                reallocated="$(echo "$smart_data" | grep -iE 'Reallocated_Sector_Ct|Reallocated_Event_Count' | awk '{print $NF}' | head -1)"
                pending="$(echo "$smart_data" | grep -i 'Current_Pending_Sector' | awk '{print $NF}' | head -1)"
                udma="$(echo "$smart_data" | grep -i 'UDMA_CRC_Error_Count' | awk '{print $NF}' | head -1)"
                
                reallocated="${reallocated:-0}"
                pending="${pending:-0}"
                udma="${udma:-0}"
                
                if [[ "$reallocated" -gt 0 || "$pending" -gt 0 || "$udma" -gt 0 ]]; then
                    disk_issues="$disk: Realloc=$reallocated, Pending=$pending, UDMA=$udma | "
                    add_critical "Диск $disk показывает SMART предупреждения | Realloc=$reallocated, Pending=$pending | Срочно сделайте backup"
                    add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать диск $disk | Найден переназначенные сектора | Backup и замена"
                    print_data "$disk [DISK_RISK]: Realloc=$reallocated, Pending=$pending, UDMA=$udma"
                fi
            else
                print_status "SKIPPED [NEEDS_ROOT for smartctl]"
                break
            fi
        done
        
        if [[ -z "$disk_issues" ]]; then
            print_data "All checked disks: OK"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: smartctl]"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: GPU
#-------------------------------------------------------------------------------
scan_gpu() {
    print_section_header "GPU_DRIVERS"
    
    if check_tool lspci; then
        local gpu_info
        gpu_info="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -5)"
        if [[ -n "$gpu_info" ]]; then
            print_data "GPU Devices:"
            echo "$gpu_info" | while read -r line; do
                echo "  - $line"
            done
        fi
        
        # Драйвер
        local gpu_driver
        gpu_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'vga\|3d\|display' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        print_data "Active GPU Driver: $gpu_driver"
        
        # NVIDIA проверка
        if echo "$gpu_info" | grep -qi nvidia; then
            if lsmod 2>/dev/null | grep -q nvidia; then
                print_data "NVIDIA driver: LOADED"
            else
                add_warning "NVIDIA GPU detected but driver not loaded"
                print_data "NVIDIA driver: NOT LOADED"
            fi
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: lspci]"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: NETWORK
#-------------------------------------------------------------------------------
scan_network() {
    print_section_header "NETWORK_INFO"
    
    print_subsection "INTERFACES"
    local iface_info
    iface_info="$(ip -br addr 2>/dev/null || ip addr 2>/dev/null | grep -E '^[0-9]+:|inet ')"
    if [[ -n "$iface_info" ]]; then
        echo "$iface_info" | head -10
    else
        print_data "Network interfaces: N/A"
    fi
    
    print_subsection "DNS_CONFIG"
    if [[ -f /etc/resolv.conf ]]; then
        local dns_servers
        dns_servers="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
        print_data "DNS Servers: $dns_servers"
    fi
    
    print_subsection "LISTENING_PORTS"
    if check_tool ss; then
        local listen_ports
        listen_ports="$(ss -tuln 2>/dev/null | head -10)"
        echo "$listen_ports"
    elif check_tool netstat; then
        local listen_ports
        listen_ports="$(netstat -tuln 2>/dev/null | head -10)"
        echo "$listen_ports"
    else
        print_status "SKIPPED [TOOL_MISSING: ss/netstat]"
    fi
    
    print_subsection "NETWORK_DRIVERS"
    if check_tool lspci; then
        local wifi_driver eth_driver
        wifi_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'wireless\|network' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        eth_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'ethernet' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        print_data "WiFi Driver: $wifi_driver"
        print_data "Ethernet Driver: $eth_driver"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: KERNEL
#-------------------------------------------------------------------------------
scan_kernel() {
    print_section_header "KERNEL_INFO"
    
    local kernel_ver
    kernel_ver="$(uname -r)"
    print_data "Kernel Version: $kernel_ver"
    
    local uptime_info
    uptime_info="$(uptime -p 2>/dev/null || uptime)"
    print_data "Uptime: $uptime_info"
    
    print_subsection "LOADED_MODULES"
    local modules_count
    modules_count="$(wc -l < /proc/modules 2>/dev/null || echo 0)"
    print_data "Loaded Modules: $modules_count"
    
    # Проприетарные модули
    local proprietary
    proprietary="$(lsmod 2>/dev/null | grep -iE 'nvidia|fglrx|broadcom|wl|vbox|virtualbox|vmware|akmod' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$proprietary" ]]; then
        print_data "Proprietary Modules: $proprietary"
        add_info "Обнаружены проприетарные драйверы: $proprietary"
    fi
    
    print_subsection "DKMS_STATUS"
    if check_tool dkms; then
        local dkms_status
        dkms_status="$(safe_sudo_cmd 'dkms status' 2>/dev/null)"
        if [[ "$dkms_status" != "[NEEDS_ROOT]" && -n "$dkms_status" ]]; then
            echo "$dkms_status"
            if echo "$dkms_status" | grep -qi "error\|mismatch"; then
                add_warning "DKMS version mismatch or errors | Проверьте совместимость модулей"
                print_issues "DKMS errors detected"
            fi
        else
            print_status "SKIPPED [NEEDS_ROOT or DKMS not installed]"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: dkms]"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: SERVICES
#-------------------------------------------------------------------------------
scan_services() {
    print_section_header "SERVICES_AND_PACKAGES"
    
    print_subsection "SYSTEMD_SERVICES"
    if check_tool systemctl; then
        local failed_services
        failed_services="$(systemctl --failed 2>/dev/null | grep -E 'failed' | head -5)"
        if [[ -n "$failed_services" ]]; then
            print_issues "Failed services detected"
            echo "$failed_services"
            add_warning "Обнаружены упавшие службы | Проверьте: systemctl --failed"
        else
            print_data "No failed systemd services"
        fi
        
        local running_count
        running_count="$(systemctl list-units --type=service --state=running 2>/dev/null | wc -l)"
        print_data "Running Services: $running_count"
    else
        print_status "SKIPPED [TOOL_MISSING: systemctl]"
    fi
    
    print_subsection "INSTALLED_PACKAGES"
    local pkg_count
    case "$PKG_MANAGER" in
        apt)
            pkg_count="$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 0)"
            ;;
        dnf|yum)
            pkg_count="$(rpm -qa 2>/dev/null | wc -l || echo 0)"
            ;;
        pacman)
            pkg_count="$(pacman -Q 2>/dev/null | wc -l || echo 0)"
            ;;
        zypper)
            pkg_count="$(rpm -qa 2>/dev/null | wc -l || echo 0)"
            ;;
        *)
            pkg_count="unknown"
            ;;
    esac
    print_data "Installed Packages: $pkg_count"
    
    print_subsection "UPDATABLE_PACKAGES"
    case "$PKG_MANAGER" in
        apt)
            local updates
            updates="$(apt list --upgradable 2>/dev/null | grep -c '/' || echo 0)"
            print_data "Available Updates: $updates"
            if [[ "$updates" -gt 50 ]]; then
                add_info "Большое количество обновлений: $updates | Рекомендуется обновить систему"
            fi
            ;;
        dnf|yum)
            local updates
            updates="$(dnf check-update 2>/dev/null | grep -c '.' || echo 0)"
            print_data "Available Updates: ~$updates"
            ;;
        pacman)
            local updates
            updates="$(pacman -Qu 2>/dev/null | wc -l || echo 0)"
            print_data "Available Updates: $updates"
            ;;
        *)
            print_data "Update check: Package manager not supported"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: USERS
#-------------------------------------------------------------------------------
scan_users() {
    print_section_header "USERS_AND_GROUPS"
    
    print_subsection "USER_ACCOUNTS"
    local user_list
    user_list="$(cut -d: -f1 /etc/passwd 2>/dev/null | grep -vE '^(root|nobody|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|_apt|systemd-|messagebus|uuidd|rtkit|cups|pulse|avahi|colord|geoclue|gdm|lightdm)' | head -10)"
    if [[ -n "$user_list" ]]; then
        echo "$user_list"
    else
        print_data "No additional users found"
    fi
    
    print_subsection "SUDO_USERS"
    local sudo_users
    sudo_users="$(grep -E '^([^#].*:.*:.*:.*:.*:.*:.*(/bin/bash|/bin/sh|/bin/zsh)$)' /etc/passwd 2>/dev/null | cut -d: -f1)"
    if [[ -n "$sudo_users" ]]; then
        echo "$sudo_users" | head -5
    fi
    
    print_subsection "ROOT_LOGIN"
    if grep -q '^root:' /etc/shadow 2>/dev/null; then
        local root_pass_status
        root_pass_status="$(grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)"
        if [[ "$root_pass_status" == "!" || "$root_pass_status" == "*" ]]; then
            print_data "Root password: DISABLED"
        else
            add_warning "Root password is SET | Consider using sudo instead"
            print_data "Root password: ENABLED"
        fi
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: SECURITY
#-------------------------------------------------------------------------------
scan_security() {
    print_section_header "SECURITY_INFO"
    
    print_subsection "FIREWALL_STATUS"
    if check_tool ufw; then
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | head -1)"
        print_data "UFW: $ufw_status"
    elif check_tool firewall-cmd; then
        local fw_status
        fw_status="$(firewall-cmd --state 2>/dev/null)"
        print_data "Firewalld: $fw_status"
    elif check_tool iptables; then
        local ipt_rules
        ipt_rules="$(iptables -L -n 2>/dev/null | wc -l)"
        print_data "iptables rules: $ipt_rules"
    else
        print_data "Firewall: Status unknown"
    fi
    
    print_subsection "SSH_CONFIG"
    if [[ -f /etc/ssh/sshd_config ]]; then
        local permit_root
        permit_root="$(grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 'not set')"
        local pass_auth
        pass_auth="$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 'not set')"
        print_data "PermitRootLogin: $permit_root"
        print_data "PasswordAuthentication: $pass_auth"
        
        if [[ "$permit_root" == "yes" ]]; then
            add_warning "SSH PermitRootLogin enabled | Рекомендуется отключить"
        fi
    else
        print_data "SSH config: Not found"
    fi
    
    print_subsection "FAIL2BAN"
    if check_tool fail2ban-client; then
        local f2b_status
        f2b_status="$(fail2ban-client status 2>/dev/null | head -1)"
        print_data "Fail2Ban: $f2b_status"
    else
        print_data "Fail2Ban: Not installed"
    fi
    
    print_subsection "APPARMOR_SELINUX"
    if check_tool aa-status; then
        local aa_status
        aa_status="$(aa-status 2>/dev/null | head -3)"
        echo "$aa_status"
    elif [[ -f /etc/selinux/config ]]; then
        local selinux_mode
        selinux_mode="$(grep SELINUX /etc/selinux/config 2>/dev/null | grep -v '^#' | head -1)"
        print_data "SELinux: $selinux_mode"
    else
        print_data "Mandatory Access Control: None detected"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: BATTERY
#-------------------------------------------------------------------------------
scan_battery() {
    print_section_header "BATTERY_STATUS"
    
    if [[ -d /sys/class/power_supply ]]; then
        local battery_found=false
        for bat in /sys/class/power_supply/BAT*; do
            if [[ -d "$bat" ]]; then
                battery_found=true
                local capacity full_design current status wear
                
                capacity="$(cat "$bat/capacity" 2>/dev/null || echo 'N/A')"
                full_design="$(cat "$bat/energy_full_design" 2>/dev/null || cat "$bat/charge_full_design" 2>/dev/null || echo 'N/A')"
                current="$(cat "$bat/energy_full" 2>/dev/null || cat "$bat/charge_full" 2>/dev/null || echo 'N/A')"
                status="$(cat "$bat/status" 2>/dev/null || echo 'N/A')"
                
                wear="N/A"
                if [[ "$full_design" != "N/A" && "$current" != "N/A" && "$full_design" -gt 0 ]] 2>/dev/null; then
                    wear="$(( (current * 100) / full_design ))%"
                    if [[ "${wear%\%}" -lt 80 ]] 2>/dev/null; then
                        add_warning "Износ батареи: $wear | Рассмотрите калибровку или замену"
                    fi
                fi
                
                print_data "Capacity: $capacity%"
                print_data "Wear Level: $wear"
                print_data "Status: $status"
            fi
        done
        
        if [[ "$battery_found" == false ]]; then
            print_data "No battery detected (desktop system?)"
        fi
    else
        print_status "SKIPPED [No power_supply class]"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: THERMAL
#-------------------------------------------------------------------------------
scan_thermal() {
    print_section_header "THERMAL_SENSORS"
    
    local thermal_zones=0
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            thermal_zones=$((thermal_zones + 1))
            local temp_val temp_c zone_name zone_type
            
            temp_val="$(cat "$zone" 2>/dev/null)"
            temp_c=$((temp_val / 1000))
            zone_type="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Zone$thermal_zones")"
            
            if [[ $temp_c -gt 85 ]]; then
                add_warning "Высокая температура $zone_type: ${temp_c}°C | Проверьте охлаждение"
                print_data "$zone_type: ${temp_c}°C [HIGH]"
            else
                print_data "$zone_type: ${temp_c}°C"
            fi
        fi
    done
    
    if [[ $thermal_zones -eq 0 ]]; then
        print_data "No thermal sensors found"
    fi
    
    print_subsection "FAN_SPEEDS"
    if check_tool sensors; then
        local fan_info
        fan_info="$(sensors 2>/dev/null | grep -i 'fan' | head -5)"
        if [[ -n "$fan_info" ]]; then
            echo "$fan_info"
        else
            print_data "Fan speeds: N/A"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: sensors]"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: LOGS
#-------------------------------------------------------------------------------
scan_logs() {
    print_section_header "SYSTEM_LOGS"
    
    print_subsection "JOURNAL_ERRORS"
    if check_tool journalctl; then
        local errors
        errors="$(journalctl -p err -xb 2>/dev/null | tail -5)"
        if [[ -n "$errors" ]]; then
            print_issues "Recent errors in journal"
            print_raw_logs "$errors"
        else
            print_data "No recent critical errors in journal"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: journalctl]"
    fi
    
    print_subsection "DMESG_ERRORS"
    local dmesg_errors
    dmesg_errors="$(dmesg 2>/dev/null | grep -iE 'error|fail|critical' | tail -5)"
    if [[ -n "$dmesg_errors" ]]; then
        print_issues "Errors in dmesg"
        print_raw_logs "$dmesg_errors"
    else
        print_data "No critical errors in dmesg"
    fi
    
    print_subsection "PCIE_ACPI_ERRORS"
    local pcie_errors
    pcie_errors="$(dmesg 2>/dev/null | grep -iE 'aer|pci bus error|acpi error' | tail -5)"
    if [[ -n "$pcie_errors" ]]; then
        print_issues "PCIe/ACPI errors detected"
        print_raw_logs "$pcie_errors"
        add_warning "PCIe/ACPI ошибки в dmesg | Проверьте соединения и прошивку"
    else
        print_data "No PCIe/ACPI errors detected"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: CONTAINERS
#-------------------------------------------------------------------------------
scan_containers() {
    print_section_header "CONTAINER_SERVICES"
    
    print_subsection "DOCKER_STATUS"
    if check_tool docker; then
        local docker_status
        docker_status="$(docker info 2>/dev/null | head -5)"
        if [[ -n "$docker_status" ]]; then
            echo "$docker_status"
            local container_count
            container_count="$(docker ps -a 2>/dev/null | wc -l)"
            print_data "Total Containers: $((container_count - 1))"
        else
            print_data "Docker: Installed but not running"
        fi
    else
        print_data "Docker: Not installed"
    fi
    
    print_subsection "PODMAN_STATUS"
    if check_tool podman; then
        local podman_version
        podman_version="$(podman --version 2>/dev/null)"
        print_data "$podman_version"
    else
        print_data "Podman: Not installed"
    fi
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: STRESS TESTS (LEVEL 4)
#-------------------------------------------------------------------------------
run_stress_tests() {
    print_section_header "STRESS_TESTS"
    
    echo -e "${YELLOW}⚠️  Запуск стресс-тестов...${NC}" >&2
    
    print_subsection "CPU_STRESS"
    if check_tool stress-ng; then
        log_info "Запуск CPU stress test (10 сек)..."
        safe_cmd "stress-ng --cpu 2 --timeout 10s" 2>&1 | head -5
        log_success "CPU stress test completed"
    else
        print_status "SKIPPED [TOOL_MISSING: stress-ng]"
    fi
    
    print_subsection "MEMORY_STRESS"
    if check_tool stress-ng; then
        log_info "Запуск memory stress test (10 сек)..."
        safe_cmd "stress-ng --vm 1 --vm-bytes 256M --timeout 10s" 2>&1 | head -5
        log_success "Memory stress test completed"
    fi
    
    print_subsection "IO_STRESS"
    if check_tool fio; then
        log_info "Запуск I/O stress test (10 сек)..."
        safe_cmd "fio --name=test --ioengine=sync --rw=randread --bs=4k --size=64M --runtime=10 --time_based" 2>&1 | head -10
        log_success "I/O stress test completed"
    else
        print_status "SKIPPED [TOOL_MISSING: fio]"
    fi
}

#-------------------------------------------------------------------------------
# ГЕНЕРАЦИЯ AI SUMMARY
#-------------------------------------------------------------------------------
generate_ai_summary() {
    {
        echo ""
        echo "========================================"
        echo "AI-PARSEABLE SUMMARY"
        echo "========================================"
        echo ""
        
        echo "## CRITICAL_ISSUES"
        if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
            for issue in "${CRITICAL_ISSUES[@]}"; do
                echo "[CRITICAL] $issue"
            done
        else
            echo "None"
        fi
        echo ""
        
        echo "## WARNING_ISSUES"
        if [[ ${#WARNING_ISSUES[@]} -gt 0 ]]; then
            for issue in "${WARNING_ISSUES[@]}"; do
                echo "[WARNING] $issue"
            done
        else
            echo "None"
        fi
        echo ""
        
        echo "## INFO_ISSUES"
        if [[ ${#INFO_ISSUES[@]} -gt 0 ]]; then
            for issue in "${INFO_ISSUES[@]}"; do
                echo "[INFO] $issue"
            done
        else
            echo "None"
        fi
        echo ""
        
        echo "## STRICT_PROHIBITIONS"
        for prohibition in "${UNIVERSAL_PROHIBITIONS[@]}"; do
            echo "[PROHIBITED] $prohibition"
        done
        if [[ ${#STRICT_PROHIBITIONS[@]} -gt 0 ]]; then
            for prohibition in "${STRICT_PROHIBITIONS[@]}"; do
                echo "[PROHIBITED] $prohibition"
            done
        fi
        echo ""
        
        echo "## RECOMMENDATIONS"
        if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
            echo "1. Немедленно устраните критические проблемы"
            echo "2. Сделайте backup важных данных"
            echo "3. Проверьте логи для детальной диагностики"
        fi
        if [[ ${#WARNING_ISSUES[@]} -gt 0 ]]; then
            echo "- Обратите внимание на предупреждения"
            echo "- Планируйте профилактические работы"
        fi
        echo ""
        echo "========================================"
        echo "END OF REPORT"
        echo "========================================"
    } >> "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# ПОКАЗ ПОМОЩИ
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
Использование: $SCRIPT_NAME [ОПЦИИ]

Опции:
  -l, --level LEVEL     Уровень сканирования (1-4, по умолчанию: меню)
                        1 = МИНИМАЛЬНЫЙ (базовое железо, логи, место на диске)
                        2 = СРЕДНИЙ (службы, пакеты, SMART, сеть)
                        3 = ТОТАЛЬНЫЙ (полная диагностика, безопасность)
                        4 = ПРОФИЛИРОВАНИЕ (стресс-тесты, тяжёлые метрики)
  -a, --auto-install    Автоматически устанавливать отсутствующие пакеты
  -o, --output FILE     Указать путь к файлу отчёта
  -h, --help            Показать эту справку

Примеры:
  $SCRIPT_NAME                     # Запустить с меню выбора
  $SCRIPT_NAME -l 2                # Запустить средний скан (уровень 2)
  $SCRIPT_NAME -l 3 -a             # Тотальный скан с авто-установкой
  $SCRIPT_NAME -l 4                # Полное профилирование со стресс-тестами

Примечание: Уровень 4 требует подтверждения из-за стресс-тестов.
EOF
}

#-------------------------------------------------------------------------------
# ОБРАБОТКА АРГУМЕНТОВ
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--level)
                SCAN_LEVEL="$2"
                if [[ ! $SCAN_LEVEL =~ ^[1-4]$ ]]; then
                    echo "Ошибка: Уровень должен быть 1-4" >&2
                    exit 1
                fi
                shift 2
                ;;
            -a|--auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Неизвестная опция: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ФУНКЦИЯ
#-------------------------------------------------------------------------------
main() {
    show_banner
    parse_args "$@"
    
    # Если уровень не указан, показываем меню
    if [[ $SCAN_LEVEL -eq 0 ]]; then
        show_scan_menu
    fi
    
    # Подготовка вывода
    if [[ -z "$OUTPUT_FILE" ]]; then
        prepare_output_dir
    fi
    
    log_info "Запуск Deep System Scan v${VERSION}"
    log_info "Уровень сканирования: ${SCAN_LEVEL}"
    log_info "Файл отчёта: ${OUTPUT_FILE}"
    echo ""
    
    # Инициализация отчёта
    write_report_header
    
    # Проверка и установка инструментов
    check_and_install_tools
    
    log_section "Запуск диагностических проверок"
    
    # Уровень 1: МИНИМАЛЬНЫЙ
    scan_cpu
    scan_ram
    scan_storage
    scan_kernel
    
    if [[ $SCAN_LEVEL -ge $LEVEL_MEDIUM ]]; then
        # Уровень 2: СРЕДНИЙ
        scan_gpu
        scan_battery
        scan_thermal
        scan_network
        scan_services
        scan_users
    fi
    
    if [[ $SCAN_LEVEL -ge $LEVEL_TOTAL ]]; then
        # Уровень 3: ТОТАЛЬНЫЙ
        scan_security
        scan_logs
        scan_containers
    fi
    
    if [[ $SCAN_LEVEL -ge $LEVEL_PROFILING ]]; then
        # Уровень 4: ПРОФИЛИРОВАНИЕ
        run_stress_tests
    fi
    
    # Генерация AI summary
    generate_ai_summary
    
    # Финальный вывод
    echo "" >&2
    log_success "Сканирование завершено успешно!"
    log_info "Отчёт сохранён: ${OUTPUT_FILE}"
    echo "" >&2
    
    # Краткая сводка
    echo "=== СВОДКА СКАНИРОВАНИЯ ===" >&2
    echo "Критических проблем: ${#CRITICAL_ISSUES[@]}" >&2
    echo "Предупреждений: ${#WARNING_ISSUES[@]}" >&2
    echo "Информационных: ${#INFO_ISSUES[@]}" >&2
    echo "" >&2
    
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}КРИТИЧЕСКИЕ ПРОБЛЕМЫ:${NC}" >&2
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "  • $issue" >&2
        done
        echo "" >&2
    fi
    
    if [[ ${#WARNING_ISSUES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}ПРЕДУПРЕЖДЕНИЯ:${NC}" >&2
        for issue in "${WARNING_ISSUES[@]}"; do
            echo "  • $issue" >&2
        done
        echo "" >&2
    fi
    
    echo "Полный отчёт: ${OUTPUT_FILE}" >&2
    echo "" >&2
}

# Запуск основной функции

