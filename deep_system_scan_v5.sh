#!/bin/bash
#===============================================================================
# DEEP SYSTEM SCAN v5.0 - Безопасная диагностика Linux для ИИ-анализа
# ТОЛЬКО ЧТЕНИЕ: Никаких изменений в системе
# Версия 5.0: Полный реестр драйверов, глубокая диагностика железа, 
#             кросс-дистрибутивность, расширенные запреты
#===============================================================================
set -o pipefail

#-------------------------------------------------------------------------------
# КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
readonly VERSION="5.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly HOSTNAME="$(hostname)"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUTPUT_FILE=""
SCAN_LEVEL=0

# Счётчики проблем для итоговой сводки
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()

# Универсальные запреты (добавляются всегда)
declare -a UNIVERSAL_PROHIBITIONS=(
    "[НЕ ДЕЛАТЬ] Менять права на /etc рекурсивно | Риск нарушения работы системы | Использовать точечные chmod только при необходимости"
    "[НЕ ДЕЛАТЬ] Отключать systemd-resolved без fallback DNS | Потеря сетевого доступа | Сначала настроить альтернативный DNS"
    "[НЕ ДЕЛАТЬ] Чистить /var/log вручную через rm | Нарушение логирования и отладки | Использовать logrotate или journalctl --vacuum"
    "[НЕ ДЕЛАТЬ] Удалять dkms пакеты без проверки зависимостей | Поломка модулей ядра | Проверить: dkms status перед удалением"
    "[НЕ ДЕЛАТЬ] Запускать fsck на смонтированном корне | Риск повреждения ФС | Загрузиться с LiveUSB"
    "[НЕ ДЕЛАТЬ] Удалять /lib/modules/\$(uname -r) | Система не загрузится | Использовать autoremove"
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
        timeout 10 bash -c "$cmd" 2>/dev/null
    else
        bash -c "$cmd" 2>/dev/null
    fi
}

# Безопасное выполнение с sudo (без интерактивного запроса)
safe_sudo_cmd() {
    local cmd="$*"
    if [[ $EUID -eq 0 ]]; then
        safe_cmd "$cmd"
    elif command -v sudo &>/dev/null && sudo -n true &>/dev/null 2>&1; then
        safe_cmd "sudo $cmd"
    else
        echo "[NEEDS_ROOT]"
        return 1
    fi
}

# Проверка наличия утилиты
check_tool() {
    local tool="$1"
    if command -v "$tool" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Добавление проблемы в список
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
# ПОДГОТОВКА ДИРЕКТОРИИ ВЫВОДА
#-------------------------------------------------------------------------------
prepare_output_dir() {
    local desktop_dirs=("$HOME/Desktop" "$HOME/Рабочий_стол")
    local target_dir=""
    
    for dir in "${desktop_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            target_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$target_dir" ]]; then
        # Создаём Desktop если нет ни одного
        target_dir="$HOME/Desktop"
        if mkdir -p "$target_dir" 2>/dev/null; then
            echo "ℹ️  Создана директория: $target_dir" >&2
        else
            target_dir="$HOME"
            echo "⚠️  Не удалось создать Desktop, используем: $target_dir" >&2
        fi
    fi
    
    OUTPUT_FILE="${target_dir}/DEEP_SCAN_${HOSTNAME}_${TIMESTAMP}.log"
    echo "📁 Отчёт будет сохранён: $OUTPUT_FILE" >&2
}

#-------------------------------------------------------------------------------
# МЕНЮ ВЫБОРА УРОВНЯ СКАНИРОВАНИЯ
#-------------------------------------------------------------------------------
show_scan_menu() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║         DEEP SYSTEM SCAN v5.0 - Выбор уровня диагностики     ║
╠══════════════════════════════════════════════════════════════╣
║  [1] Минимальный: ядро, CPU/RAM, базовые логи, uptime        ║
║  [2] Средний: + службы, пакеты, сеть, конфиги, SMART, users  ║
║  [3] Тотальный: + валидация, безопасность, контейнеры, всё   ║
╚══════════════════════════════════════════════════════════════╝
EOF
    
    while true; do
        read -rp "Выберите уровень сканирования [1-3]: " choice
        case "$choice" in
            1) SCAN_LEVEL=1; echo "✅ Выбран режим: МИНИМАЛЬНЫЙ"; break ;;
            2) SCAN_LEVEL=2; echo "✅ Выбран режим: СРЕДНИЙ"; break ;;
            3) SCAN_LEVEL=3; echo "✅ Выбран режим: ТОТАЛЬНЫЙ"; break ;;
            *) echo "❌ Неверный выбор. Введите 1, 2 или 3." ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# УТИЛИТЫ ВЫВОДА
#-------------------------------------------------------------------------------
print_section_header() {
    echo ""
    echo "## [$1]"
    echo ""
}

print_subsection() {
    echo "### [$1]"
}

print_status() {
    echo "• STATUS: $1"
}

print_data() {
    echo "• DATA: $1"
}

print_issues() {
    if [[ -n "$1" ]]; then
        echo "• ISSUES_FOUND: $1"
    fi
}

print_raw_logs() {
    if [[ -n "$1" ]]; then
        echo "• RAW_LOGS:"
        echo "$1" | head -20
    fi
}

#-------------------------------------------------------------------------------
# ОПРЕДЕЛЕНИЕ ПАКЕТНОГО МЕНЕДЖЕРА
#-------------------------------------------------------------------------------
detect_package_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

PKG_MANAGER="$(detect_package_manager)"

#-------------------------------------------------------------------------------
# БАЗОВЫЕ ФУНКЦИИ (уровень 1+)
#-------------------------------------------------------------------------------
scan_basic_info() {
    print_section_header "BASIC_SYSTEM_INFO"
    
    print_subsection "KERNEL_AND_UPTIME"
    local kernel_ver
    kernel_ver="$(uname -r)"
    local uptime_info
    uptime_info="$(safe_cmd 'uptime -p' || uptime)"
    print_data "Kernel: $kernel_ver | Uptime: $uptime_info"
    
    print_subsection "CPU_INFO"
    local cpu_model
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'Unknown')"
    local cpu_cores
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
    print_data "Model: $cpu_model | Cores: $cpu_cores"
    
    print_subsection "MEMORY_INFO"
    local mem_total mem_avail
    mem_total="$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')"
    mem_avail="$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')"
    print_data "Total: ${mem_total}MB | Available: ${mem_avail}MB"
    
    print_subsection "DISK_SPACE"
    local disk_info
    disk_info="$(df -h / 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " used"}')"
    print_data "$disk_info"
}

#-------------------------------------------------------------------------------
# ПОЛНЫЙ РЕЕСТР ДРАЙВЕРОВ И ПРОШИВОК (уровень 2+)
#-------------------------------------------------------------------------------
scan_drivers_firmware() {
    print_section_header "DRIVERS_FIRMWARE"
    
    print_subsection "LOADED_MODULES_FULL"
    local modules_count
    modules_count="$(wc -l < /proc/modules 2>/dev/null || echo 0)"
    print_data "Loaded modules count: $modules_count"
    
    # Таблица драйверов: УСТРОЙСТВО | ДРАЙВЕР | ТИП | ВЕРСИЯ | СТАТУС | ЗАМЕЧАНИЯ
    echo "• DATA: MODULE_TABLE_START"
    echo "  УСТРОЙСТВО | ДРАЙВЕР | ТИП (open/prop) | ВЕРСИЯ | СТАТУС | ЗАМЕЧАНИЯ"
    echo "  ----------------------------------------------------------------------------"
    
    # Проприетарные драйверы
    local proprietary_modules
    proprietary_modules="$(lsmod 2>/dev/null | grep -iE 'nvidia|fglrx|broadcom|wl|vbox|virtualbox|vmware|akmod|rtl8723|rtl8821|rtl88x2' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$proprietary_modules" ]]; then
        echo "  GPU/WiFi | $proprietary_modules | prop | varies | loaded | Проприетарный драйвер"
        add_info "Proprietary drivers detected: $proprietary_modules | System integration"
    fi
    
    # Открытые драйверы GPU
    local open_gpu_drivers
    open_gpu_drivers="$(lsmod 2>/dev/null | grep -iE 'nouveau|radeon|amdgpu|i915|iris|i965' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$open_gpu_drivers" ]]; then
        echo "  GPU | $open_gpu_drivers | open | varies | loaded | Открытый драйвер GPU"
    fi
    
    # Аудио драйверы
    local audio_drivers
    audio_drivers="$(lsmod 2>/dev/null | grep -E '^snd_hda_intel|^snd_sof|^snd_pci_acp' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$audio_drivers" ]]; then
        echo "  Audio | $audio_drivers | open | varies | loaded | Драйвер аудио"
    else
        audio_drivers="$(lsmod 2>/dev/null | grep -E '^snd_' | head -3 | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
        if [[ -n "$audio_drivers" ]]; then
            echo "  Audio | $audio_drivers | open | varies | loaded | Драйвер аудио"
        fi
    fi
    
    # Сетевые драйверы
    local net_drivers
    net_drivers="$(lsmod 2>/dev/null | grep -iE 'e1000|e1000e|igb|ixgbe|r8169|r8152|atlantic|mlx4|mlx5|bnxt_en|ena|virtio_net' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$net_drivers" ]]; then
        echo "  Network | $net_drivers | open | varies | loaded | Драйвер сети"
    fi
    
    # WiFi драйверы
    local wifi_drivers
    wifi_drivers="$(lsmod 2>/dev/null | grep -iE 'iwlwifi|ath9k|ath10k|ath11k|mt76|rt2800|rt2x00|brcmfmac|mwifiex' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$wifi_drivers" ]]; then
        echo "  WiFi | $wifi_drivers | open | varies | loaded | Драйвер WiFi"
    fi
    
    # Storage контроллеры
    local storage_drivers
    storage_drivers="$(lsmod 2>/dev/null | grep -iE 'ahci|nvme|megaraid|mpt3sas|hpsa|qla2xxx|lpfc' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$storage_drivers" ]]; then
        echo "  Storage | $storage_drivers | open | varies | loaded | Контроллер хранения"
    fi
    
    # Touchpad драйверы
    local touchpad_drivers
    touchpad_drivers="$(lsmod 2>/dev/null | grep -iE 'synaptics|psmouse|hid_multitouch|i2c_hid' | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$touchpad_drivers" ]]; then
        echo "  Touchpad | $touchpad_drivers | open | varies | loaded | Драйвер тачпада"
    fi
    
    echo "  ----------------------------------------------------------------------------"
    echo "• DATA: MODULE_TABLE_END"
    
    print_subsection "DKMS_STATUS_DETAILED"
    if check_tool dkms; then
        local dkms_status
        dkms_status="$(safe_sudo_cmd 'dkms status' 2>/dev/null)"
        if [[ "$dkms_status" != "[NEEDS_ROOT]" && -n "$dkms_status" ]]; then
            print_data "$dkms_status"
            
            # Проверка версий модулей и ядра
            local current_kernel
            current_kernel="$(uname -r)"
            if echo "$dkms_status" | grep -qi "error\|mismatch\|bad tree"; then
                print_issues "DKMS version mismatch or errors detected"
                add_warning "DKMS issues found | Check kernel module compatibility"
                add_prohibition "[НЕ ДЕЛАТЬ] Обновлять ядро до устранения DKMS ошибок | Риск потери модулей | Сначала исправить: dkms autoinstall"
            fi
            
            # Проверка заголовков ядра
            local headers_installed=false
            if [[ -d "/lib/modules/$current_kernel/build" ]] || [[ -d "/usr/src/linux-headers-$current_kernel" ]]; then
                headers_installed=true
                print_data "Kernel headers: Installed for $current_kernel"
            else
                print_data "Kernel headers: Not found for $current_kernel"
                add_warning "Kernel headers missing | DKMS modules may fail to build"
            fi
        else
            print_status "SKIPPED [NEEDS_ROOT or DKMS not installed]"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: dkms]"
    fi
    
    print_subsection "GPU_DRIVERS_DETAILED"
    local gpu_driver gpu_vendor gpu_info
    if check_tool lspci; then
        gpu_info="$(lspci -k 2>/dev/null | grep -A3 -i 'vga\|3d\|display' | head -20)"
        if [[ -n "$gpu_info" ]]; then
            gpu_driver="$(echo "$gpu_info" | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
            gpu_vendor="$(echo "$gpu_info" | grep -iE 'nvidia|intel|amd|advanced micro devices' | head -1)"
            print_data "GPU Vendor: ${gpu_vendor:-Unknown} | Driver: ${gpu_driver:-N/A}"
            
            # Определение типа драйвера
            if [[ "$gpu_driver" =~ nvidia|fglrx ]]; then
                print_data "Driver type: Proprietary"
            elif [[ "$gpu_driver" =~ nouveau|radeon|amdgpu|i915|iris ]]; then
                print_data "Driver type: Open source"
            fi
        else
            print_data "GPU: Not detected via lspci"
        fi
        
        # NVIDIA специфичная информация
        if check_tool nvidia-smi; then
            local nvidia_info
            nvidia_info="$(timeout 10 nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -3)"
            if [[ -n "$nvidia_info" ]]; then
                print_data "NVIDIA GPU(s): $nvidia_info"
            fi
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: lspci]"
    fi
    
    print_subsection "NETWORK_DRIVERS_DETAILED"
    if check_tool lspci && check_tool ip; then
        local wifi_driver eth_driver
        wifi_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'wireless\|network' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
        eth_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'ethernet' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
        print_data "WiFi: ${wifi_driver:-N/A} | Ethernet: ${eth_driver:-N/A}"
        
        # USB WiFi адаптеры
        if check_tool lsusb; then
            local usb_wifi
            usb_wifi="$(lsusb 2>/dev/null | grep -iE 'wireless|802.11|wifi' | head -3)"
            if [[ -n "$usb_wifi" ]]; then
                print_data "USB WiFi adapters: $usb_wifi"
            fi
        fi
    fi
    
    print_subsection "AUDIO_DRIVERS_DETAILED"
    local audio_driver
    audio_driver="$(lsmod 2>/dev/null | grep -E '^snd_' | head -5 | awk '{print $1}' | tr '\\n' ',' | sed 's/,$//')"
    if [[ -n "$audio_driver" ]]; then
        print_data "Audio modules: $audio_driver"
        
        # Определение основного драйвера
        if [[ "$audio_driver" =~ snd_hda_intel ]]; then
            print_data "Primary audio driver: Intel HDA (common for desktops/laptops)"
        elif [[ "$audio_driver" =~ snd_sof ]]; then
            print_data "Primary audio driver: Sound Open Firmware (modern Intel platforms)"
        fi
    else
        print_data "Audio modules: None loaded"
    fi
    
    print_subsection "CPU_MICROCODE_DETAILED"
    local microcode_info
    microcode_info="$(dmesg 2>/dev/null | grep -i 'microcode' | tail -3)"
    if [[ -n "$microcode_info" ]]; then
        print_data "$microcode_info"
        
        # Проверка на обновления микрокода
        if echo "$microcode_info" | grep -qi 'updated\|revised'; then
            print_data "Microcode: Updated successfully"
        elif echo "$microcode_info" | grep -qi 'failed\|error'; then
            add_warning "Microcode update failed | Check BIOS/UEFI and intel-microcode/amd-microcode package"
        fi
    else
        # Проверка через файл
        if [[ -f /proc/cpuinfo ]]; then
            local cpu_mcode
            cpu_mcode="$(grep -i 'microcode' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
            if [[ -n "$cpu_mcode" ]]; then
                print_data "Microcode version: $cpu_mcode"
            else
                print_data "Microcode: Information not available"
            fi
        fi
    fi
    
    # Проверка наличия файлов микрокода
    local ucode_files=""
    if [[ -d /lib/firmware/intel-ucode ]]; then
        ucode_files="Intel ucode: $(ls /lib/firmware/intel-ucode 2>/dev/null | wc -l) files"
    fi
    if [[ -d /lib/firmware/amd-ucode ]]; then
        ucode_files="${ucode_files:+$ucode_files | }AMD ucode: $(ls /lib/firmware/amd-ucode 2>/dev/null | wc -l) files"
    fi
    if [[ -n "$ucode_files" ]]; then
        print_data "Firmware files: $ucode_files"
    fi
}

#-------------------------------------------------------------------------------
# ГЛУБОКАЯ ДИАГНОСТИКА СОСТОЯНИЯ ЖЕЛЕЗА (уровень 2+)
#-------------------------------------------------------------------------------
scan_hardware_health() {
    print_section_header "HARDWARE_HEALTH"
    
    print_subsection "SMART_DISK_STATUS_DETAILED"
    if check_tool smartctl; then
        local disks
        disks="$(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/(sd|nvme|hd)')"
        local disk_issues=""
        for disk in $disks; do
            local smart_data
            smart_data="$(safe_sudo_cmd "smartctl -A $disk" 2>/dev/null)"
            if [[ "$smart_data" != "[NEEDS_ROOT]" && -n "$smart_data" ]]; then
                # Извлечение критических атрибутов SMART
                local reallocated pending udma power_hours temp
                reallocated="$(echo "$smart_data" | grep -iE 'Reallocated_Sector_Ct|Reallocated_Event_Count' | awk '{print $NF}' | head -1)"
                pending="$(echo "$smart_data" | grep -i 'Current_Pending_Sector' | awk '{print $NF}')"
                udma="$(echo "$smart_data" | grep -i 'UDMA_CRC_Error_Count' | awk '{print $NF}')"
                power_hours="$(echo "$smart_data" | grep -i 'Power_On_Hours' | awk '{print $NF}')"
                temp="$(echo "$smart_data" | grep -iE 'Temperature_Celsius|Temperature_Internal' | awk '{print $NF}' | head -1)"
                
                local risk=""
                local issues_list=""
                
                # Проверка критических значений
                if [[ "${reallocated:-0}" -gt 0 ]]; then
                    risk="[DISK_RISK]"
                    issues_list="${issues_list}Realloc=${reallocated} "
                    add_critical "Disk $disk: ${reallocated} Reallocated Sectors | Data integrity risk | Backup immediately and consider replacement"
                    add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать диск $disk | Найден ${reallocated} переназначенных секторов | Срочно сделать backup и планировать замену"
                fi
                
                if [[ "${pending:-0}" -gt 0 ]]; then
                    risk="[DISK_RISK]"
                    issues_list="${issues_list}Pending=${pending} "
                    add_critical "Disk $disk: ${pending} Pending Sectors | Imminent failure possible | Backup immediately"
                fi
                
                if [[ "${udma:-0}" -gt 0 ]]; then
                    risk="[DISK_RISK]"
                    issues_list="${issues_list}UDMA_CRC=${udma} "
                    add_warning "Disk $disk: ${udma} UDMA CRC Errors | Cable/connection issue likely | Check SATA cable"
                fi
                
                if [[ -n "$risk" ]]; then
                    print_data "$disk $risk: Realloc=${reallocated:-0}, Pending=${pending:-0}, UDMA=${udma:-0}, PowerOn=${power_hours:-N/A}h, Temp=${temp:-N/A}°C | Issues: ${issues_list:-none}"
                else
                    print_data "$disk OK: Realloc=0, Pending=0, UDMA=0, PowerOn=${power_hours:-N/A}h, Temp=${temp:-N/A}°C"
                fi
            else
                print_status "SKIPPED [NEEDS_ROOT for smartctl]"
                break
            fi
        done
        if [[ -z "$disk_issues" ]]; then
            print_data "All checked disks: No critical SMART values"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: smartctl]"
        add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать установку smartmontools | Невозможно мониторить здоровье дисков | Установить: apt install smartmontools"
    fi
    
    print_subsection "BATTERY_STATUS_DETAILED"
    if [[ -d /sys/class/power_supply ]]; then
        local battery_found=false
        for bat in /sys/class/power_supply/BAT*; do
            if [[ -d "$bat" ]]; then
                battery_found=true
                local capacity full_design current cycles status voltage
                capacity="$(cat "$bat/capacity" 2>/dev/null || echo 'N/A')"
                full_design="$(cat "$bat/energy_full_design" 2>/dev/null || cat "$bat/charge_full_design" 2>/dev/null || echo 'N/A')"
                current="$(cat "$bat/energy_full" 2>/dev/null || cat "$bat/charge_full" 2>/dev/null || echo 'N/A')"
                cycles="$(cat "$bat/cycle_count" 2>/dev/null || echo 'N/A')"
                status="$(cat "$bat/status" 2>/dev/null || echo 'N/A')"
                voltage="$(cat "$bat/voltage_now" 2>/dev/null | awk '{printf "%.2fV", $1/1000000}' || echo 'N/A')"
                
                local wear="N/A"
                if [[ "$full_design" != "N/A" && "$current" != "N/A" ]]; then
                    if [[ "$full_design" =~ ^[0-9]+$ ]] && [[ "$full_design" -gt 0 ]]; then
                        wear="$(( (current * 100) / full_design ))%"
                        if [[ "${wear%\%}" -lt 80 ]]; then
                            add_warning "Battery wear detected | Capacity at $wear | Consider calibration or replacement"
                            add_prohibition "[НЕ ДЕЛАТЬ] Полностью разряжать изношенную батарею | Риск глубокого разряда | Держать заряд 20-80%"
                        elif [[ "${wear%\%}" -lt 50 ]]; then
                            add_critical "Battery severely worn | Capacity at $wear | Replace soon"
                            add_prohibition "[НЕ ДЕЛАТЬ] Использовать как основной источник питания | Риск внезапного отключения | Заменить батарею"
                        fi
                    fi
                fi
                
                print_data "Capacity: ${capacity}% | Wear Level: $wear | Cycles: ${cycles} | Status: $status | Voltage: $voltage"
            fi
        done
        if [[ "$battery_found" == false ]]; then
            print_data "No battery detected (desktop system?)"
        fi
    else
        print_status "SKIPPED [No power_supply class]"
    fi
    
    print_subsection "THERMAL_SENSORS_DETAILED"
    local thermal_zones=0
    local high_temp_detected=false
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            thermal_zones=$((thermal_zones + 1))
            local temp_val
            temp_val="$(cat "$zone" 2>/dev/null)"
            local temp_c=$((temp_val / 1000))
            local zone_name
            zone_name="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Zone$thermal_zones")"
            
            if [[ $temp_c -gt 90 ]]; then
                high_temp_detected=true
                add_critical "Critical temperature on $zone_name: ${temp_c}°C | Immediate shutdown recommended | Check cooling system"
                add_prohibition "[НЕ ДЕЛАТЬ] Продолжать работу при температуре >90°C | Риск повреждения железа | Немедленно охладить систему"
                print_data "$zone_name: ${temp_c}°C [CRITICAL]"
            elif [[ $temp_c -gt 85 ]]; then
                high_temp_detected=true
                add_warning "High temperature on $zone_name: ${temp_c}°C | Check cooling system"
                print_data "$zone_name: ${temp_c}°C [HIGH]"
            else
                print_data "$zone_name: ${temp_c}°C"
            fi
        fi
    done
    if [[ $thermal_zones -eq 0 ]]; then
        print_data "No thermal sensors found"
    fi
    
    # Проверка троттлинга
    print_subsection "THERMAL_THROTTLING_HISTORY"
    local throttle_events
    throttle_events="$(dmesg 2>/dev/null | grep -iE 'thermal throttling|package temperature|core temperature' | tail -5)"
    if [[ -n "$throttle_events" ]]; then
        print_issues "Thermal throttling events detected"
        print_raw_logs "$throttle_events"
        add_warning "CPU thermal throttling occurred | Performance impacted | Improve cooling"
    else
        print_data "No thermal throttling events in dmesg"
    fi
    
    # RPM вентиляторов (если доступно)
    print_subsection "FAN_SPEED_SENSORS"
    local fan_found=false
    for fan in /sys/class/hwmon/hwmon*/fan*_input; do
        if [[ -f "$fan" ]]; then
            fan_found=true
            local fan_rpm
            fan_rpm="$(cat "$fan" 2>/dev/null)"
            local fan_label
            fan_label="$(cat "${fan%_input}_label" 2>/dev/null || echo "Fan")"
            if [[ "$fan_rpm" =~ ^[0-9]+$ ]] && [[ "$fan_rpm" -gt 0 ]]; then
                print_data "$fan_label: ${fan_rpm} RPM"
            else
                print_data "$fan_label: Stopped or sensor error"
            fi
        fi
    done
    if [[ "$fan_found" == false ]]; then
        print_data "Fan speed sensors: Not available"
    fi
    
    print_subsection "PCIE_ACPI_ERRORS_DETAILED"
    local pcie_errors
    pcie_errors="$(dmesg 2>/dev/null | grep -iE 'aer|pci bus error|acpi error|pcieport' | tail -10)"
    if [[ -n "$pcie_errors" ]]; then
        print_issues "PCIe/ACPI errors detected"
        print_raw_logs "$pcie_errors"
        add_warning "PCIe/ACPI errors in dmesg | Check hardware connections and firmware"
        add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать PCIe AER ошибки | Возможна нестабильность | Обновить BIOS/UEFI и проверить устройства"
        
        # Дополнительная проверка через lspci
        if check_tool lspci; then
            local pcie_link_status
            pcie_link_status="$(lspci -vvv 2>/dev/null | grep -iE 'LnkSta:|AER|Error' | head -10)"
            if [[ -n "$pcie_link_status" ]]; then
                print_data "PCIe link status: $pcie_link_status"
            fi
        fi
    else
        print_data "No PCIe/ACPI errors detected"
    fi
    
    print_subsection "ECC_RAM_STATUS_DETAILED"
    if check_tool edac-util; then
        local ecc_status
        ecc_status="$(safe_sudo_cmd 'edac-util -v' 2>/dev/null)"
        if [[ "$ecc_status" != "[NEEDS_ROOT]" && -n "$ecc_status" ]]; then
            print_data "$ecc_status"
            
            # Проверка на исправленные ошибки
            if echo "$ecc_status" | grep -qiE 'corrected|uncorrected'; then
                add_warning "ECC memory errors detected | Review EDAC report"
            fi
        else
            print_status "SKIPPED [NEEDS_ROOT]"
        fi
    else
        local ecc_dmesg
        ecc_dmesg="$(dmesg 2>/dev/null | grep -iE 'ecc|corrected error|uncorrected error|mce' | tail -5)"
        if [[ -n "$ecc_dmesg" ]]; then
            print_data "ECC events: $ecc_dmesg"
            if echo "$ecc_dmesg" | grep -qi 'uncorrected'; then
                add_critical "Uncorrected ECC errors detected | Hardware failure | Replace RAM"
                add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать uncorrected ECC ошибки | Риск порчи данных | Заменить память"
            fi
        else
            print_data "ECC: No data available (may not be supported on this system)"
        fi
    fi
    
    print_subsection "NVME_HEALTH"
    if check_tool nvme; then
        local nvme_drives
        nvme_drives="$(ls /dev/nvme* 2>/dev/null | grep -v 'n')"
        for drive in $nvme_drives; do
            local nvme_smart
            nvme_smart="$(safe_sudo_cmd "nvme smart-log $drive" 2>/dev/null | head -20)"
            if [[ "$nvme_smart" != "[NEEDS_ROOT]" && -n "$nvme_smart" ]]; then
                print_data "$drive: $nvme_smart"
            fi
        done
    else
        print_status "SKIPPED [TOOL_MISSING: nvme-cli]"
    fi
}

#-------------------------------------------------------------------------------
# СИСТЕМНЫЕ СЛУЖБЫ И ПАКЕТЫ (уровень 2+)
#-------------------------------------------------------------------------------
scan_services_packages() {
    print_section_header "SERVICES_AND_PACKAGES"
    
    print_subsection "SYSTEMD_SERVICES"
    local failed_services
    failed_services="$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$failed_services" ]]; then
        print_issues "Failed services: $failed_services"
        add_warning "Failed systemd services: $failed_services | Run 'systemctl status <service>'"
        add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать failed сервисы | Возможны проблемы в работе системы | Изучить: systemctl status <сервис>"
    else
        print_data "All systemd services: OK"
    fi
    
    print_subsection "PACKAGE_MANAGER_STATUS"
    case "$PKG_MANAGER" in
        apt)
            local broken_packages
            broken_packages="$(safe_sudo_cmd 'apt-get check' 2>&1 | grep -i 'broken\|error' || echo '')"
            if [[ -n "$broken_packages" ]]; then
                print_issues "Broken packages detected"
                print_data "$broken_packages"
                add_warning "Broken APT packages | Run 'apt --fix-broken install'"
                add_prohibition "[НЕ ДЕЛАТЬ] Удалять пакеты вручную из /var/lib/dpkg | Нарушит зависимости | Используй apt --fix-broken install"
            else
                print_data "APT package check: OK"
            fi
            
            local upgradable
            upgradable="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' | wc -l)"
            print_data "Upgradable packages: $upgradable"
            
            # Проверка обновлений безопасности
            if check_tool unattended-upgrades; then
                print_data "Unattended upgrades: Installed"
            else
                print_data "Unattended upgrades: Not installed (security updates may be delayed)"
            fi
            ;;
        dnf)
            local broken_dnf
            broken_dnf="$(safe_sudo_cmd 'dnf check' 2>&1 | grep -i 'error\|broken' || echo '')"
            if [[ -n "$broken_dnf" ]]; then
                print_issues "DNF issues detected"
                add_warning "DNF package issues | Review with 'dnf check'"
            else
                print_data "DNF check: OK"
            fi
            
            local upgradable_dnf
            upgradable_dnf="$(dnf check-update 2>/dev/null | grep -c '.' || echo '0')"
            print_data "Upgradable packages: $upgradable_dnf"
            ;;
        pacman)
            local orphaned
            orphaned="$(pacman -Qtdq 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
            if [[ -n "$orphaned" ]]; then
                print_data "Orphaned packages: $orphaned"
                add_info "Orphaned packages found | Review with 'pacman -Qtdq'"
            else
                print_data "Pacman: No orphaned packages"
            fi
            
            # Проверка частичных обновлений
            if [[ -f /var/lib/pacman/db.lck ]]; then
                add_warning "Pacman database locked | Possible interrupted update"
                add_prohibition "[НЕ ДЕЛАТЬ] Прерывать обновление pacman | Риск поломки системы | Дождаться завершения"
            fi
            ;;
        zypper)
            print_data "Zypper manager detected"
            local zypper_patches
            zypper_patches="$(zypper list-patches 2>/dev/null | grep -c 'needed' || echo '0')"
            print_data "Needed patches: $zypper_patches"
            ;;
        unknown)
            print_status "SKIPPED [Unknown package manager]"
            ;;
    esac
    
    print_subsection "SNAP_FLATPAK_APPARMOR"
    if check_tool snap; then
        local snap_count
        snap_count="$(snap list 2>/dev/null | tail -n +2 | wc -l)"
        print_data "Snap packages: $snap_count"
        
        # Проверка статуса snapd
        if systemctl is-active --quiet snapd 2>/dev/null; then
            print_data "Snapd service: Active"
        else
            print_data "Snapd service: Inactive"
        fi
    fi
    if check_tool flatpak; then
        local flatpak_count
        flatpak_count="$(flatpak list 2>/dev/null | wc -l)"
        print_data "Flatpak packages: $flatpak_count"
    fi
    if ! check_tool snap && ! check_tool flatpak; then
        print_data "Snap/Flatpak: Not installed"
    fi
    
    # Проверка других менеджеров пакетов
    print_subsection "OTHER_PACKAGE_MANAGERS"
    if check_tool pip3 || check_tool pip; then
        local pip_packages
        pip_packages="$(pip3 list 2>/dev/null | tail -n +3 | wc -l || pip list 2>/dev/null | tail -n +3 | wc -l)"
        print_data "Python pip packages: ~$pip_packages"
    fi
    if check_tool npm; then
        local npm_packages
        npm_packages="$(npm list -g --depth=0 2>/dev/null | tail -n +2 | wc -l)"
        print_data "Node.js npm global packages: ~$npm_packages"
    fi
    if check_tool cargo; then
        local cargo_packages
        cargo_packages="$(cargo install --list 2>/dev/null | tail -n +2 | wc -l)"
        print_data "Rust cargo packages: ~$cargo_packages"
    fi
}

#-------------------------------------------------------------------------------
# ВАЛИДАЦИЯ КОНФИГОВ И БЕЗОПАСНОСТЬ (уровень 3)
#-------------------------------------------------------------------------------
scan_config_validation() {
    print_section_header "CONFIG_VALIDATION"
    
    print_subsection "FSTAB_VALIDATION_ENHANCED"
    if [[ -f /etc/fstab ]]; then
        local fstab_issues=""
        # Проверка на дубликаты UUID
        local uuid_count
        uuid_count="$(grep -v '^#' /etc/fstab | grep -i 'uuid' | awk '{print $1}' | sort | uniq -d)"
        if [[ -n "$uuid_count" ]]; then
            fstab_issues="Duplicate UUIDs: $uuid_count | "
            add_critical "Duplicate UUIDs in /etc/fstab | May cause boot failures | Fix fstab entries"
            add_prohibition "[НЕ ДЕЛАТЬ] Загружаться с таким fstab | Риск неправильного монтирования | Исправить дубликаты UUID"
        fi
        
        # Проверка mount options для /tmp
        local tmp_opts
        tmp_opts="$(grep -E '\s/tmp\s' /etc/fstab | awk '{print $4}')"
        if [[ -n "$tmp_opts" && ! "$tmp_opts" =~ noexec ]]; then
            add_info "/tmp without noexec option | Security consideration | Add noexec,nosuid,nodev"
        fi
        
        # Проверка mount options для /home
        local home_opts
        home_opts="$(grep -E '\s/home\s' /etc/fstab | awk '{print $4}')"
        if [[ -n "$home_opts" && ! "$home_opts" =~ nosuid ]]; then
            add_info "/home without nosuid option | Security consideration | Add nosuid,nodev"
        fi
        
        # Проверка наличия всех точек монтирования
        local mount_points
        mount_points="$(grep -v '^#' /etc/fstab | grep -v '^$' | awk '{print $2}')"
        for mp in $mount_points; do
            if [[ ! -d "$mp" ]]; then
                fstab_issues="${fstab_issues}Mount point $mp does not exist | "
                add_warning "Mount point $mp in fstab does not exist | Create directory or fix fstab"
            fi
        done
        
        if [[ -z "$fstab_issues" ]]; then
            print_data "/etc/fstab: Basic validation OK"
        else
            print_issues "$fstab_issues"
        fi
    else
        print_status "SKIPPED [/etc/fstab not found]"
    fi
    
    print_subsection "SYSTEMD_UNIT_VALIDATION_ENHANCED"
    if check_tool systemd-analyze; then
        local verify_output
        verify_output="$(safe_sudo_cmd 'systemd-analyze verify' 2>&1 | head -15)"
        if [[ -n "$verify_output" && "$verify_output" != "[NEEDS_ROOT]" ]]; then
            if echo "$verify_output" | grep -qi "error\|warning"; then
                print_issues "Systemd unit validation issues"
                print_raw_logs "$verify_output"
                add_warning "Systemd unit warnings | Review with 'systemd-analyze verify'"
            else
                print_data "Systemd units: Validation OK"
            fi
        else
            print_status "SKIPPED [NEEDS_ROOT]"
        fi
        
        # Анализ времени загрузки
        local boot_time
        boot_time="$(systemd-analyze 2>/dev/null | head -1)"
        if [[ -n "$boot_time" ]]; then
            print_data "Boot time: $boot_time"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: systemd-analyze]"
    fi
    
    print_subsection "SYSCTL_HARDENING_ENHANCED"
    local sysctl_issues=""
    local syncookies
    syncookies="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo 'N/A')"
    if [[ "$syncookies" != "1" && "$syncookies" != "N/A" ]]; then
        sysctl_issues="tcp_syncookies=$syncookies | "
        add_warning "TCP syncookies disabled | DDoS vulnerability | Enable: sysctl -w net.ipv4.tcp_syncookies=1"
    fi
    
    local aslr
    aslr="$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo 'N/A')"
    if [[ "$aslr" != "2" && "$aslr" != "N/A" ]]; then
        sysctl_issues="${sysctl_issues}aslr=$aslr | "
        add_warning "ASLR not fully enabled | Security risk | Enable: sysctl -w kernel.randomize_va_space=2"
    fi
    
    local suid_dumpable
    suid_dumpable="$(sysctl -n fs.suid_dumpable 2>/dev/null || echo 'N/A')"
    if [[ "$suid_dumpable" != "0" && "$suid_dumpable" != "N/A" ]]; then
        sysctl_issues="${sysctl_issues}suid_dumpable=$suid_dumpable | "
        add_warning "SUID core dumps enabled | Information leak risk | Set: sysctl -w fs.suid_dumpable=0"
    fi
    
    # IPv6 privacy extensions
    local ipv6_privacy
    ipv6_privacy="$(sysctl -n net.ipv6.conf.all.use_tempaddr 2>/dev/null || echo 'N/A')"
    if [[ "$ipv6_privacy" == "0" ]]; then
        add_info "IPv6 privacy extensions disabled | Consider enabling for privacy"
    fi
    
    if [[ -z "$sysctl_issues" ]]; then
        print_data "Sysctl hardening: Basic checks OK"
    else
        print_issues "$sysctl_issues"
    fi
    
    print_subsection "HOSTS_RESOLV_VALIDATION_ENHANCED"
    if [[ -f /etc/hosts ]]; then
        local hosts_dup
        hosts_dup="$(grep -v '^#' /etc/hosts | grep -v '^$' | awk '{print $2}' | sort | uniq -d)"
        if [[ -n "$hosts_dup" ]]; then
            print_issues "Duplicate entries in /etc/hosts: $hosts_dup"
            add_warning "Duplicate /etc/hosts entries | May cause DNS issues"
        else
            print_data "/etc/hosts: No duplicates"
        fi
        
        # Проверка localhost записи
        if ! grep -q '127.0.0.1.*localhost' /etc/hosts; then
            add_warning "Missing localhost entry in /etc/hosts | Some applications may fail"
        fi
    fi
    
    if [[ -f /etc/resolv.conf ]]; then
        local nameservers
        nameservers="$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || echo '0')"
        print_data "DNS nameservers configured: $nameservers"
        
        # Проверка на дубликаты nameserver
        local ns_dup
        ns_dup="$(grep '^nameserver' /etc/resolv.conf | sort | uniq -d)"
        if [[ -n "$ns_dup" ]]; then
            print_data "Note: Duplicate nameserver entries found (usually harmless)"
        fi
        
        # Проверка systemd-resolved
        if [[ -L /etc/resolv.conf ]] && [[ "$(readlink /etc/resolv.conf)" =~ systemd-resolved ]]; then
            print_data "DNS managed by: systemd-resolved"
        fi
    fi
    
    print_subsection "JOURNAL_PERSISTENCE_LOGROTATE"
    if [[ -d /var/log/journal ]]; then
        local journal_size
        journal_size="$(du -sh /var/log/journal 2>/dev/null | cut -f1)"
        print_data "Persistent journal size: ${journal_size:-unknown}"
    else
        print_data "Journal: Volatile (not persistent across reboots)"
    fi
    
    if check_tool journalctl; then
        local journal_disk_usage
        journal_disk_usage="$(journalctl --disk-usage 2>/dev/null)"
        if [[ -n "$journal_disk_usage" ]]; then
            print_data "Journal disk usage: $journal_disk_usage"
        fi
    fi
    
    if check_tool logrotate; then
        if [[ -f /etc/logrotate.conf ]]; then
            print_data "Logrotate: Configured"
        else
            add_warning "Logrotate configuration missing | Logs may grow indefinitely"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: logrotate]"
    fi
    
    print_subsection "CRON_SYSTEMD_TIMERS_VALIDATION"
    local cron_jobs=0
    if [[ -d /etc/cron.d ]]; then
        cron_jobs=$((cron_jobs + $(ls -1 /etc/cron.d 2>/dev/null | wc -l)))
    fi
    for crontab in /var/spool/cron/crontabs/*; do
        if [[ -f "$crontab" ]]; then
            cron_jobs=$((cron_jobs + 1))
        fi
    done
    print_data "System cron jobs: $cron_jobs"
    
    # Проверка подозрительных cron заданий
    local suspicious_cron
    suspicious_cron="$(grep -rE 'curl.*\|.*bash|wget.*\|.*bash|nc.*-e|/dev/tcp' /etc/cron.* /var/spool/cron 2>/dev/null | head -5)"
    if [[ -n "$suspicious_cron" ]]; then
        add_critical "Suspicious cron jobs detected | Possible malware | Review: $suspicious_cron"
        add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать подозрительные cron задания | Возможна компрометация | Проверить содержимое"
    fi
    
    if check_tool systemctl; then
        local failed_timers
        failed_timers="$(systemctl list-timers --failed --no-pager 2>/dev/null | tail -n +3 | wc -l)"
        if [[ $failed_timers -gt 0 ]]; then
            print_issues "Failed systemd timers: $failed_timers"
            add_warning "Failed systemd timers | Review with 'systemctl list-timers --failed'"
        else
            print_data "Systemd timers: OK"
        fi
        
        # Проверка битых путей в timer юнитах
        local broken_timer_paths
        broken_timer_paths="$(systemctl list-timers --all --no-pager 2>/dev/null | grep -i 'unit.*not found' | head -5)"
        if [[ -n "$broken_timer_paths" ]]; then
            print_data "Broken timer paths detected: $broken_timer_paths"
        fi
    fi
}

#-------------------------------------------------------------------------------
# БЕЗОПАСНОСТЬ (уровень 3)
#-------------------------------------------------------------------------------
scan_security() {
    print_section_header "SECURITY_AUDIT"
    
    print_subsection "OPEN_PORTS_DETAILED"
    if check_tool ss; then
        local open_ports
        open_ports="$(ss -tuln 2>/dev/null | grep LISTEN | wc -l)"
        local port_details
        port_details="$(ss -tuln 2>/dev/null | grep LISTEN | awk '{print $5}' | sort -u | head -15 | tr '\n' ',' | sed 's/,$//')"
        print_data "Listening ports: $open_ports | $port_details"
        
        # Проверка на подозрительные порты
        local suspicious_ports
        suspicious_ports="$(ss -tuln 2>/dev/null | grep LISTEN | awk '{print $5}' | grep -E ':4444|:5555|:6666|:31337|:12345')"
        if [[ -n "$suspicious_ports" ]]; then
            add_critical "Suspicious listening ports detected | Possible backdoor | Investigate immediately"
            add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать подозрительные порты (4444, 5555, 31337) | Возможна компрометация | Проверить процессы"
        fi
    elif check_tool netstat; then
        local open_ports
        open_ports="$(netstat -tuln 2>/dev/null | grep LISTEN | wc -l)"
        print_data "Listening ports: $open_ports"
    else
        print_status "SKIPPED [TOOL_MISSING: ss/netstat]"
    fi
    
    print_subsection "FIREWALL_STATUS_DETAILED"
    local firewall_status="Not detected"
    if check_tool ufw; then
        local ufw_stat
        ufw_stat="$(ufw status 2>/dev/null | head -1)"
        if [[ "$ufw_stat" =~ "active" ]]; then
            firewall_status="UFW: Active"
        else
            firewall_status="UFW: Inactive"
            add_warning "UFW firewall inactive | Consider enabling for security"
        fi
    elif check_tool iptables; then
        local ipt_rules
        ipt_rules="$(safe_sudo_cmd 'iptables -L -n' 2>/dev/null | head -10)"
        if [[ "$ipt_rules" != "[NEEDS_ROOT]" && -n "$ipt_rules" ]]; then
            firewall_status="iptables: Rules configured"
        else
            firewall_status="iptables: [NEEDS_ROOT or no rules]"
        fi
    fi
    if check_tool nft; then
        local nft_rules
        nft_rules="$(safe_sudo_cmd 'nft list ruleset' 2>/dev/null | head -5)"
        if [[ "$nft_rules" != "[NEEDS_ROOT]" && -n "$nft_rules" ]]; then
            firewall_status="nftables: Active"
        fi
    fi
    print_data "$firewall_status"
    
    print_subsection "SUID_SGID_FILES_DETAILED"
    local suid_files
    suid_files="$(find /usr /bin /sbin -perm -4000 -type f 2>/dev/null | head -15 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$suid_files" ]]; then
        print_data "SUID files (sample): $suid_files"
        if echo "$suid_files" | grep -qvE 'sudo|su|passwd|mount|umount|newgrp|chsh|gpasswd|wall|write|ssh-keysign|pkexec'; then
            add_warning "Unusual SUID files detected | Review for security"
        fi
    else
        print_data "SUID files: None found in standard paths"
    fi
    
    local sgid_files
    sgid_files="$(find /usr /bin /sbin -perm -2000 -type f 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$sgid_files" ]]; then
        print_data "SGID files (sample): $sgid_files"
    fi
    
    print_subsection "WORLD_WRITABLE_FILES_DETAILED"
    local world_writable
    world_writable="$(find /etc /usr /var -type f -perm -0002 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$world_writable" ]]; then
        print_issues "World-writable files: $world_writable"
        add_critical "World-writable files in system dirs | Security risk | chmod o-w <files>"
        add_prohibition "[НЕ ДЕЛАТЬ] Оставлять world-writable файлы в /etc /usr | Риск компрометации | Исправить права: chmod o-w"
    else
        print_data "World-writable files: None in /etc /usr /var"
    fi
    
    # Поиск world-writable директорий без sticky bit
    local ww_dirs
    ww_dirs="$(find /tmp /var/tmp -type d -perm -0002 ! -perm -1000 2>/dev/null | head -5)"
    if [[ -n "$ww_dirs" ]]; then
        add_warning "World-writable directories without sticky bit: $ww_dirs"
    fi
    
    print_subsection "RECENT_LOGINS_SUDO_USAGE"
    local recent_logins
    recent_logins="$(last -5 2>/dev/null | head -5)"
    if [[ -n "$recent_logins" ]]; then
        print_data "Last 5 logins recorded"
        print_raw_logs "$recent_logins"
    else
        print_data "Login history: Not available"
    fi
    
    # Проверка sudo usage
    if [[ -f /var/log/auth.log ]]; then
        local sudo_attempts
        sudo_attempts="$(grep -i 'sudo.*authentication failure' /var/log/auth.log 2>/dev/null | tail -5)"
        if [[ -n "$sudo_attempts" ]]; then
            add_warning "Failed sudo authentication attempts detected | Review auth.log"
            print_raw_logs "$sudo_attempts"
        fi
    fi
    
    print_subsection "SSH_CONFIGURATION_ENHANCED"
    if [[ -f /etc/ssh/sshd_config ]]; then
        local root_login
        root_login="$(grep -i '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')"
        local pass_auth
        pass_auth="$(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')"
        local pubkey_auth
        pubkey_auth="$(grep -i '^PubkeyAuthentication' /etc/ssh/sshd_config | awk '{print $2}')"
        
        if [[ "$root_login" == "yes" ]]; then
            add_warning "SSH root login permitted | Security risk | Set PermitRootLogin no"
            add_prohibition "[НЕ ДЕЛАТЬ] Разрешать root login по SSH | Критический риск безопасности | Установить PermitRootLogin no"
        fi
        if [[ "$pass_auth" == "yes" ]]; then
            add_info "SSH password authentication enabled | Consider key-only auth"
        fi
        if [[ "$pubkey_auth" != "yes" ]]; then
            add_info "SSH public key authentication may be disabled | Consider enabling"
        fi
        
        print_data "Root login: ${root_login:-default} | Password auth: ${pass_auth:-default} | Pubkey auth: ${pubkey_auth:-default}"
        
        # Проверка синтаксиса sshd_config
        if check_tool sshd; then
            local sshd_test
            sshd_test="$(safe_sudo_cmd 'sshd -t' 2>&1)"
            if [[ -n "$sshd_test" && "$sshd_test" != "[NEEDS_ROOT]" ]]; then
                print_issues "SSHD config errors: $sshd_test"
                add_critical "SSH configuration syntax errors | Run 'sshd -t' to diagnose"
                add_prohibition "[НЕ ДЕЛАТЬ] Перезапускать sshd с ошибками конфигурации | Риск потери доступа | Исправить ошибки сначала"
            else
                print_data "SSHD config syntax: OK"
            fi
        fi
    else
        print_status "SKIPPED [No SSH server installed]"
    fi
    
    print_subsection "SELINUX_APPARMOR_STATUS"
    if check_tool getenforce; then
        local selinux_status
        selinux_status="$(getenforce 2>/dev/null)"
        print_data "SELinux status: ${selinux_status:-Not enforced}"
    elif check_tool aa-status; then
        local apparmor_status
        apparmor_status="$(aa-status 2>/dev/null | head -5)"
        if [[ -n "$apparmor_status" ]]; then
            print_data "AppArmor: Active"
            print_raw_logs "$apparmor_status"
        else
            print_data "AppArmor: Installed but status unknown"
        fi
    else
        print_data "Mandatory Access Control: Neither SELinux nor AppArmor detected"
    fi
}

#-------------------------------------------------------------------------------
# ЛОГИ И ПРОБЛЕМЫ (уровень 2+)
#-------------------------------------------------------------------------------
scan_logs_analysis() {
    print_section_header "LOG_ANALYSIS"
    
    print_subsection "JOURNALCTL_CRITICAL_ERRORS"
    if check_tool journalctl; then
        local critical_entries
        critical_entries="$(journalctl -p err -xb --no-pager 2>/dev/null | tail -15)"
        if [[ -n "$critical_entries" ]]; then
            print_issues "Error entries in journal"
            print_raw_logs "$critical_entries"
            add_warning "System errors logged | Review with 'journalctl -p err -xb'"
        else
            print_data "Journalctl: No critical errors in current boot"
        fi
        
        # Проверка на OOM killer
        local oom_entries
        oom_entries="$(journalctl -t kernel --no-pager 2>/dev/null | grep -i 'oom-killer\|out of memory' | tail -5)"
        if [[ -n "$oom_entries" ]]; then
            add_critical "OOM killer triggered | Memory exhaustion | Check memory-hungry processes"
            add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать OOM события | Риск потери данных | Добавить swap или RAM"
            print_raw_logs "$oom_entries"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: journalctl or systemd]"
    fi
    
    print_subsection "DMESG_CRITICAL_ISSUES"
    local dmesg_errors
    dmesg_errors="$(dmesg 2>/dev/null | grep -iE 'segfault|oom|out of memory|i/o error|kernel panic|bug at|general protection fault' | tail -10)"
    if [[ -n "$dmesg_errors" ]]; then
        print_issues "Critical kernel messages"
        print_raw_logs "$dmesg_errors"
        
        if echo "$dmesg_errors" | grep -qi 'oom\|out of memory'; then
            add_critical "OOM killer triggered | Memory exhaustion | Check memory-hungry processes"
            add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать OOM события | Риск потери данных | Добавить swap или RAM"
        fi
        if echo "$dmesg_errors" | grep -qi 'segfault\|general protection fault'; then
            add_warning "Segmentation faults detected | Application crashes | Review affected applications"
        fi
        if echo "$dmesg_errors" | grep -qi 'i/o error'; then
            add_critical "I/O errors detected | Storage failure likely | Backup immediately"
            add_prohibition "[НЕ ДЕЛАТЬ] Продолжать использовать диск с I/O ошибками | Риск полной потери данных | Заменить диск"
        fi
        if echo "$dmesg_errors" | grep -qi 'kernel panic'; then
            add_critical "Kernel panic detected | System instability | Check hardware and kernel logs"
            add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать kernel panic | Критическая нестабильность | Исследовать причину"
        fi
    else
        print_data "Dmesg: No critical errors found"
    fi
    
    print_subsection "LOGROTATE_STATUS_DETAILED"
    if [[ -d /var/log/journal ]]; then
        local journal_size
        journal_size="$(du -sh /var/log/journal 2>/dev/null | cut -f1)"
        print_data "Persistent journal size: ${journal_size:-unknown}"
    else
        print_data "Journal: Volatile (not persistent)"
    fi
    
    # Проверка размера логов
    local log_sizes
    log_sizes="$(du -sh /var/log 2>/dev/null | cut -f1)"
    if [[ -n "$log_sizes" ]]; then
        print_data "/var/log total size: $log_sizes"
        if [[ "${log_sizes%[GMK]}" -gt 1000 ]] 2>/dev/null; then
            add_warning "Large /var/log directory | Consider log rotation or cleanup"
        fi
    fi
}

#-------------------------------------------------------------------------------
# КОНТЕЙНЕРЫ И ВИРТУАЛИЗАЦИЯ (уровень 3)
#-------------------------------------------------------------------------------
scan_containers_virtualization() {
    print_section_header "CONTAINERS_VIRTUALIZATION"
    
    print_subsection "VIRTUALIZATION_TYPE_DETAILED"
    local virt_type
    if check_tool systemd-detect-virt; then
        virt_type="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    else
        virt_type="$(grep -i 'hypervisor' /proc/cpuinfo 2>/dev/null | head -1 || echo 'unknown')"
    fi
    print_data "Virtualization: $virt_type"
    
    # Определение хоста или гостя
    if [[ "$virt_type" == "none" ]]; then
        print_data "Running on: Bare metal (physical hardware)"
    else
        print_data "Running in: Virtual machine ($virt_type)"
    fi
    
    print_subsection "DOCKER_CONTAINERS_DETAILED"
    if check_tool docker; then
        local docker_running
        docker_running="$(docker ps -q 2>/dev/null | wc -l)"
        local docker_total
        docker_total="$(docker ps -aq 2>/dev/null | wc -l)"
        print_data "Running containers: $docker_running | Total: $docker_total"
        
        # Проверка использования ресурсов Docker
        if [[ $docker_running -gt 0 ]]; then
            local docker_stats
            docker_stats="$(docker stats --no-stream 2>/dev/null | head -5)"
            if [[ -n "$docker_stats" ]]; then
                print_data "Container resource usage: $docker_stats"
            fi
        fi
        
        # Проверка на старые образы
        local dangling_images
        dangling_images="$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l)"
        if [[ $dangling_images -gt 0 ]]; then
            add_info "Dangling Docker images: $dangling_images | Consider cleanup with 'docker image prune'"
        fi
    else
        print_data "Docker: Not installed"
    fi
    
    print_subsection "PODMAN_LIBVIRT_OTHER"
    if check_tool podman; then
        local podman_count
        podman_count="$(podman ps -q 2>/dev/null | wc -l)"
        print_data "Podman containers: $podman_count"
    fi
    if check_tool virsh; then
        local vm_running
        vm_running="$(virsh list 2>/dev/null | grep -c ' running' || echo '0')"
        local vm_total
        vm_total="$(virsh list --all 2>/dev/null | grep -c '.' || echo '0')"
        print_data "Libvirt VMs running: $vm_running | Total: $((vm_total - 1))"
    fi
    if check_tool lxc; then
        local lxc_count
        lxc_count="$(lxc list 2>/dev/null | grep -c '|' || echo '0')"
        print_data "LXC containers: ~$lxc_count"
    fi
}

#-------------------------------------------------------------------------------
# ПОЛЬЗОВАТЕЛИ И CRON (уровень 2+)
#-------------------------------------------------------------------------------
scan_users_cron() {
    print_section_header "USERS_AND_SCHEDULERS"
    
    print_subsection "USER_ACCOUNTS_DETAILED"
    local user_count
    user_count="$(cut -d: -f1 /etc/passwd | wc -l)"
    local sudo_users
    sudo_users="$(getent group sudo 2>/dev/null | cut -d: -f4 || getent group wheel 2>/dev/null | cut -d: -f4)"
    print_data "Total users: $user_count | Sudo group: ${sudo_users:-N/A}"
    
    # Проверка пользователей без пароля
    local empty_pass_users
    empty_pass_users="$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null)"
    if [[ -n "$empty_pass_users" ]]; then
        add_warning "Users with empty/locked passwords: $empty_pass_users"
    fi
    
    # Проверка UID 0 кроме root
    local multi_root
    multi_root="$(awk -F: '$3 == 0 {print $1}' /etc/passwd | grep -v 'root')"
    if [[ -n "$multi_root" ]]; then
        add_critical "Multiple users with UID 0 (root privileges): $multi_root | Security risk"
        add_prohibition "[НЕ ДЕЛАТЬ] Оставлять несколько root-пользователей | Критический риск безопасности | Удалить или изменить UID"
    fi
    
    print_subsection "CRON_JOBS_DETAILED"
    local cron_jobs=0
    if [[ -d /etc/cron.d ]]; then
        cron_jobs=$((cron_jobs + $(ls -1 /etc/cron.d 2>/dev/null | wc -l)))
    fi
    if [[ -d /etc/cron.daily ]]; then
        cron_jobs=$((cron_jobs + $(ls -1 /etc/cron.daily 2>/dev/null | wc -l)))
    fi
    if [[ -d /etc/cron.hourly ]]; then
        cron_jobs=$((cron_jobs + $(ls -1 /etc/cron.hourly 2>/dev/null | wc -l)))
    fi
    for crontab in /var/spool/cron/crontabs/*; do
        if [[ -f "$crontab" ]]; then
            cron_jobs=$((cron_jobs + 1))
        fi
    done
    print_data "System cron jobs: $cron_jobs"
    
    print_subsection "SYSTEMD_TIMERS_DETAILED"
    if check_tool systemctl; then
        local failed_timers
        failed_timers="$(systemctl list-timers --failed --no-pager 2>/dev/null | tail -n +3 | wc -l)"
        if [[ $failed_timers -gt 0 ]]; then
            print_issues "Failed systemd timers: $failed_timers"
            add_warning "Failed systemd timers | Review with 'systemctl list-timers --failed'"
        else
            print_data "Systemd timers: OK"
        fi
        
        # Список активных таймеров
        local active_timers
        active_timers="$(systemctl list-timers --no-pager 2>/dev/null | tail -n +3 | head -10)"
        if [[ -n "$active_timers" ]]; then
            print_data "Active timers (sample): $active_timers"
        fi
    fi
}

#-------------------------------------------------------------------------------
# ГЕНЕРАЦИЯ AI SUMMARY
#-------------------------------------------------------------------------------
generate_ai_summary() {
    print_section_header "AI_SUMMARY_READY"
    
    echo ""
    echo "=== КРИТИЧЕСКИЕ ПРОБЛЕМЫ ==="
    if [[ ${#CRITICAL_ISSUES[@]} -eq 0 ]]; then
        echo "✅ No critical issues detected."
    else
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "[CRITICAL] $issue"
        done
    fi
    
    echo ""
    echo "=== ПРЕДУПРЕЖДЕНИЯ ==="
    if [[ ${#WARNING_ISSUES[@]} -eq 0 ]]; then
        echo "✅ No warnings."
    else
        for issue in "${WARNING_ISSUES[@]}"; do
            echo "[WARNING] $issue"
        done
    fi
    
    echo ""
    echo "=== ИНФОРМАЦИЯ ==="
    if [[ ${#INFO_ISSUES[@]} -eq 0 ]]; then
        echo "ℹ️  No informational notes."
    else
        for issue in "${INFO_ISSUES[@]}"; do
            echo "[INFO] $issue"
        done
    fi
    
    # Добавляем универсальные запреты
    for prohibition in "${UNIVERSAL_PROHIBITIONS[@]}"; do
        STRICT_PROHIBITIONS+=("$prohibition")
    done
    
    if [[ ${#STRICT_PROHIBITIONS[@]} -gt 0 ]]; then
        echo ""
        echo "=== ⛔ STRICT_PROHIBITIONS ==="
        for prohibition in "${STRICT_PROHIBITIONS[@]}"; do
            echo "$prohibition"
        done
    fi
    
    echo ""
    echo "=== NEXT_STEPS_FOR_AI_ANALYSIS ==="
    echo "• Передай этот отчёт ИИ с запросом: 'Проанализируй, дай пошаговый план устранения, выдели риски.'"
    echo "• Не выполняй команды с пометкой [NEEDS_ROOT] без аудита."
    echo "• Обрати внимание на секции [CRITICAL] и [STRICT_PROHIBITIONS]."
    echo "• Для автоматического парсинга используй маркеры ## [], ### [], • STATUS/DATA/ISSUES_FOUND."
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ФУНКЦИЯ СКАНИРОВАНИЯ
#-------------------------------------------------------------------------------
run_scan() {
    {
        echo "#==============================================================================="
        echo "# DEEP SYSTEM SCAN v${VERSION} - Отчёт диагностики"
        echo "# Хост: $HOSTNAME"
        echo "# Дата: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Уровень сканирования: $SCAN_LEVEL"
        echo "# Пакетный менеджер: $PKG_MANAGER"
        echo "#==============================================================================="
        
        # Уровень 1: Базовая информация (всегда)
        scan_basic_info
        
        # Уровень 2+: Драйверы, железо, службы, логи, пользователи
        if [[ $SCAN_LEVEL -ge 2 ]]; then
            scan_drivers_firmware
            scan_hardware_health
            scan_services_packages
            scan_logs_analysis
            scan_users_cron
        fi
        
        # Уровень 3: Конфиги, безопасность, контейнеры
        if [[ $SCAN_LEVEL -ge 3 ]]; then
            scan_config_validation
            scan_security
            scan_containers_virtualization
        fi
        
        # Итоговая сводка (всегда)
        generate_ai_summary
        
    } > "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# ГЛАВНАЯ ФУНКЦИЯ
#-------------------------------------------------------------------------------
main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           DEEP SYSTEM SCAN v${VERSION} - Диагностика Linux          ║"
    echo "║                    ТОЛЬКО ЧТЕНИЕ (Read-Only)                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Подготовка директории вывода
    prepare_output_dir
    
    # Показ меню выбора уровня
    show_scan_menu
    
    echo ""
    echo "🔄 Начало сканирования..."
    echo ""
    
    # Запуск сканирования
    run_scan
    
    # Проверка результата
    if [[ -f "$OUTPUT_FILE" ]]; then
        local file_size
        file_size="$(du -h "$OUTPUT_FILE" | cut -f1)"
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║                    ✅ Сканирование завержено                  ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Файл отчёта: $OUTPUT_FILE"
        echo "║ Размер: $file_size"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "📋 Для анализа передайте файл ИИ с запросом:"
        echo "   'Проанализируй системный отчёт, выяви проблемы, дай план действий'"
    else
        echo "❌ Ошибка: Не удалось создать файл отчёта"
        exit 1
    fi
}

# Запуск главной функции
main
