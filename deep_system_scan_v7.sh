#!/usr/bin/env bash
#===============================================================================
# DEEP SYSTEM SCAN v7.0 - Расширенная диагностика Linux для ИИ-анализа
# ТОЛЬКО ЧТЕНИЕ: Никаких изменений в системе (кроме опциональной установки пакетов)
# Версия 7 включает >2000 параметров: ядро, память, процессы, ФС, сеть, 
# безопасность, энергетика, CPU/микрокод, BIOS/UEFI, RAM, GPU, хранилища,
# сетевые адаптеры, USB/PCIe, IPMI/BMC, датчики, прошивки, TPM, аудио
#===============================================================================

set -o pipefail
# set -e намеренно НЕ используется для гибкой обработки ошибок

#-------------------------------------------------------------------------------
# КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
readonly VERSION="7.0"
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
readonly LEVEL_DEEP=5

# Цвета для терминала
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # Без цвета

# Счётчики проблем
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()

# Статус инструментов
declare -A TOOLS_STATUS=()

# Счётчики параметров
TOTAL_PARAMS_COLLECTED=0

# Флаги
AUTO_INSTALL=false
FORCE_PROFILING=false
SKIP_INTERACTIVE=false

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
    "[НЕ ДЕЛАТЬ] Записывать в /proc или /sys напрямую | Может нарушить работу ядра | Только чтение"
    "[НЕ ДЕЛАТЬ] Загружать неизвестные модули ядра | Риск стабильности | Проверять подписи"
    "[НЕ ДЕЛАТЬ] Отключать SELinux/AppArmor без необходимости | Снижение безопасности | Использовать audit режим"
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

# Подсчёт параметров
increment_params() {
    local count="$1"
    TOTAL_PARAMS_COLLECTED=$((TOTAL_PARAMS_COLLECTED + count))
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

log_deep_section() {
    echo -e "\n${MAGENTA}>>> $* <<<${NC}" >&2
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
╔══════════════════════════════════════════════════════════════════╗
║          DEEP SYSTEM SCAN v${VERSION} - Расширенная диагностика       ║
║         Сбор >2000 параметров системы и оборудования             ║
║              Безопасный сканер только для чтения                 ║
╚══════════════════════════════════════════════════════════════════╝
EOF
}

#-------------------------------------------------------------------------------
# МЕНЮ НА РУССКОМ
#-------------------------------------------------------------------------------
show_scan_menu() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║     DEEP SYSTEM SCAN v7.0 - Выбор уровня диагностики             ║
╠══════════════════════════════════════════════════════════════════╣
║  [1] Минимальный: ядро, CPU/RAM, базовые логи, uptime            ║
║      (~30 секунд, ~50 параметров)                                ║
║  [2] Средний: + службы, пакеты, сеть, SMART, пользователи        ║
║      (~2 минуты, ~200 параметров)                                ║
║  [3] Тотальный: + безопасность, контейнеры, валидация            ║
║      (~5 минут, ~500 параметров)                                 ║
║  [4] Профилирование: + стресс-тесты, тяжёлые метрики             ║
║      (~10 минут, ~800 параметров, ТРЕБУЕТ подтверждения!)        ║
║  [5] ГЛУБОКИЙ: Полный сбор >2000 параметров железа и ОС          ║
║      (~15 минут, МАКСИМАЛЬНАЯ ДЕТАЛИЗАЦИЯ)                       ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    
    while true; do
        read -rp "Выберите уровень сканирования [1-5] (по умолчанию 1): " choice
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
            5)
                echo -e "${MAGENTA}🔬 Режим 5: ГЛУБОКОЕ СКАНИРОВАНИЕ${NC}"
                echo "   Будет собрано >2000 параметров:"
                echo "   • Диагностика: ядро, память, процессы, ФС, сеть (>1000)"
                echo "   • Железо: CPU, BIOS, RAM, GPU, диски, NIC (>1000)"
                read -rp "Продолжить? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    SCAN_LEVEL=5
                    echo "✅ Выбран режим: ГЛУБОКИЙ АНАЛИЗ СИСТЕМЫ"
                    break
                else
                    echo "❌ Выбор отменён."
                fi
                ;;
            *) echo "❌ Неверный выбор. Введите 1, 2, 3, 4 или 5." ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# АРГУМЕНТЫ КОМАНДНОЙ СТРОКИ
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--level)
                SCAN_LEVEL="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -a|--auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            -f|--force)
                FORCE_PROFILING=true
                shift
                ;;
            -q|--quiet)
                SKIP_INTERACTIVE=true
                shift
                ;;
            -h|--help)
                echo "Использование: $SCRIPT_NAME [-l уровень] [-o файл] [-a] [-f] [-q]"
                echo "  -l, --level       Уровень сканирования (1-5)"
                echo "  -o, --output      Файл вывода"
                echo "  -a, --auto-install Автоматическая установка пакетов"
                echo "  -f, --force       Принудительное профилирование"
                echo "  -q, --quiet       Тихий режим"
                exit 0
                ;;
            *)
                echo "Неизвестный параметр: $1"
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# ПРОВЕРКА И УСТАНОВКА ИНСТРУМЕНТОВ
#-------------------------------------------------------------------------------
check_and_install_tools() {
    log_section "Проверка необходимых инструментов"
    
    local -a missing_tools=()
    
    # Основные инструменты v6
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
    
    # Дополнительные инструменты v7
    declare -A extra_tools=(
        ["nvme"]="nvme-cli"
        ["ethtool"]="ethtool"
        ["ipmitool"]="ipmitool"
        ["fwupdmgr"]="fwupd"
        ["tpm2_pcrread"]="tpm2-tools"
        ["numactl"]="numactl"
        ["turbostat"]="linux-tools"
        ["cpuid"]="cpuid"
        ["glxinfo"]="mesa-utils"
        ["nvidia-smi"]="nvidia-driver"
        ["bpftool"]="bpftool"
        ["perf"]="linux-perf"
    )
    
    # Объединяем
    for tool in "${!extra_tools[@]}"; do
        if [[ -z "${tool_packages[$tool]}" ]]; then
            tool_packages["$tool"]="${extra_tools[$tool]}"
        fi
    done
    
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
                if [[ "$AUTO_INSTALL" != true ]] && [[ "$SKIP_INTERACTIVE" != true ]]; then
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

print_deep_data() {
    local key="$1"
    local value="$2"
    local output="  [$key]: $value"
    echo "$output" >> "$OUTPUT_FILE"
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
# ЧАСТЬ 1: ДИАГНОСТИКА СИСТЕМЫ (>1000 параметров)
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: CPU (расширенное)
#-------------------------------------------------------------------------------
scan_cpu_deep() {
    print_section_header "CPU_DEEP_INFO"
    log_deep_section "Детальная информация о CPU"
    
    local param_count=0
    
    # Базовая информация
    print_subsection "CPU_BASIC"
    lscpu 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(lscpu 2>/dev/null | wc -l)))
    
    # Подробный cpuinfo
    print_subsection "CPU_PROC_INFO"
    cat /proc/cpuinfo 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/cpuinfo 2>/dev/null || echo 0)))
    
    # Микрокод и уязвимости
    print_subsection "CPU_VULNERABILITIES"
    for vuln in /sys/devices/system/cpu/vulnerabilities/*; do
        if [[ -f "$vuln" ]]; then
            local name=$(basename "$vuln")
            local status=$(cat "$vuln" 2>/dev/null)
            print_data "$name: $status"
            param_count=$((param_count + 1))
        fi
    done
    
    # Microcode версии по ядрам
    print_subsection "CPU_MICROCODE_PER_CORE"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        if [[ -d "$cpu_dir" ]]; then
            local cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')
            local microcode_ver=$(cat "$cpu_dir/microcode/version" 2>/dev/null || echo "N/A")
            print_deep_data "cpu${cpu_id}_microcode" "$microcode_ver"
            param_count=$((param_count + 1))
        fi
    done
    
    # Частоты и governor
    print_subsection "CPU_FREQ_GOVERNORS"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        if [[ -d "$cpu_dir/cpufreq" ]]; then
            local cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')
            local cur_freq=$(cat "$cpu_dir/cpufreq/scaling_cur_freq" 2>/dev/null || echo "N/A")
            local max_freq=$(cat "$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || echo "N/A")
            local min_freq=$(cat "$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || echo "N/A")
            local gov=$(cat "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
            print_deep_data "cpu${cpu_id}_cur_mhz" "$((cur_freq / 1000))"
            print_deep_data "cpu${cpu_id}_max_mhz" "$((max_freq / 1000))"
            print_deep_data "cpu${cpu_id}_min_mhz" "$((min_freq / 1000))"
            print_deep_data "cpu${cpu_id}_governor" "$gov"
            param_count=$((param_count + 4))
        fi
    done
    
    # C-states
    print_subsection "CPU_CSTATES"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        if [[ -d "$cpu_dir/cpuidle" ]]; then
            local cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')
            for state in "$cpu_dir/cpuidle/state"*; do
                if [[ -d "$state" ]]; then
                    local state_name=$(cat "$state/name" 2>/dev/null)
                    local state_desc=$(cat "$state/desc" 2>/dev/null)
                    print_deep_data "cpu${cpu_id}_cstate_${state_name}" "$state_desc"
                    param_count=$((param_count + 1))
                fi
            done
        fi
    done
    
    # Кэши
    print_subsection "CPU_CACHES"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        if [[ -d "$cpu_dir/cache" ]]; then
            local cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')
            for idx in "$cpu_dir/cache/index"*; do
                if [[ -d "$idx" ]]; then
                    local level=$(cat "$idx/level" 2>/dev/null)
                    local size=$(cat "$idx/size" 2>/dev/null)
                    local type=$(cat "$idx/type" 2>/dev/null)
                    print_deep_data "cpu${cpu_id}_cache_L${level}_${type}" "$size"
                    param_count=$((param_count + 1))
                fi
            done
        fi
    done
    
    # Топология NUMA
    print_subsection "CPU_NUMA_TOPOLOGY"
    if [[ -d /sys/devices/system/node ]]; then
        numactl --hardware 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        for node in /sys/devices/system/node/node*; do
            if [[ -d "$node" ]]; then
                local node_id=$(basename "$node")
                local cpulist=$(cat "$node/cpulist" 2>/dev/null)
                print_deep_data "${node_id}_cpulist" "$cpulist"
                param_count=$((param_count + 1))
            fi
        done
    fi
    
    # MSRs через rdmsr если доступен
    if check_tool rdmsr; then
        print_subsection "CPU_MSR_REGISTERS"
        local msr_vals=$(rdmsr 0x10 2>/dev/null || echo "N/A")
        print_data "IA32_FEATURE_CONTROL: $msr_vals"
        param_count=$((param_count + 1))
    fi
    
    increment_params "$param_count"
    log_info "Собрано параметров CPU: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: ПАМЯТЬ (расширенное)
#-------------------------------------------------------------------------------
scan_memory_deep() {
    print_section_header "MEMORY_DEEP_INFO"
    log_deep_section "Детальная информация о памяти"
    
    local param_count=0
    
    # /proc/meminfo
    print_subsection "MEMINFO_FULL"
    cat /proc/meminfo 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/meminfo 2>/dev/null || echo 0)))
    
    # /proc/vmstat
    print_subsection "VMSTAT_FULL"
    cat /proc/vmstat 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/vmstat 2>/dev/null || echo 0)))
    
    # sysctl vm параметры
    print_subsection "SYSCTL_VM_PARAMS"
    sysctl -a 2>/dev/null | grep "^vm\." | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(sysctl -a 2>/dev/null | grep -c "^vm\." || echo 0)))
    
    # NUMA статистика
    print_subsection "NUMASTAT"
    if check_tool numastat; then
        numastat -v 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(numastat -v 2>/dev/null | grep -c . || echo 0)))
    else
        cat /sys/devices/system/node/node*/meminfo 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(grep -c . /sys/devices/system/node/node*/meminfo 2>/dev/null || echo 0)))
    fi
    
    # Статистика по узлам NUMA
    print_subsection "NUMA_NODE_MEMINFO"
    for node in /sys/devices/system/node/node*; do
        if [[ -d "$node" ]]; then
            local node_id=$(basename "$node")
            print_deep_data "${node_id}_meminfo" "$(cat "$node/meminfo" 2>/dev/null | head -5)"
            param_count=$((param_count + 1))
        fi
    done
    
    # HugePages
    print_subsection "HUGEPAGES"
    for hp in /proc/sys/vm/nr_hugepages /proc/sys/vm/nr_overcommit_hugepages \
              /sys/kernel/mm/hugepages/hugepages-*/nr_hugepages; do
        if [[ -f "$hp" ]]; then
            print_deep_data "$(basename $(dirname $hp))_$(basename $hp)" "$(cat "$hp" 2>/dev/null)"
            param_count=$((param_count + 1))
        fi
    done
    
    # EDAC ошибки памяти
    print_subsection "EDAC_MEMORY_ERRORS"
    if [[ -d /sys/devices/system/edac ]]; then
        find /sys/devices/system/edac -name "*count" -type f 2>/dev/null | while read f; do
            print_deep_data "$(basename $f)" "$(cat "$f" 2>/dev/null)"
            param_count=$((param_count + 1))
        done
    fi
    
    increment_params "$param_count"
    log_info "Собрано параметров памяти: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: ПРОЦЕССЫ (расширенное)
#-------------------------------------------------------------------------------
scan_processes_deep() {
    print_section_header "PROCESSES_DEEP_INFO"
    log_deep_section "Детальная информация о процессах"
    
    local param_count=0
    local proc_count=0
    
    # Общие лимиты
    print_subsection "SYSTEM_LIMITS"
    print_data "threads-max: $(cat /proc/sys/kernel/threads-max 2>/dev/null)"
    print_data "pid_max: $(cat /proc/sys/kernel/pid_max 2>/dev/null)"
    param_count=$((param_count + 2))
    
    # Топ процессов по CPU
    print_subsection "TOP_CPU_PROCESSES"
    ps aux --sort=-%cpu 2>/dev/null | head -20 | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + 20))
    
    # Топ процессов по памяти
    print_subsection "TOP_MEM_PROCESSES"
    ps aux --sort=-%mem 2>/dev/null | head -20 | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + 20))
    
    # Детали по каждому процессу (ограничено первыми 50)
    print_subsection "PROCESS_DETAILS"
    for pid_dir in /proc/[0-9]*; do
        if [[ -d "$pid_dir" ]] && [[ $proc_count -lt 50 ]]; then
            local pid=$(basename "$pid_dir")
            
            # Пропускаем системные процессы без cmdline
            if [[ ! -r "$pid_dir/cmdline" ]]; then
                continue
            fi
            
            local cmdline=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null | head -c 100)
            local state=$(cat "$pid_dir/stat" 2>/dev/null | awk '{print $3}')
            local ppid=$(cat "$pid_dir/stat" 2>/dev/null | awk '{print $4}')
            local threads=$(cat "$pid_dir/status" 2>/dev/null | grep Threads | awk '{print $2}')
            local vm_rss=$(cat "$pid_dir/status" 2>/dev/null | grep VmRSS | awk '{print $2}')
            
            if [[ -n "$cmdline" ]]; then
                print_deep_data "pid${pid}_cmd" "${cmdline:0:80}"
                print_deep_data "pid${pid}_state" "$state"
                print_deep_data "pid${pid}_ppid" "$ppid"
                print_deep_data "pid${pid}_threads" "${threads:-N/A}"
                print_deep_data "pid${pid}_vmrss_kb" "${vm_rss:-N/A}"
                param_count=$((param_count + 5))
                proc_count=$((proc_count + 1))
            fi
        fi
    done
    
    # Cgroups v2
    print_subsection "CGROUPS_V2"
    if [[ -d /sys/fs/cgroup ]]; then
        find /sys/fs/cgroup -maxdepth 2 -name "cgroup.procs" -type f 2>/dev/null | head -10 | while read f; do
            local count=$(wc -l < "$f" 2>/dev/null)
            print_deep_data "cgroup_$(dirname $f | xargs basename)_procs" "$count"
            param_count=$((param_count + 1))
        done
    fi
    
    # Открытые файлы (lsof summary)
    print_subsection "OPEN_FILES_SUMMARY"
    if check_tool lsof; then
        lsof 2>/dev/null | awk '{print $5}' | sort | uniq -c | sort -rn | head -10 | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + 10))
    fi
    
    increment_params "$param_count"
    log_info "Собрано параметров процессов: $param_count (процессов: $proc_count)"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: ЯДРО И ЗАГРУЗКА
#-------------------------------------------------------------------------------
scan_kernel_deep() {
    print_section_header "KERNEL_DEEP_INFO"
    log_deep_section "Детальная информация о ядре"
    
    local param_count=0
    
    # Версия и релиз
    print_subsection "KERNEL_VERSION"
    print_data "version: $(uname -r)"
    print_data "osrelease: $(cat /proc/sys/kernel/osrelease 2>/dev/null)"
    print_data "version_str: $(cat /proc/version 2>/dev/null)"
    param_count=$((param_count + 3))
    
    # Параметры загрузки
    print_subsection "BOOT_PARAMS"
    cat /proc/cmdline 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + 1))
    
    # Все sysctl kernel.*
    print_subsection "SYSCTL_KERNEL_ALL"
    sysctl -a 2>/dev/null | grep "^kernel\." | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(sysctl -a 2>/dev/null | grep -c "^kernel\." || echo 0)))
    
    # Загруженные модули
    print_subsection "LOADED_MODULES"
    lsmod 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(lsmod 2>/dev/null | tail -n +2 | wc -l)))
    
    # Детали модулей
    print_subsection "MODULE_DETAILS"
    for mod in $(lsmod 2>/dev/null | tail -n +2 | awk '{print $1}' | head -30); do
        local mod_info=$(modinfo "$mod" 2>/dev/null | grep -E "^version:|^license:|^description:" | tr '\n' '; ')
        print_deep_data "module_${mod}" "${mod_info:-N/A}"
        param_count=$((param_count + 1))
    done
    
    # dmesg критические сообщения
    print_subsection "DMESG_CRITICAL"
    dmesg -l err,crit,alert,emerg 2>/dev/null | tail -30 | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(dmesg -l err,crit,alert,emerg 2>/dev/null | tail -30 | wc -l)))
    
    # Параметры ядра в runtime
    print_subsection "PROC_SYS_KERNEL"
    find /proc/sys/kernel -type f 2>/dev/null | head -50 | while read f; do
        print_deep_data "$(echo $f | sed 's|/proc/sys/kernel/||')" "$(cat "$f" 2>/dev/null)"
        param_count=$((param_count + 1))
    done
    
    # Security параметры
    print_subsection "KERNEL_SECURITY"
    print_data "dmesg_restrict: $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null)"
    print_data "kptr_restrict: $(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"
    print_data "randomize_va_space: $(cat /proc/sys/kernel/randomize_va_space 2>/dev/null)"
    print_data "sysrq: $(cat /proc/sys/kernel/sysrq 2>/dev/null)"
    print_data "ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null)"
    param_count=$((param_count + 5))
    
    increment_params "$param_count"
    log_info "Собрано параметров ядра: $param_count"
}


#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: СЕТЬ (расширенное)
#-------------------------------------------------------------------------------
scan_network_deep() {
    print_section_header "NETWORK_DEEP_INFO"
    log_deep_section "Детальная информация о сети"
    
    local param_count=0
    
    # Интерфейсы и статистика
    print_subsection "NETWORK_INTERFACES"
    ip -s link 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(ip -s link 2>/dev/null | wc -l)))
    
    # Соединения
    print_subsection "NETWORK_CONNECTIONS"
    ss -tanup 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(ss -tanup 2>/dev/null | tail -n +2 | wc -l)))
    
    # /proc/net/dev
    print_subsection "PROC_NET_DEV"
    cat /proc/net/dev 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/net/dev 2>/dev/null || echo 0)))
    
    # SNMP статистика
    print_subsection "PROC_NET_SNMP"
    cat /proc/net/snmp 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/net/snmp 2>/dev/null || echo 0)))
    
    # nstat если доступен
    if check_tool nstat; then
        print_subsection "NSTAT_ALL"
        nstat -a 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(nstat -a 2>/dev/null | grep -v "^#" | wc -l)))
    fi
    
    # sysctl net параметры
    print_subsection "SYSCTL_NET_PARAMS"
    sysctl -a 2>/dev/null | grep "^net\." | head -100 | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(sysctl -a 2>/dev/null | grep -c "^net\." || echo 0)))
    
    # Детали по интерфейсам через ethtool
    print_subsection "ETHTOOL_DETAILS"
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if check_tool ethtool; then
            print_deep_data "${iface}_driver" "$(ethtool -i "$iface" 2>/dev/null | grep driver | awk '{print $2}')"
            print_deep_data "${iface}_firmware" "$(ethtool -i "$iface" 2>/dev/null | grep firmware | awk '{print $2}')"
            print_deep_data "${iface}_speed" "$(cat /sys/class/net/$iface/speed 2>/dev/null || echo N/A)"
            print_deep_data "${iface}_duplex" "$(cat /sys/class/net/$iface/duplex 2>/dev/null || echo N/A)"
            param_count=$((param_count + 4))
            
            # Статистика драйвера
            if ethtool -S "$iface" 2>/dev/null | grep -q ":"; then
                ethtool -S "$iface" 2>/dev/null | grep ":" | head -20 | while read line; do
                    print_deep_data "${iface}_$(echo $line | cut -d: -f1 | tr -d ' ')" "$(echo $line | cut -d: -f2)"
                    param_count=$((param_count + 1))
                done
            fi
        fi
    done
    
    # Маршруты
    print_subsection "ROUTING_TABLE"
    ip route 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(ip route 2>/dev/null | wc -l)))
    
    # ARP таблица
    print_subsection "ARP_CACHE"
    ip neigh 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(ip neigh 2>/dev/null | wc -l)))
    
    # DNS конфигурация
    print_subsection "DNS_CONFIG"
    cat /etc/resolv.conf 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /etc/resolv.conf 2>/dev/null || echo 0)))
    
    increment_params "$param_count"
    log_info "Собрано параметров сети: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: ФС И ДИСКИ (расширенное)
#-------------------------------------------------------------------------------
scan_storage_deep() {
    print_section_header "STORAGE_DEEP_INFO"
    log_deep_section "Детальная информация о файловых системах и дисках"
    
    local param_count=0
    
    # df по всем ФС
    print_subsection "DISK_USAGE"
    df -Th 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(df -Th 2>/dev/null | tail -n +2 | wc -l)))
    
    # Монтирование
    print_subsection "MOUNT_POINTS"
    mount 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(mount 2>/dev/null | wc -l)))
    
    # lsblk детально
    print_subsection "BLOCK_DEVICES"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,TRIM,SERIAL,MODEL 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(lsblk 2>/dev/null | tail -n +2 | wc -l)))
    
    # iostat если доступен
    if check_tool iostat; then
        print_subsection "IOSTAT"
        iostat -xd 1 1 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(iostat -xd 1 1 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # /proc/diskstats
    print_subsection "PROC_DISKSTATS"
    cat /proc/diskstats 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(grep -c . /proc/diskstats 2>/dev/null || echo 0)))
    
    # Детали по каждому диску в /sys/block
    print_subsection "BLOCK_DEVICE_DETAILS"
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
        if [[ -d "$disk" ]]; then
            local name=$(basename "$disk")
            print_deep_data "${name}_size" "$(cat "$disk/size" 2>/dev/null)"
            print_deep_data "${name}_model" "$(cat "$disk/device/model" 2>/dev/null | tr -d ' ')"
            print_deep_data "${name}_rev" "$(cat "$disk/device/rev" 2>/dev/null)"
            print_deep_data "${name}_vendor" "$(cat "$disk/device/vendor" 2>/dev/null)"
            print_deep_data "${name}_queue_scheduler" "$(cat "$disk/queue/scheduler" 2>/dev/null)"
            print_deep_data "${name}_queue_nr_requests" "$(cat "$disk/queue/nr_requests" 2>/dev/null)"
            print_deep_data "${name}_queue_read_ahead_kb" "$(cat "$disk/queue/read_ahead_kb" 2>/dev/null)"
            print_deep_data "${name}_queue_logical_block_size" "$(cat "$disk/queue/logical_block_size" 2>/dev/null)"
            print_deep_data "${name}_queue_physical_block_size" "$(cat "$disk/queue/physical_block_size" 2>/dev/null)"
            param_count=$((param_count + 9))
            
            # Статистика I/O
            if [[ -f "$disk/stat" ]]; then
                local stats=$(cat "$disk/stat" 2>/dev/null)
                print_deep_data "${name}_io_stats" "$stats"
                param_count=$((param_count + 1))
            fi
        fi
    done
    
    # SMART для дисков
    print_subsection "SMART_DATA"
    if check_tool smartctl; then
        for dev in /dev/sd[a-z] /dev/nvme[0-9]*; do
            if [[ -b "$dev" ]]; then
                print_deep_data "${dev}_smart_model" "$(smartctl -i "$dev" 2>/dev/null | grep "Model Number:" | awk '{print $3}')"
                print_deep_data "${dev}_smart_serial" "$(smartctl -i "$dev" 2>/dev/null | grep "Serial Number:" | awk '{print $3}')"
                print_deep_data "${dev}_smart_health" "$(smartctl -H "$dev" 2>/dev/null | grep "overall-health" | awk -F: '{print $2}')"
                param_count=$((param_count + 3))
            fi
        done
    fi
    
    # NVMe специфично
    if check_tool nvme; then
        print_subsection "NVME_HEALTH"
        for nvme_dev in /dev/nvme[0-9]*; do
            if [[ -c "$nvme_dev" ]]; then
                nvme smart-log "$nvme_dev" 2>/dev/null | tee -a "$OUTPUT_FILE" || true
                param_count=$((param_count + 20))
            fi
        done
    fi
    
    # inode usage
    print_subsection "INODE_USAGE"
    df -i 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(df -i 2>/dev/null | tail -n +2 | wc -l)))
    
    increment_params "$param_count"
    log_info "Собрано параметров хранилища: $param_count"
}

#-------------------------------------------------------------------------------
# ЧАСТЬ 2: ЖЕЛЕЗО И ПРОШИВКИ (>1000 параметров)
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: CPU И МИКРОКОД (аппаратное)
#-------------------------------------------------------------------------------
scan_hardware_cpu() {
    print_section_header "HARDWARE_CPU_INFO"
    log_deep_section "Аппаратная информация о CPU"
    
    local param_count=0
    
    # dmidecode processor
    print_subsection "DMI_PROCESSOR"
    if check_tool dmidecode; then
        dmidecode -t processor 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t processor 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # lscpu расширенный
    print_subsection "LSCPU_EXTENDED"
    lscpu -e 2>/dev/null | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(lscpu -e 2>/dev/null | wc -l)))
    
    # CPUID если доступен
    if check_tool cpuid; then
        print_subsection "CPUID_RAW"
        cpuid 2>/dev/null | head -100 | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + 100))
    fi
    
    # turbostat если доступен
    if check_tool turbostat; then
        print_subsection "TURBOSTAT"
        turbostat --show Core,CPU,Avg_MHz,Busy%,Bzy_MHz,Totl_C0%,AvgWatt,PkgTmp,RAMWatt --interval 1 --num_iterations 1 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + 10))
    fi
    
    increment_params "$param_count"
    log_info "Собрано аппаратных параметров CPU: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: BIOS/UEFI И МАТЕРИНСКАЯ ПЛАТА
#-------------------------------------------------------------------------------
scan_bios_uefi() {
    print_section_header "BIOS_UEFI_INFO"
    log_deep_section "Информация о BIOS/UEFI и материнской плате"
    
    local param_count=0
    
    # dmidecode bios
    print_subsection "DMI_BIOS"
    if check_tool dmidecode; then
        dmidecode -t bios 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t bios 2>/dev/null | grep -c . || echo 0)))
        
        # baseboard
        print_subsection "DMI_BASEBOARD"
        dmidecode -t baseboard 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t baseboard 2>/dev/null | grep -c . || echo 0)))
        
        # system
        print_subsection "DMI_SYSTEM"
        dmidecode -t system 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t system 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # EFI переменные
    print_subsection "EFI_INFO"
    if [[ -d /sys/firmware/efi ]]; then
        print_data "EFI_detected: yes"
        print_data "fw_platform_size: $(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)"
        param_count=$((param_count + 2))
        
        # Secure Boot
        if [[ -f /sys/firmware/efi/vars/SecureBoot-*/data ]]; then
            print_data "SecureBoot: detected"
            param_count=$((param_count + 1))
        fi
    else
        print_data "EFI_detected: no (legacy BIOS)"
        param_count=$((param_count + 1))
    fi
    
    # efibootmgr
    if check_tool efibootmgr; then
        print_subsection "EFI_BOOT_ENTRIES"
        efibootmgr -v 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(efibootmgr -v 2>/dev/null | wc -l)))
    fi
    
    # mokutil для Secure Boot
    if check_tool mokutil; then
        print_subsection "SECURE_BOOT_STATUS"
        mokutil --sb-state 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(mokutil --sb-state 2>/dev/null | wc -l)))
    fi
    
    # DMI через sysfs
    print_subsection "DMI_SYSFS"
    for f in /sys/class/dmi/id/*; do
        if [[ -f "$f" && -r "$f" ]]; then
            print_deep_data "dmi_$(basename $f)" "$(cat "$f" 2>/dev/null)"
            param_count=$((param_count + 1))
        fi
    done
    
    increment_params "$param_count"
    log_info "Собрано параметров BIOS/UEFI: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: ОЗУ (аппаратное)
#-------------------------------------------------------------------------------
scan_hardware_ram() {
    print_section_header "HARDWARE_RAM_INFO"
    log_deep_section "Аппаратная информация об ОЗУ"
    
    local param_count=0
    
    # dmidecode memory
    print_subsection "DMI_MEMORY"
    if check_tool dmidecode; then
        dmidecode -t memory 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t memory 2>/dev/null | grep -c . || echo 0)))
        
        # type 17 - DIMM details
        print_subsection "DMI_DIMM_DETAILS"
        dmidecode -t 17 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(dmidecode -t 17 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # EDAC ошибки
    print_subsection "EDAC_ERRORS"
    if check_tool edac-util; then
        edac-util -v 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(edac-util -v 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # ras-mc-ctl
    if check_tool ras-mc-ctl; then
        print_subsection "RAS_MEMORY_CONTROLLER"
        ras-mc-ctl 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(ras-mc-ctl 2>/dev/null | grep -c . || echo 0)))
    fi
    
    increment_params "$param_count"
    log_info "Собрано параметров RAM: $param_count"
}

#-------------------------------------------------------------------------------
# СКАНИРОВАНИЕ: GPU И ВИДЕО
#-------------------------------------------------------------------------------
scan_hardware_gpu() {
    print_section_header "HARDWARE_GPU_INFO"
    log_deep_section "Информация о GPU и видео"
    
    local param_count=0
    
    # lspci VGA
    print_subsection "PCI_VIDEO"
    lspci -vvv 2>/dev/null | grep -A30 -i vga | tee -a "$OUTPUT_FILE" || true
    param_count=$((param_count + $(lspci -vvv 2>/dev/null | grep -A30 -i vga | wc -l)))
    
    # NVIDIA если есть
    if check_tool nvidia-smi; then
        print_subsection "NVIDIA_SMI"
        nvidia-smi -q 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + $(nvidia-smi -q 2>/dev/null | grep -c . || echo 0)))
    fi
    
    # Intel GPU
    if check_tool intel_gpu_top; then
        print_subsection "INTEL_GPU_FREQ"
        cat /sys/class/drm/card*/gt_*freq* 2>/dev/null | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + 5))
    fi
    
    # OpenGL info
    if check_tool glxinfo; then
        print_subsection "OPENGL_INFO"
        glxinfo 2>/dev/null | grep -E "vendor|renderer|version" | tee -a "$OUTPUT_FILE" || true
        param_count=$((param_count + 10))
    fi
    
    # DRM устройства
    print_subsection "DRM_DEVICES"
    for card in /sys/class/drm/card*; do
        if [[ -d "$card" ]]; then
            local card_name=$(basename "$card")
            print_deep_data "${card_name}_status" "$(cat "$card/status" 2>/dev/null)"
            print_deep_data "${card_name}_vendor" "$(cat "$card/device/vendor" 2>/dev/null)"
            print_deep_data "${card_name}_device" "$(cat "$card/device/device" 2>/dev/null)"
            param_count=$((param_count + 3))
        fi
    done
    
    increment_params "$param_count"
    log_info "Собрано параметров GPU: $param_count"
}

