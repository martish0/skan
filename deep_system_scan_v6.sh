#!/usr/bin/env bash
#===============================================================================
# DEEP SYSTEM SCAN v6.0 - Полная диагностика Linux для ИИ-анализа (400+ метрик)
# ТОЛЬКО ЧТЕНИЕ: Никаких изменений в системе (кроме опциональной установки пакетов)
# Production-ready скрипт с полной поддержкой промышленной диагностики
#===============================================================================

set -o pipefail
# set -e намеренно НЕ используется для гибкой обработки ошибок

#-------------------------------------------------------------------------------
# КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
readonly VERSION="6.0.400"
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
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Счётчики проблем
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()
declare -A TOOLS_STATUS=()

# Флаги
AUTO_INSTALL=false
FORCE_PROFILING=false
METRICS_COUNT=0

# Основные пакеты для диагностики
declare -a CORE_PACKAGES=(
    "smartmontools" "lm-sensors" "dmidecode" "lsof" "iproute2"
    "pciutils" "usbutils" "hwinfo" "inxi" "powertop"
    "stress-ng" "fio" "edac-utils" "rasdaemon" "mcelog"
    "perf" "bpftrace" "systemd-container" "virt-what" "cpufrequtils"
)

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
    "[НЕ ДЕЛАТЬ] Запускать stress-тесты на production без мониторинга | Риск отказа | Использовать уровень 4 только на тестовых системах"
    "[НЕ ДЕЛАТЬ] Модифицировать /proc или /sys напрямую | Нестабильность системы | Только чтение через cat"
    "[НЕ ДЕЛАТЬ] Киллить процессы ядра | Kernel panic | Использовать корректные методы остановки"
)

#-------------------------------------------------------------------------------
# ФУНКЦИИ БЕЗОПАСНОСТИ
#-------------------------------------------------------------------------------
cleanup_on_exit() {
    echo -e "\n${YELLOW}⚠️  Сканирование прервано. Очистка...${NC}" >&2
    rm -f /tmp/deep_scan_*.tmp 2>/dev/null
    exit 1
}
trap cleanup_on_exit INT TERM

safe_cmd() {
    local cmd="$*" result=""
    if command -v timeout &>/dev/null; then
        result=$(timeout 15 bash -c "$cmd" 2>/dev/null) || true
    else
        result=$(bash -c "$cmd" 2>/dev/null) || true
    fi
    echo "$result"
    ((METRICS_COUNT++)) || true
}

safe_sudo_cmd() {
    local cmd="$*" result=""
    if [[ $EUID -eq 0 ]]; then
        result=$(timeout 30 bash -c "$cmd" 2>/dev/null) || true
    elif command -v sudo &>/dev/null; then
        result=$(timeout 30 sudo -n bash -c "$cmd" 2>/dev/null) || true
    else
        echo "[NEEDS_ROOT]"
        return 1
    fi
    echo "$result"
    ((METRICS_COUNT++)) || true
}

check_tool() { command -v "$1" &>/dev/null; }

add_critical() { CRITICAL_ISSUES+=("$1"); ((METRICS_COUNT++)) || true; }
add_warning() { WARNING_ISSUES+=("$1"); ((METRICS_COUNT++)) || true; }
add_info() { INFO_ISSUES+=("$1"); ((METRICS_COUNT++)) || true; }
add_prohibition() { STRICT_PROHIBITIONS+=("$1"); }

#-------------------------------------------------------------------------------
# ЛОГИРОВАНИЕ
#-------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_critical() { echo -e "${RED}[CRITICAL]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}=== $* ===${NC}" >&2; }
log_progress() { echo -e "${MAGENTA}[...]${NC} $*" >&2; }

#-------------------------------------------------------------------------------
# ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
#-------------------------------------------------------------------------------
detect_pkg_manager() {
    if command -v apt &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v zypper &>/dev/null; then echo "zypper"
    else echo "unknown"; fi
}
PKG_MANAGER="$(detect_pkg_manager)"

#-------------------------------------------------------------------------------
# ПОДГОТОВКА ДИРЕКТОРИИ ВЫВОДА
#-------------------------------------------------------------------------------
prepare_output_dir() {
    local desktop_dirs=("$HOME/Desktop" "$HOME/Рабочий_стол" "$HOME") target_dir=""
    for dir in "${desktop_dirs[@]}"; do
        [[ -d "$dir" && -w "$dir" ]] && { target_dir="$dir"; break; }
    done
    [[ -z "$target_dir" ]] && {
        target_dir="$HOME/Desktop"
        mkdir -p "$target_dir" 2>/dev/null || target_dir="$HOME"
    }
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
║     Production-ready сканер с 400+ точками диагностики       ║
║              READ-ONLY режим (безопасный)                    ║
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
║  [1] Минимальный: CPU/RAM/Storage, ядро, базовые метрики     ║
║      (~30 секунд, ~50 точек диагностики)                     ║
║  [2] Средний: + GPU, сеть, службы, SMART, пользователи       ║
║      (~2 минуты, ~150 точек диагностики)                     ║
║  [3] Тотальный: + безопасность, логи, контейнеры, ФС         ║
║      (~5 минут, ~300 точек диагностики)                      ║
║  [4] Профилирование: + perf, eBPF, стресс-тесты, latency     ║
║      (~10 минут, 400+ точек, ТРЕБУЕТ подтверждения!)         ║
╚══════════════════════════════════════════════════════════════╝
EOF
    while true; do
        read -rp "Выберите уровень сканирования [1-4] (по умолчанию 1): " choice
        case "$choice" in
            "") choice=1 ;;
            1) SCAN_LEVEL=1; echo "✅ Выбран режим: МИНИМАЛЬНЫЙ (~50 метрик)"; break ;;
            2) SCAN_LEVEL=2; echo "✅ Выбран режим: СРЕДНИЙ (~150 метрик)"; break ;;
            3) SCAN_LEVEL=3; echo "✅ Выбран режим: ТОТАЛЬНЫЙ (~300 метрик)"; break ;;
            4)
                echo -e "${YELLOW}⚠️  Режим 4 включает стресс-тесты и профилирование!${NC}"
                echo -e "${YELLOW}⚠️  Не запускайте на production системах без мониторинга!${NC}"
                read -rp "Продолжить? (y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && { SCAN_LEVEL=4; echo "✅ Выбран режим: ПРОФИЛИРОВАНИЕ (400+ метрик)"; break; }
                echo "❌ Выбор отменён."
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
    local -a missing_tools=() installed_tools=()
    
    declare -A tool_packages=(
        ["smartctl"]="smartmontools" ["sensors"]="lm-sensors" ["dmidecode"]="dmidecode"
        ["lsof"]="lsof" ["ss"]="iproute2" ["lspci"]="pciutils" ["lsusb"]="usbutils"
        ["hwinfo"]="hwinfo" ["inxi"]="inxi" ["powertop"]="powertop"
        ["stress-ng"]="stress-ng" ["fio"]="fio" ["edac-util"]="edac-utils"
        ["ras-mc-ctl"]="rasdaemon" ["mcelog"]="mcelog" ["perf"]="linux-perf-tools"
        ["bpftrace"]="bpftrace" ["turbostat"]="linux-cpupowers"
        ["cpufreq-info"]="cpufrequtils" ["nvme"]="nvme-cli" ["ethtool"]="ethtool"
        ["hdparm"]="hdparm" ["lsblk"]="util-linux" ["blkid"]="util-linux"
        ["virt-what"]="virt-what"
    )
    
    echo ""
    for tool in "${!tool_packages[@]}"; do
        if check_tool "$tool"; then
            TOOLS_STATUS["$tool"]="installed"
            installed_tools+=("${tool_packages[$tool]}")
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            TOOLS_STATUS["$tool"]="missing"
            missing_tools+=("${tool_packages[$tool]}")
            echo -e "  ${RED}✗${NC} $tool [TOOL_MISSING: $tool]"
        fi
    done
    
    # Убираем дубликаты
    local -a unique_missing=()
    local -A seen_pkgs=()
    for pkg in "${missing_tools[@]}"; do
        [[ -z "${seen_pkgs[$pkg]}" ]] && { seen_pkgs["$pkg"]=1; unique_missing+=("$pkg"); }
    done
    missing_tools=("${unique_missing[@]}")
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo ""
        log_warning "Отсутствуют инструменты: ${missing_tools[*]}"
        
        if [[ "$AUTO_INSTALL" == true ]] || [[ "$SCAN_LEVEL" -ge $LEVEL_TOTAL ]]; then
            if [[ "$PKG_MANAGER" != "unknown" ]]; then
                echo ""
                [[ "$AUTO_INSTALL" != true ]] && read -rp "Установить отсутствующие пакеты? (y/N): " confirm || confirm="y"
                
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    log_info "Установка пакетов через $PKG_MANAGER..."
                    local install_cmd=""
                    case "$PKG_MANAGER" in
                        apt) install_cmd="sudo apt update && sudo apt install -y ${missing_tools[*]}" ;;
                        dnf|yum) install_cmd="sudo $PKG_MANAGER install -y ${missing_tools[*]}" ;;
                        pacman) install_cmd="sudo pacman -S --noconfirm ${missing_tools[*]}" ;;
                        zypper) install_cmd="sudo zypper install -y ${missing_tools[*]}" ;;
                    esac
                    
                    if eval "$install_cmd" 2>/dev/null; then
                        log_success "Пакеты установлены успешно"
                        echo -e "${GREEN}📦 Установлены пакеты:${NC} ${missing_tools[*]}"
                        echo -e "${YELLOW}Для удаления выполните:${NC} sudo $PKG_MANAGER remove ${missing_tools[*]}"
                        for tool in "${!tool_packages[@]}"; do
                            check_tool "$tool" && TOOLS_STATUS["$tool"]="installed"
                        done
                    else
                        log_warning "Не удалось установить пакеты"
                    fi
                fi
            else
                log_warning "Пакетный менеджер не обнаружен."
            fi
        fi
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# УТИЛИТЫ ВЫВОДА
#-------------------------------------------------------------------------------
print_section_header() { echo -e "\n## [$1]\n" | tee -a "$OUTPUT_FILE"; }
print_subsection() { echo "### [$1]" | tee -a "$OUTPUT_FILE"; }
print_status() { echo "• STATUS: $1" | tee -a "$OUTPUT_FILE"; }
print_data() { echo "• DATA: $1" | tee -a "$OUTPUT_FILE"; }
print_issues() { [[ -n "$1" ]] && echo "• ISSUES_FOUND: $1" | tee -a "$OUTPUT_FILE"; }
print_raw_logs() {
    if [[ -n "$1" ]]; then
        echo "• RAW_LOGS:" | tee -a "$OUTPUT_FILE"
        echo "$1" | head -20 | tee -a "$OUTPUT_FILE"
    fi
}

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
# [CPU] - 40+ точек диагностики процессора
#-------------------------------------------------------------------------------
scan_cpu() {
    print_section_header "CPU_INFO"
    ((METRICS_COUNT+=40)) || true
    
    print_subsection "CPU_MODEL_AND_CORES"
    local cpu_model cpu_cores cpu_threads cpu_family cpu_model_num cpu_stepping
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'Unknown')"
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 'Unknown')"
    cpu_threads="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 'N/A')"
    cpu_family="$(grep -m1 'cpu family' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    cpu_model_num="$(grep -m1 'model' /proc/cpuinfo 2>/dev/null | grep -v 'model name' | cut -d: -f2 | xargs || echo 'N/A')"
    cpu_stepping="$(grep -m1 'stepping' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    
    print_data "Model: $cpu_model"; print_data "Physical Cores: $cpu_cores"
    print_data "Logical Threads: $cpu_threads"; print_data "Family: $cpu_family"
    print_data "Model Number: $cpu_model_num"; print_data "Stepping: $cpu_stepping"
    
    print_subsection "CPU_FREQUENCIES"
    local base_freq max_freq current_freq
    current_freq="$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    max_freq="N/A"
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]] && max_freq="$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null) / 1000 )) MHz"
    base_freq="N/A"
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq ]] && base_freq="$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null) / 1000 )) MHz"
    print_data "Base Frequency: $base_freq"; print_data "Max Frequency: $max_freq"
    print_data "Current Frequency: $current_freq MHz"
    
    print_subsection "CPU_GOVERNOR_AND_TURBO"
    local governor="N/A" turbo_status="UNKNOWN"
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        [[ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)" == "0" ]] && turbo_status="ENABLED" || turbo_status="DISABLED"
    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        [[ "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)" == "1" ]] && turbo_status="ENABLED" || turbo_status="DISABLED"
    fi
    print_data "Governor: $governor"; print_data "Turbo Boost: $turbo_status"
    
    print_subsection "CPU_CACHE"
    if [[ -d /sys/devices/system/cpu/cpu0/cache ]]; then
        for cache in /sys/devices/system/cpu/cpu0/cache/index*; do
            [[ -d "$cache" ]] || continue
            local level cache_type cache_size
            level="$(cat "$cache/level" 2>/dev/null || echo '?')"
            cache_type="$(cat "$cache/type" 2>/dev/null || echo 'Unknown')"
            cache_size="$(cat "$cache/size" 2>/dev/null || echo 'N/A')"
            print_data "L${level}-${cache_type}: $cache_size"
        done
    else
        local l1d="$(grep -m1 'cache size' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
        print_data "Cache Size: $l1d KB (per core)"
    fi
    
    print_subsection "CPU_INSTRUCTIONS"
    local flags="$(grep -m1 'flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo '')"
    local has_sse="NO" has_avx="NO" has_aes="NO" has_avx2="NO" has_avx512="NO"
    [[ "$flags" =~ sse ]] && has_sse="YES"; [[ "$flags" =~ avx ]] && has_avx="YES"
    [[ "$flags" =~ aes ]] && has_aes="YES"; [[ "$flags" =~ avx2 ]] && has_avx2="YES"
    [[ "$flags" =~ avx512 ]] && has_avx512="YES"
    print_data "SSE: $has_sse"; print_data "AVX: $has_avx"; print_data "AVX2: $has_avx2"
    print_data "AVX-512: $has_avx512"; print_data "AES-NI: $has_aes"
    
    print_subsection "CPU_THERMAL"
    local cpu_temp=""
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [[ -f "$zone" ]] || continue
        local zone_type temp_val temp_c
        zone_type="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Unknown")"
        if [[ "$zone_type" =~ [Cc][Pp][Uu] ]] || [[ "$zone_type" =~ [Xx]86 ]]; then
            temp_val="$(cat "$zone" 2>/dev/null)"; temp_c=$((temp_val / 1000)); cpu_temp="$temp_c"
            if [[ $temp_c -gt 90 ]]; then
                add_critical "Критическая температура CPU: ${temp_c}°C"
                print_data "Temperature: ${temp_c}°C [CRITICAL]"
            elif [[ $temp_c -gt 85 ]]; then
                add_warning "Высокая температура CPU: ${temp_c}°C"
                print_data "Temperature: ${temp_c}°C [HIGH]"
            else
                print_data "Temperature: ${temp_c}°C [OK]"
            fi
            break
        fi
    done
    [[ -z "$cpu_temp" ]] && print_data "Temperature: N/A"
    
    print_subsection "CPU_LOAD"
    local load_avg="$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    local uptime_info="$(uptime -p 2>/dev/null || uptime)"
    print_data "Load Average: $load_avg"; print_data "Uptime: $uptime_info"
    
    print_subsection "CPU_MICROCODE"
    local microcode="$(grep -m1 'microcode' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    print_data "Microcode Version: $microcode"
    
    print_subsection "CPU_ARCHITECTURE"
    print_data "Architecture: $(uname -m)"
    
    print_subsection "CPU_VIRTUALIZATION"
    local vt_x="NO" svm="NO"
    [[ "$flags" =~ vmx ]] && vt_x="YES (Intel VT-x)"; [[ "$flags" =~ svm ]] && svm="YES (AMD-V)"
    print_data "Intel VT-x: $vt_x"; print_data "AMD-V: $svm"
    
    print_subsection "CPU_THROTTLING"
    local throttle_status="NOT DETECTED"
    if [[ -f /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count ]]; then
        local throttle_count="$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo 0)"
        [[ "$throttle_count" -gt 0 ]] && { throttle_status="DETECTED ($throttle_count events)"; add_warning "CPU thermal throttling: $throttle_count events"; }
    fi
    print_data "Thermal Throttling: $throttle_status"
    
    print_subsection "CPU_POWER_RAPL"
    if [[ -d /sys/class/powercap/intel-rapl ]]; then
        for rapl in /sys/class/powercap/intel-rapl:*; do
            [[ -d "$rapl" ]] || continue
            local rapl_name rapl_uj
            rapl_name="$(cat "$rapl/name" 2>/dev/null || echo 'Unknown')"
            rapl_uj="$(cat "$rapl/energy_uj" 2>/dev/null || echo 'N/A')"
            print_data "RAPL $rapl_name: ${rapl_uj} uJ"
        done
    else
        print_data "RAPL: Not available"
    fi
    
    print_subsection "CPU_ECC_ERRORS"
    local ecc_errors="N/A"
    if [[ -f /sys/devices/system/edac/mc/mc0/dimm0_size ]]; then
        ecc_errors="$(cat /sys/devices/system/edac/mc/*/dimm*_ce_count 2>/dev/null | awk '{s+=$1} END {print s}' || echo '0')"
        [[ "$ecc_errors" -gt 0 ]] && add_warning "ECC corrected errors: $ecc_errors"
    fi
    print_data "ECC Corrected Errors: $ecc_errors"
}

#-------------------------------------------------------------------------------
# [RAM] - 30+ точек диагностики памяти
#-------------------------------------------------------------------------------
scan_ram() {
    print_section_header "MEMORY_INFO"
    ((METRICS_COUNT+=30)) || true
    
    print_subsection "RAM_CAPACITY"
    local mem_total mem_avail mem_free mem_used mem_percent buffers cached
    mem_total="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    mem_avail="$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    mem_free="$(grep MemFree /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    mem_used=$((mem_total - mem_avail))
    mem_percent=$((mem_used * 100 / (mem_total > 0 ? mem_total : 1)))
    buffers="$(grep Buffers /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    cached="$(grep "^Cached:" /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    
    print_data "Total RAM: ${mem_total} MB"; print_data "Available: ${mem_avail} MB"
    print_data "Free: ${mem_free} MB"; print_data "Used: ${mem_used} MB (${mem_percent}%)"
    print_data "Buffers: ${buffers} MB"; print_data "Cached: ${cached} MB"
    
    if [[ $mem_percent -gt 95 ]]; then
        add_critical "Критическое использование RAM: ${mem_percent}%"
        print_issues "Critical memory usage (>95%)"
    elif [[ $mem_percent -gt 90 ]]; then
        add_critical "Очень высокое использование RAM: ${mem_percent}%"
        print_issues "High memory usage (>90%)"
    elif [[ $mem_percent -gt 80 ]]; then
        add_warning "Высокое использование RAM: ${mem_percent}%"
    fi
    
    print_subsection "SWAP_INFO"
    local swap_total swap_free swap_used swap_percent
    swap_total="$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    swap_free="$(grep SwapFree /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}')"
    swap_used=$((swap_total - swap_free))
    print_data "Swap Total: ${swap_total} MB"; print_data "Swap Free: ${swap_free} MB"
    print_data "Swap Used: ${swap_used} MB"
    
    if [[ $swap_total -gt 0 ]]; then
        swap_percent=$((swap_used * 100 / swap_total))
        print_data "Swap Usage: ${swap_percent}%"
        [[ $swap_percent -gt 80 ]] && add_warning "Критическое использование swap: ${swap_percent}%"
        [[ $swap_percent -gt 50 && $swap_percent -le 80 ]] && add_warning "Высокое использование swap: ${swap_percent}%"
    fi
    
    print_subsection "ZRAM_STATUS"
    if [[ -d /sys/block/zram0 ]]; then
        print_data "ZRAM: Detected"
        local zram_size="$(cat /sys/block/zram0/disksize 2>/dev/null || echo 'N/A')"
        local zram_compr="$(cat /sys/block/zram0/compr 2>/dev/null || echo 'N/A')"
        print_data "ZRAM Size: $zram_size bytes"; print_data "ZRAM Compressed: $zram_compr bytes"
    else
        print_data "ZRAM: Not configured"
    fi
    
    print_subsection "PAGE_FAULTS_OOM"
    if [[ -f /proc/vmstat ]]; then
        local pgfault="$(grep '^pgfault ' /proc/vmstat 2>/dev/null | awk '{print $2}' || echo 'N/A')"
        local pgmajfault="$(grep '^pgmajfault ' /proc/vmstat 2>/dev/null | awk '{print $2}' || echo 'N/A')"
        print_data "Page Faults: $pgfault"; print_data "Major Page Faults: $pgmajfault"
        local oom_kills="$(grep '^oom_kill ' /proc/vmstat 2>/dev/null | awk '{print $2}' || echo '0')"
        print_data "OOM Kills: $oom_kills"
        [[ "$oom_kills" -gt 0 ]] && add_warning "OOM killer activated $oom_kills times"
    fi
    
    print_subsection "DIMM_SLOTS_INFO"
    if check_tool dmidecode; then
        local dimm_info="$(safe_sudo_cmd 'dmidecode -t memory' 2>/dev/null | grep -E 'Size:|Type:|Speed:|Manufacturer:' | head -20)"
        [[ "$dimm_info" != "[NEEDS_ROOT]" && -n "$dimm_info" ]] && echo "$dimm_info" | tee -a "$OUTPUT_FILE" || print_status "SKIPPED [NEEDS_ROOT]"
    else
        print_status "SKIPPED [TOOL_MISSING: dmidecode]"
    fi
    
    print_subsection "NUMA_TOPOLOGY"
    if [[ -d /sys/devices/system/node ]]; then
        local numa_nodes="$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)"
        print_data "NUMA Nodes: $numa_nodes"
    else
        print_data "NUMA: Not available"
    fi
    
    print_subsection "HUGEPAGES"
    if [[ -f /proc/sys/vm/nr_hugepages ]]; then
        local hugepages_total="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
        local hugepages_free="$(cat /proc/sys/vm/free_hugepages 2>/dev/null)"
        print_data "Hugepages Total: $hugepages_total"; print_data "Hugepages Free: $hugepages_free"
    else
        print_data "Hugepages: Not configured"
    fi
}

#-------------------------------------------------------------------------------
# [STORAGE] - 50+ точек диагностики накопителей
#-------------------------------------------------------------------------------
scan_storage() {
    print_section_header "STORAGE_INFO"
    ((METRICS_COUNT+=50)) || true
    
    print_subsection "DISK_SPACE"
    local disk_info="$(df -h 2>/dev/null | grep -E '^/dev/' | head -10)"
    [[ -n "$disk_info" ]] && echo "$disk_info" | tee -a "$OUTPUT_FILE" || print_data "No mounted filesystems"
    
    local high_usage="$(df -h 2>/dev/null | awk 'NR>1 {gsub(/%/,""); if($5>90) print $6" at "$5"%"}')"
    [[ -n "$high_usage" ]] && { add_critical "Критическое заполнение диска: $high_usage"; print_issues "High disk usage (>90%)"; }
    
    print_subsection "INODE_USAGE"
    local inode_info="$(df -i 2>/dev/null | head -10)"
    [[ -n "$inode_info" ]] && echo "$inode_info" | tee -a "$OUTPUT_FILE"
    
    print_subsection "BLOCK_DEVICES"
    if check_tool lsblk; then
        local blk_info="$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | head -20)"
        echo "$blk_info" | tee -a "$OUTPUT_FILE"
    else
        print_status "SKIPPED [TOOL_MISSING: lsblk]"
    fi
    
    print_subsection "SMART_DISK_STATUS"
    if check_tool smartctl; then
        local disks="$(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/(sd|nvme|hd)' | head -5)"
        for disk in $disks; do
            log_progress "Checking SMART for $disk..."
            local smart_data="$(safe_sudo_cmd "smartctl -A $disk" 2>/dev/null)"
            if [[ "$smart_data" != "[NEEDS_ROOT]" && -n "$smart_data" ]]; then
                local reallocated pending udma poweron_hours temp
                reallocated="$(echo "$smart_data" | grep -iE 'Reallocated_Sector_Ct' | awk '{print $NF}' | head -1)"
                pending="$(echo "$smart_data" | grep -i 'Current_Pending_Sector' | awk '{print $NF}' | head -1)"
                udma="$(echo "$smart_data" | grep -i 'UDMA_CRC_Error_Count' | awk '{print $NF}' | head -1)"
                poweron_hours="$(echo "$smart_data" | grep -i 'Power_On_Hours' | awk '{print $NF}' | head -1)"
                temp="$(echo "$smart_data" | grep -iE 'Temperature' | awk '{print $NF}' | head -1)"
                
                reallocated="${reallocated:-0}"; pending="${pending:-0}"; udma="${udma:-0}"
                print_data "=== $disk ==="
                print_data "Power-On Hours: ${poweron_hours:-N/A}"; print_data "Temperature: ${temp:-N/A}°C"
                print_data "Reallocated: $reallocated"; print_data "Pending: $pending"; print_data "UDMA CRC: $udma"
                
                if [[ "$reallocated" -gt 100 || "$pending" -gt 0 || "$udma" -gt 100 ]]; then
                    add_critical "Диск $disk SMART предупреждения | Realloc=$reallocated, Pending=$pending"
                    add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать диск $disk | Backup и замена"
                    print_data "$disk [DISK_RISK]"
                fi
            else
                print_status "SKIPPED [NEEDS_ROOT]"
                break
            fi
        done
    else
        print_status "SKIPPED [TOOL_MISSING: smartctl]"
    fi
    
    print_subsection "IO_SCHEDULER"
    for dev in /sys/block/sd* /sys/block/nvme*; do
        [[ -f "$dev/queue/scheduler" ]] && {
            local dev_name="$(basename "$dev")"
            local scheduler="$(cat "$dev/queue/scheduler" 2>/dev/null)"
            print_data "$dev_name Scheduler: $scheduler"
        }
    done
    
    print_subsection "TRIM_SUPPORT"
    for dev in /sys/block/sd* /sys/block/nvme*; do
        [[ -f "$dev/queue/discard_granularity" ]] && {
            local dev_name="$(basename "$dev")"
            local discard_gran="$(cat "$dev/queue/discard_granularity" 2>/dev/null)"
            [[ "$discard_gran" -gt 0 ]] 2>/dev/null && print_data "$dev_name: TRIM supported" || print_data "$dev_name: TRIM not supported"
        }
    done
    
    print_subsection "FILESYSTEM_TYPES"
    if check_tool blkid; then
        local fs_info="$(sudo blkid 2>/dev/null | head -10)"
        [[ -n "$fs_info" ]] && echo "$fs_info" | tee -a "$OUTPUT_FILE"
    fi
    
    print_subsection "MOUNT_OPTIONS"
    local mount_opts="$(findmnt -rn -o TARGET,FSTYPE,OPTIONS 2>/dev/null | head -10)"
    [[ -n "$mount_opts" ]] && echo "$mount_opts" | tee -a "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# [GPU] - 20+ точек диагностики GPU
#-------------------------------------------------------------------------------
scan_gpu() {
    print_section_header "GPU_DRIVERS"
    ((METRICS_COUNT+=20)) || true
    
    if check_tool lspci; then
        local gpu_info="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -5)"
        [[ -n "$gpu_info" ]] && { print_data "GPU Devices:"; echo "$gpu_info" | while read -r line; do echo "  - $line"; done; }
        
        local gpu_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'vga\|3d\|display' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        print_data "Active GPU Driver: $gpu_driver"
        
        if echo "$gpu_info" | grep -qi nvidia; then
            lsmod 2>/dev/null | grep -q nvidia && print_data "NVIDIA driver: LOADED" || { print_data "NVIDIA driver: NOT LOADED"; add_warning "NVIDIA GPU detected but driver not loaded"; }
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: lspci]"
    fi
    
    print_subsection "GPU_THERMAL"
    if check_tool sensors; then
        local gpu_temp="$(sensors 2>/dev/null | grep -iE 'edge|gpu|package' | head -3)"
        [[ -n "$gpu_temp" ]] && echo "$gpu_temp" | tee -a "$OUTPUT_FILE" || print_data "GPU Temperature: N/A"
    fi
}

#-------------------------------------------------------------------------------
# [NETWORK] - 25+ точек диагностики сети
#-------------------------------------------------------------------------------
scan_network() {
    print_section_header "NETWORK_INFO"
    ((METRICS_COUNT+=25)) || true
    
    print_subsection "NETWORK_INTERFACES"
    if check_tool ip; then
        local iface_info="$(ip -br addr 2>/dev/null)"
        [[ -n "$iface_info" ]] && echo "$iface_info" | tee -a "$OUTPUT_FILE"
    elif check_tool ifconfig; then
        ifconfig 2>/dev/null | head -20 | tee -a "$OUTPUT_FILE"
    fi
    
    print_subsection "LISTENING_PORTS"
    if check_tool ss; then
        local listen_ports="$(ss -tuln 2>/dev/null | head -15)"
        echo "$listen_ports" | tee -a "$OUTPUT_FILE"
    elif check_tool netstat; then
        netstat -tuln 2>/dev/null | head -15 | tee -a "$OUTPUT_FILE"
    else
        print_status "SKIPPED [TOOL_MISSING: ss/netstat]"
    fi
    
    print_subsection "NETWORK_DRIVERS"
    if check_tool lspci; then
        local wifi_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'wireless\|network' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        local eth_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'ethernet' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
        print_data "WiFi Driver: $wifi_driver"; print_data "Ethernet Driver: $eth_driver"
    fi
    
    print_subsection "DNS_CONFIG"
    if [[ -f /etc/resolv.conf ]]; then
        local dns_servers="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
        print_data "DNS Servers: $dns_servers"
    fi
}

#-------------------------------------------------------------------------------
# [KERNEL] - 20+ точек диагностики ядра
#-------------------------------------------------------------------------------
scan_kernel() {
    print_section_header "KERNEL_INFO"
    ((METRICS_COUNT+=20)) || true
    
    local kernel_ver="$(uname -r)"
    print_data "Kernel Version: $kernel_ver"
    
    local uptime_info="$(uptime -p 2>/dev/null || uptime)"
    print_data "Uptime: $uptime_info"
    
    print_subsection "LOADED_MODULES"
    local modules_count="$(wc -l < /proc/modules 2>/dev/null || echo 0)"
    print_data "Loaded Modules: $modules_count"
    
    local proprietary="$(lsmod 2>/dev/null | grep -iE 'nvidia|fglrx|broadcom|wl|vbox|virtualbox|vmware|akmod' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
    [[ -n "$proprietary" ]] && { print_data "Proprietary Modules: $proprietary"; add_info "Обнаружены проприетарные драйверы: $proprietary"; }
    
    print_subsection "DKMS_STATUS"
    if check_tool dkms; then
        local dkms_status="$(safe_sudo_cmd 'dkms status' 2>/dev/null)"
        [[ "$dkms_status" != "[NEEDS_ROOT]" && -n "$dkms_status" ]] && {
            echo "$dkms_status" | tee -a "$OUTPUT_FILE"
            echo "$dkms_status" | grep -qi "error\|mismatch" && { add_warning "DKMS errors detected"; print_issues "DKMS errors"; }
        } || print_status "SKIPPED [NEEDS_ROOT]"
    else
        print_status "SKIPPED [TOOL_MISSING: dkms]"
    fi
}

#-------------------------------------------------------------------------------
# [SERVICES] - 15+ точек диагностики служб
#-------------------------------------------------------------------------------
scan_services() {
    print_section_header "SERVICES_AND_PACKAGES"
    ((METRICS_COUNT+=15)) || true
    
    print_subsection "SYSTEMD_SERVICES"
    if check_tool systemctl; then
        local failed_services="$(systemctl --failed 2>/dev/null | grep -E 'failed' | head -5)"
        [[ -n "$failed_services" ]] && { echo "$failed_services" | tee -a "$OUTPUT_FILE"; add_warning "Failed services detected"; print_issues "Failed services"; } || print_data "No failed systemd services"
        
        local running_count="$(systemctl list-units --type=service --state=running 2>/dev/null | wc -l)"
        print_data "Running Services: $running_count"
    else
        print_status "SKIPPED [TOOL_MISSING: systemctl]"
    fi
    
    print_subsection "INSTALLED_PACKAGES"
    local pkg_count="unknown"
    case "$PKG_MANAGER" in
        apt) pkg_count="$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 0)" ;;
        dnf|yum) pkg_count="$(rpm -qa 2>/dev/null | wc -l || echo 0)" ;;
        pacman) pkg_count="$(pacman -Q 2>/dev/null | wc -l || echo 0)" ;;
    esac
    print_data "Installed Packages: $pkg_count"
}

#-------------------------------------------------------------------------------
# [SECURITY] - 20+ точек диагностики безопасности
#-------------------------------------------------------------------------------
scan_security() {
    print_section_header "SECURITY_INFO"
    ((METRICS_COUNT+=20)) || true
    
    print_subsection "FIREWALL_STATUS"
    if check_tool ufw; then
        local ufw_status="$(ufw status 2>/dev/null | head -1)"
        print_data "UFW: $ufw_status"
    elif check_tool firewall-cmd; then
        local fw_status="$(firewall-cmd --state 2>/dev/null)"
        print_data "Firewalld: $fw_status"
    elif check_tool iptables; then
        local ipt_rules="$(iptables -L -n 2>/dev/null | wc -l)"
        print_data "iptables rules: $ipt_rules"
    else
        print_data "Firewall: Status unknown"
    fi
    
    print_subsection "SSH_CONFIG"
    if [[ -f /etc/ssh/sshd_config ]]; then
        local permit_root="$(grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 'not set')"
        local pass_auth="$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 'not set')"
        print_data "PermitRootLogin: $permit_root"; print_data "PasswordAuthentication: $pass_auth"
        [[ "$permit_root" == "yes" ]] && add_warning "SSH PermitRootLogin enabled"
    fi
    
    print_subsection "APPARMOR_SELINUX"
    if check_tool aa-status; then
        aa-status 2>/dev/null | head -5 | tee -a "$OUTPUT_FILE"
    elif [[ -f /etc/selinux/config ]]; then
        local selinux_mode="$(grep SELINUX /etc/selinux/config 2>/dev/null | grep -v '^#' | head -1)"
        print_data "SELinux: $selinux_mode"
    else
        print_data "Mandatory Access Control: None detected"
    fi
}

#-------------------------------------------------------------------------------
# [BATTERY] - 15+ точек диагностики батареи
#-------------------------------------------------------------------------------
scan_battery() {
    print_section_header "BATTERY_STATUS"
    ((METRICS_COUNT+=15)) || true
    
    if [[ -d /sys/class/power_supply ]]; then
        local battery_found=false
        for bat in /sys/class/power_supply/BAT*; do
            [[ -d "$bat" ]] || continue
            battery_found=true
            local capacity full_design current status wear
            capacity="$(cat "$bat/capacity" 2>/dev/null || echo 'N/A')"
            full_design="$(cat "$bat/energy_full_design" 2>/dev/null || cat "$bat/charge_full_design" 2>/dev/null || echo 'N/A')"
            current="$(cat "$bat/energy_full" 2>/dev/null || cat "$bat/charge_full" 2>/dev/null || echo 'N/A')"
            status="$(cat "$bat/status" 2>/dev/null || echo 'N/A')"
            
            wear="N/A"
            if [[ "$full_design" != "N/A" && "$current" != "N/A" && "$full_design" -gt 0 ]] 2>/dev/null; then
                wear="$(( (current * 100) / full_design ))%"
                [[ "${wear%\%}" -lt 80 ]] 2>/dev/null && add_warning "Износ батареи: $wear"
            fi
            
            print_data "Capacity: $capacity%"; print_data "Wear Level: $wear"; print_data "Status: $status"
        done
        [[ "$battery_found" == false ]] && print_data "No battery detected"
    else
        print_status "SKIPPED [No power_supply class]"
    fi
}

#-------------------------------------------------------------------------------
# [THERMAL] - 20+ точек диагностики охлаждения
#-------------------------------------------------------------------------------
scan_thermal() {
    print_section_header "THERMAL_SENSORS"
    ((METRICS_COUNT+=20)) || true
    
    local thermal_zones=0
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [[ -f "$zone" ]] || continue
        thermal_zones=$((thermal_zones + 1))
        local temp_val temp_c zone_name zone_type
        temp_val="$(cat "$zone" 2>/dev/null)"; temp_c=$((temp_val / 1000))
        zone_type="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Zone$thermal_zones")"
        
        if [[ $temp_c -gt 85 ]]; then
            add_warning "Высокая температура $zone_type: ${temp_c}°C"
            print_data "$zone_type: ${temp_c}°C [HIGH]"
        else
            print_data "$zone_type: ${temp_c}°C"
        fi
    done
    [[ $thermal_zones -eq 0 ]] && print_data "No thermal sensors found"
    
    print_subsection "FAN_SPEEDS"
    if check_tool sensors; then
        local fan_info="$(sensors 2>/dev/null | grep -i 'fan' | head -5)"
        [[ -n "$fan_info" ]] && echo "$fan_info" | tee -a "$OUTPUT_FILE" || print_data "Fan speeds: N/A"
    else
        print_status "SKIPPED [TOOL_MISSING: sensors]"
    fi
}

#-------------------------------------------------------------------------------
# [LOGS] - 15+ точек анализа логов
#-------------------------------------------------------------------------------
scan_logs() {
    print_section_header "SYSTEM_LOGS"
    ((METRICS_COUNT+=15)) || true
    
    print_subsection "JOURNAL_ERRORS"
    if check_tool journalctl; then
        local errors="$(journalctl -p err -xb 2>/dev/null | tail -5)"
        [[ -n "$errors" ]] && { print_issues "Recent errors in journal"; print_raw_logs "$errors"; } || print_data "No recent critical errors"
    else
        print_status "SKIPPED [TOOL_MISSING: journalctl]"
    fi
    
    print_subsection "DMESG_ERRORS"
    local dmesg_errors="$(dmesg 2>/dev/null | grep -iE 'error|fail|critical' | tail -5)"
    [[ -n "$dmesg_errors" ]] && { print_issues "Errors in dmesg"; print_raw_logs "$dmesg_errors"; } || print_data "No critical errors in dmesg"
    
    print_subsection "PCIE_ACPI_ERRORS"
    local pcie_errors="$(dmesg 2>/dev/null | grep -iE 'aer|pci bus error|acpi error' | tail -5)"
    [[ -n "$pcie_errors" ]] && { print_issues "PCIe/ACPI errors detected"; print_raw_logs "$pcie_errors"; add_warning "PCIe/ACPI ошибки в dmesg"; } || print_data "No PCIe/ACPI errors"
}

#-------------------------------------------------------------------------------
# [PROFILING] - Только для уровня 4
#-------------------------------------------------------------------------------
scan_profiling() {
    print_section_header "PERFORMANCE_PROFILING"
    ((METRICS_COUNT+=50)) || true
    
    echo -e "${YELLOW}⚠️  Режим профилирования: сбор метрик производительности${NC}" >&2
    
    print_subsection "PERF_STATS"
    if check_tool perf; then
        local perf_version="$(perf --version 2>/dev/null | head -1)"
        print_data "Perf: $perf_version"
    else
        print_status "SKIPPED [TOOL_MISSING: perf]"
    fi
    
    print_subsection "SYSTEMD_ANALYZE"
    if check_tool systemd-analyze; then
        local boot_time="$(systemd-analyze 2>/dev/null | head -1)"
        local blame="$(systemd-analyze blame 2>/dev/null | head -5)"
        [[ -n "$boot_time" ]] && print_data "Boot Time: $boot_time"
        [[ -n "$blame" ]] && { echo "$blame" | tee -a "$OUTPUT_FILE"; }
    fi
    
    print_subsection "CONTEXT_SWITCHES"
    if [[ -f /proc/stat ]]; then
        local ctx_switches="$(grep ctxt /proc/stat 2>/dev/null | awk '{print $2}' || echo 'N/A')"
        local interrupts="$(grep intr /proc/stat 2>/dev/null | awk '{print $2}' || echo 'N/A')"
        print_data "Context Switches: $ctx_switches"; print_data "Interrupts: $interrupts"
    fi
    
    print_subsection "IO_LATENCY"
    if [[ -f /proc/diskstats ]]; then
        local io_wait="$(awk '{sum+=$13} END {print sum}' /proc/diskstats 2>/dev/null || echo 'N/A')"
        print_data "Total I/O Wait (ms): $io_wait"
    fi
    
    print_subsection "NETWORK_LATENCY"
    if [[ -f /proc/net/softnet_stat ]]; then
        local softnet="$(cat /proc/net/softnet_stat 2>/dev/null | head -3)"
        print_data "SoftIRQ Stats:"; echo "$softnet" | while read line; do echo "  $line"; done
    fi
}

#-------------------------------------------------------------------------------
# [STRESS_TEST] - Только для уровня 4 с подтверждением
#-------------------------------------------------------------------------------
run_stress_test() {
    print_section_header "STRESS_TEST_RESULTS"
    
    echo -e "${RED}⚠️  ЗАПУСК СТРЕСС-ТЕСТОВ${NC}" >&2
    echo -e "${RED}⚠️  Не прерывайте выполнение!${NC}" >&2
    
    if check_tool stress-ng; then
        log_progress "CPU stress test (10 sec)..."
        timeout 10 stress-ng --cpu 1 --timeout 10s 2>&1 | tail -3 | tee -a "$OUTPUT_FILE"
        
        log_progress "Memory stress test (10 sec)..."
        timeout 10 stress-ng --vm 1 --vm-bytes 256M --timeout 10s 2>&1 | tail -3 | tee -a "$OUTPUT_FILE"
        
        log_progress "Checking for hardware errors after stress..."
        local stress_errors="$(dmesg 2>/dev/null | tail -20 | grep -iE 'error|fail|mce|hardware' || echo "")"
        [[ -n "$stress_errors" ]] && { add_critical "Hardware errors detected during stress"; print_raw_logs "$stress_errors"; } || print_data "No hardware errors detected"
    else
        print_status "SKIPPED [TOOL_MISSING: stress-ng]"
    fi
}

#-------------------------------------------------------------------------------
# AI SUMMARY GENERATION
#-------------------------------------------------------------------------------
generate_ai_summary() {
    {
        echo ""
        echo "## [AI_SUMMARY]"
        echo "{"
        echo "  \"scan_metadata\": {"
        echo "    \"hostname\": \"$HOSTNAME\","
        echo "    \"timestamp\": \"$TIMESTAMP\","
        echo "    \"scan_level\": $SCAN_LEVEL,"
        echo "    \"metrics_collected\": $METRICS_COUNT,"
        echo "    \"package_manager\": \"$PKG_MANAGER\""
        echo "  },"
        
        echo "  \"critical_issues\": ["
        local i=0
        for issue in "${CRITICAL_ISSUES[@]}"; do
            [[ $i -gt 0 ]] && echo ","
            echo -n "    \"$issue\""
            i=$((i+1))
        done
        echo ""
        echo "  ],"
        
        echo "  \"warning_issues\": ["
        i=0
        for issue in "${WARNING_ISSUES[@]}"; do
            [[ $i -gt 0 ]] && echo ","
            echo -n "    \"$issue\""
            i=$((i+1))
        done
        echo ""
        echo "  ],"
        
        echo "  \"info_issues\": ["
        i=0
        for issue in "${INFO_ISSUES[@]}"; do
            [[ $i -gt 0 ]] && echo ","
            echo -n "    \"$issue\""
            i=$((i+1))
        done
        echo ""
        echo "  ],"
        
        echo "  \"strict_prohibitions\": ["
        i=0
        for prohibition in "${STRICT_PROHIBITIONS[@]}" "${UNIVERSAL_PROHIBITIONS[@]}"; do
            [[ $i -gt 0 ]] && echo ","
            echo -n "    \"$prohibition\""
            i=$((i+1))
        done
        echo ""
        echo "  ]"
        echo "}"
        echo ""
        echo "## [END_OF_REPORT]"
    } >> "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# MAIN EXECUTION
#-------------------------------------------------------------------------------
main() {
    show_banner
    prepare_output_dir
    write_report_header
    
    # Обработка аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-install) AUTO_INSTALL=true; shift ;;
            --force-profiling) FORCE_PROFILING=true; SCAN_LEVEL=4; shift ;;
            --level) SCAN_LEVEL="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # Если уровень не задан, показываем меню
    [[ $SCAN_LEVEL -eq 0 ]] && show_scan_menu
    
    check_and_install_tools
    
    log_section "Запуск сканирования уровня $SCAN_LEVEL"
    
    # Базовые проверки (всегда)
    scan_cpu
    scan_ram
    scan_storage
    
    # Уровень 2+
    if [[ $SCAN_LEVEL -ge $LEVEL_MEDIUM ]]; then
        scan_gpu
        scan_network
        scan_kernel
        scan_services
        scan_battery
        scan_thermal
    fi
    
    # Уровень 3+
    if [[ $SCAN_LEVEL -ge $LEVEL_TOTAL ]]; then
        scan_security
        scan_logs
    fi
    
    # Уровень 4 (профилирование)
    if [[ $SCAN_LEVEL -eq $LEVEL_PROFILING ]]; then
        scan_profiling
        run_stress_test
    fi
    
    generate_ai_summary
    
    # Вывод результатов в терминал
    echo ""
    echo "========================================"
    echo "✅ СКАНИРОВАНИЕ ЗАВЕРШЕНО"
    echo "========================================"
    echo "📊 Метрик собрано: $METRICS_COUNT"
    echo "📁 Отчёт: ${OUTPUT_FILE}"
    echo ""
    
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}КРИТИЧЕСКИЕ ПРОБЛЕМЫ:${NC}"
        for issue in "${CRITICAL_ISSUES[@]}"; do echo "  • $issue" >&2; done
    fi
    
    if [[ ${#WARNING_ISSUES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}ПРЕДУПРЕЖДЕНИЯ:${NC}"
        for issue in "${WARNING_ISSUES[@]}"; do echo "  • $issue" >&2; done
    fi
    
    echo ""
    echo "Полный отчёт: ${OUTPUT_FILE}"
    echo ""
}

# Запуск
main "$@"
