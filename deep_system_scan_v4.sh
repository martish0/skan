#!/bin/bash
#===============================================================================
# DEEP SYSTEM SCAN v4.0 - Безопасная диагностика Linux для ИИ-анализа
# ТОЛЬКО ЧТЕНИЕ: Никаких изменений в системе
#===============================================================================
set -o pipefail

#-------------------------------------------------------------------------------
# КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
#-------------------------------------------------------------------------------
readonly VERSION="4.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly HOSTNAME="$(hostname)"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly OUTPUT_DIR=""
OUTPUT_FILE=""
SCAN_LEVEL=0

# Счётчики проблем для итоговой сводки
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()

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
║         DEEP SYSTEM SCAN v4.0 - Выбор уровня диагностики     ║
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
# ДРАЙВЕРЫ И ПРОШИВКИ (уровень 2+)
#-------------------------------------------------------------------------------
scan_drivers_firmware() {
    print_section_header "DRIVERS_FIRMWARE"
    
    print_subsection "LOADED_MODULES"
    local modules_count
    modules_count="$(wc -l < /proc/modules 2>/dev/null || echo 0)"
    print_data "Loaded modules: $modules_count"
    
    # Проприетарные драйверы
    local proprietary_modules
    proprietary_modules="$(lsmod 2>/dev/null | grep -iE 'nvidia|fglrx|broadcom|wl|vbox|virtualbox|vmware|akmod' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$proprietary_modules" ]]; then
        print_data "Proprietary drivers: $proprietary_modules"
        add_info "Proprietary drivers detected: $proprietary_modules | System integration"
    else
        print_data "Proprietary drivers: None detected"
    fi
    
    print_subsection "DKMS_STATUS"
    if check_tool dkms; then
        local dkms_status
        dkms_status="$(safe_sudo_cmd 'dkms status' 2>/dev/null)"
        if [[ "$dkms_status" != "[NEEDS_ROOT]" && -n "$dkms_status" ]]; then
            print_data "$dkms_status"
            if echo "$dkms_status" | grep -qi "error\|mismatch"; then
                print_issues "DKMS version mismatch or errors detected"
                add_warning "DKMS issues found | Check kernel module compatibility"
            fi
        else
            print_status "SKIPPED [NEEDS_ROOT or DKMS not installed]"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: dkms]"
    fi
    
    print_subsection "GPU_DRIVERS"
    local gpu_driver
    if check_tool lspci; then
        gpu_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'vga\|3d\|display' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
        if [[ -n "$gpu_driver" ]]; then
            print_data "Active GPU driver: $gpu_driver"
        else
            print_data "GPU driver: Not detected via lspci"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: lspci]"
    fi
    
    print_subsection "NETWORK_DRIVERS"
    local wifi_driver eth_driver
    if check_tool lspci; then
        wifi_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'wireless\|network' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
        eth_driver="$(lspci -k 2>/dev/null | grep -A3 -i 'ethernet' | grep -i 'kernel driver in use' | head -1 | cut -d: -f2 | xargs)"
        print_data "WiFi: ${wifi_driver:-N/A} | Ethernet: ${eth_driver:-N/A}"
    fi
    
    print_subsection "AUDIO_DRIVERS"
    local audio_driver
    audio_driver="$(lsmod 2>/dev/null | grep -E '^snd_' | head -5 | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$audio_driver" ]]; then
        print_data "Audio modules: $audio_driver"
    else
        print_data "Audio modules: None loaded"
    fi
    
    print_subsection "CPU_MICROCODE"
    local microcode_info
    microcode_info="$(dmesg 2>/dev/null | grep -i 'microcode' | tail -2)"
    if [[ -n "$microcode_info" ]]; then
        print_data "$microcode_info"
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
}

#-------------------------------------------------------------------------------
# ДИАГНОСТИКА ЖЕЛЕЗА (уровень 2+)
#-------------------------------------------------------------------------------
scan_hardware_health() {
    print_section_header "HARDWARE_HEALTH"
    
    print_subsection "SMART_DISK_STATUS"
    if check_tool smartctl; then
        local disks
        disks="$(lsblk -dpno NAME 2>/dev/null | grep -E '^/dev/(sd|nvme|hd)')"
        local disk_issues=""
        for disk in $disks; do
            local smart_data
            smart_data="$(safe_sudo_cmd "smartctl -A $disk" 2>/dev/null)"
            if [[ "$smart_data" != "[NEEDS_ROOT]" && -n "$smart_data" ]]; then
                local reallocated pending udma
                reallocated="$(echo "$smart_data" | grep -i 'Reallocated_Sector_Ct\|Reallocated_Event_Count' | awk '{print $NF}')"
                pending="$(echo "$smart_data" | grep -i 'Current_Pending_Sector' | awk '{print $NF}')"
                udma="$(echo "$smart_data" | grep -i 'UDMA_CRC_Error_Count' | awk '{print $NF}')"
                
                local risk=""
                if [[ "${reallocated:-0}" -gt 0 || "${pending:-0}" -gt 0 || "${udma:-0}" -gt 0 ]]; then
                    risk="[DISK_RISK]"
                    disk_issues="$disk: Realloc=${reallocated:-0}, Pending=${pending:-0}, UDMA=${udma:-0} | "
                    add_critical "Disk $disk shows SMART warnings | Realloc=${reallocated:-0}, Pending=${pending:-0} | Backup immediately and consider replacement"
                    add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать диск $disk | Найден ${reallocated:-0} переназначенных секторов | Срочно сделать backup и планировать замену"
                fi
                
                if [[ -n "$risk" ]]; then
                    print_data "$disk $risk: Realloc=${reallocated:-0}, Pending=${pending:-0}, UDMA=${udma:-0}"
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
    
    print_subsection "BATTERY_STATUS"
    if [[ -d /sys/class/power_supply ]]; then
        local battery_found=false
        for bat in /sys/class/power_supply/BAT*; do
            if [[ -d "$bat" ]]; then
                battery_found=true
                local capacity full_design current
                capacity="$(cat "$bat/capacity" 2>/dev/null || echo 'N/A')"
                full_design="$(cat "$bat/energy_full_design" 2>/dev/null || cat "$bat/charge_full_design" 2>/dev/null || echo 'N/A')"
                current="$(cat "$bat/energy_full" 2>/dev/null || cat "$bat/charge_full" 2>/dev/null || echo 'N/A')"
                local status
                status="$(cat "$bat/status" 2>/dev/null || echo 'N/A')"
                
                local wear="N/A"
                if [[ "$full_design" != "N/A" && "$current" != "N/A" && "$full_design" -gt 0 ]]; then
                    wear="$(( (current * 100) / full_design ))%"
                    if [[ "${wear%\%}" -lt 80 ]]; then
                        add_warning "Battery wear detected | Capacity at $wear | Consider calibration or replacement"
                    fi
                fi
                
                print_data "Capacity: $capacity% | Wear Level: $wear | Status: $status"
            fi
        done
        if [[ "$battery_found" == false ]]; then
            print_data "No battery detected (desktop system?)"
        fi
    else
        print_status "SKIPPED [No power_supply class]"
    fi
    
    print_subsection "THERMAL_SENSORS"
    local thermal_zones=0
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            thermal_zones=$((thermal_zones + 1))
            local temp_val
            temp_val="$(cat "$zone" 2>/dev/null)"
            local temp_c=$((temp_val / 1000))
            local zone_name
            zone_name="$(cat "${zone%/temp}/type" 2>/dev/null || echo "Zone$thermal_zones")"
            
            if [[ $temp_c -gt 85 ]]; then
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
    
    print_subsection "PCIE_ACPI_ERRORS"
    local pcie_errors
    pcie_errors="$(dmesg 2>/dev/null | grep -iE 'aer|pci bus error|acpi error' | tail -5)"
    if [[ -n "$pcie_errors" ]]; then
        print_issues "PCIe/ACPI errors detected"
        print_raw_logs "$pcie_errors"
        add_warning "PCIe/ACPI errors in dmesg | Check hardware connections and firmware"
    else
        print_data "No PCIe/ACPI errors detected"
    fi
    
    print_subsection "ECC_RAM_STATUS"
    if check_tool edac-util; then
        local ecc_status
        ecc_status="$(safe_sudo_cmd 'edac-util -v' 2>/dev/null)"
        if [[ "$ecc_status" != "[NEEDS_ROOT]" && -n "$ecc_status" ]]; then
            print_data "$ecc_status"
        else
            print_status "SKIPPED [NEEDS_ROOT]"
        fi
    else
        local ecc_dmesg
        ecc_dmesg="$(dmesg 2>/dev/null | grep -iE 'ecc|corrected error' | tail -3)"
        if [[ -n "$ecc_dmesg" ]]; then
            print_data "ECC events: $ecc_dmesg"
        else
            print_data "ECC: No data available (may not be supported)"
        fi
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
            ;;
        zypper)
            print_data "Zypper manager detected"
            ;;
        unknown)
            print_status "SKIPPED [Unknown package manager]"
            ;;
    esac
    
    print_subsection "SNAP_FLATPAK"
    if check_tool snap; then
        local snap_count
        snap_count="$(snap list 2>/dev/null | tail -n +2 | wc -l)"
        print_data "Snap packages: $snap_count"
    fi
    if check_tool flatpak; then
        local flatpak_count
        flatpak_count="$(flatpak list 2>/dev/null | wc -l)"
        print_data "Flatpak packages: $flatpak_count"
    fi
    if ! check_tool snap && ! check_tool flatpak; then
        print_data "Snap/Flatpak: Not installed"
    fi
}

#-------------------------------------------------------------------------------
# ВАЛИДАЦИЯ КОНФИГОВ (уровень 3)
#-------------------------------------------------------------------------------
scan_config_validation() {
    print_section_header "CONFIG_VALIDATION"
    
    print_subsection "FSTAB_VALIDATION"
    if [[ -f /etc/fstab ]]; then
        local fstab_issues=""
        # Проверка на дубликаты UUID
        local uuid_count
        uuid_count="$(grep -v '^#' /etc/fstab | grep -i 'uuid' | awk '{print $1}' | sort | uniq -d)"
        if [[ -n "$uuid_count" ]]; then
            fstab_issues="Duplicate UUIDs: $uuid_count | "
            add_critical "Duplicate UUIDs in /etc/fstab | May cause boot failures | Fix fstab entries"
        fi
        
        # Проверка mount options для /tmp
        local tmp_opts
        tmp_opts="$(grep -E '\s/tmp\s' /etc/fstab | awk '{print $4}')"
        if [[ -n "$tmp_opts" && ! "$tmp_opts" =~ noexec ]]; then
            add_info "/tmp without noexec option | Security consideration | Add noexec,nosuid,nodev"
        fi
        
        if [[ -z "$fstab_issues" ]]; then
            print_data "/etc/fstab: Basic validation OK"
        else
            print_issues "$fstab_issues"
        fi
    else
        print_status "SKIPPED [/etc/fstab not found]"
    fi
    
    print_subsection "SYSTEMD_UNIT_VALIDATION"
    if check_tool systemd-analyze; then
        local verify_output
        verify_output="$(safe_sudo_cmd 'systemd-analyze verify' 2>&1 | head -10)"
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
    else
        print_status "SKIPPED [TOOL_MISSING: systemd-analyze]"
    fi
    
    print_subsection "SYSCCTL_HARDENING"
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
    
    if [[ -z "$sysctl_issues" ]]; then
        print_data "Sysctl hardening: Basic checks OK"
    else
        print_issues "$sysctl_issues"
    fi
    
    print_subsection "HOSTS_RESOLV_VALIDATION"
    if [[ -f /etc/hosts ]]; then
        local hosts_dup
        hosts_dup="$(grep -v '^#' /etc/hosts | grep -v '^$' | awk '{print $2}' | sort | uniq -d)"
        if [[ -n "$hosts_dup" ]]; then
            print_issues "Duplicate entries in /etc/hosts: $hosts_dup"
            add_warning "Duplicate /etc/hosts entries | May cause DNS issues"
        else
            print_data "/etc/hosts: No duplicates"
        fi
    fi
    
    if [[ -f /etc/resolv.conf ]]; then
        local nameservers
        nameservers="$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || echo '0')"
        print_data "DNS nameservers configured: $nameservers"
    fi
}

#-------------------------------------------------------------------------------
# БЕЗОПАСНОСТЬ (уровень 3)
#-------------------------------------------------------------------------------
scan_security() {
    print_section_header "SECURITY_AUDIT"
    
    print_subsection "OPEN_PORTS"
    if check_tool ss; then
        local open_ports
        open_ports="$(ss -tuln 2>/dev/null | grep LISTEN | wc -l)"
        local port_details
        port_details="$(ss -tuln 2>/dev/null | grep LISTEN | awk '{print $5}' | sort -u | head -10 | tr '\n' ',' | sed 's/,$//')"
        print_data "Listening ports: $open_ports | $port_details"
    elif check_tool netstat; then
        local open_ports
        open_ports="$(netstat -tuln 2>/dev/null | grep LISTEN | wc -l)"
        print_data "Listening ports: $open_ports"
    else
        print_status "SKIPPED [TOOL_MISSING: ss/netstat]"
    fi
    
    print_subsection "FIREWALL_STATUS"
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
        ipt_rules="$(safe_sudo_cmd 'iptables -L -n' 2>/dev/null | head -5)"
        if [[ "$ipt_rules" != "[NEEDS_ROOT]" && -n "$ipt_rules" ]]; then
            firewall_status="iptables: Rules configured"
        else
            firewall_status="iptables: [NEEDS_ROOT]"
        fi
    fi
    print_data "$firewall_status"
    
    print_subsection "SUID_SGID_FILES"
    local suid_files
    suid_files="$(find /usr /bin /sbin -perm -4000 -type f 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$suid_files" ]]; then
        print_data "SUID files (sample): $suid_files"
        if echo "$suid_files" | grep -qvE 'sudo|su|passwd|mount|umount'; then
            add_warning "Unusual SUID files detected | Review for security"
        fi
    else
        print_data "SUID files: None found in standard paths"
    fi
    
    print_subsection "WORLD_WRITABLE_FILES"
    local world_writable
    world_writable="$(find /etc /usr /var -type f -perm -0002 2>/dev/null | head -5 | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$world_writable" ]]; then
        print_issues "World-writable files: $world_writable"
        add_critical "World-writable files in system dirs | Security risk | chmod o-w <files>"
        add_prohibition "[НЕ ДЕЛАТЬ] Оставлять world-writable файлы в /etc /usr | Риск компрометации | Исправить права: chmod o-w"
    else
        print_data "World-writable files: None in /etc /usr /var"
    fi
    
    print_subsection "RECENT_LOGINS"
    local recent_logins
    recent_logins="$(last -5 2>/dev/null | head -5)"
    if [[ -n "$recent_logins" ]]; then
        print_data "Last 5 logins recorded"
        print_raw_logs "$recent_logins"
    else
        print_data "Login history: Not available"
    fi
    
    print_subsection "SSH_CONFIGURATION"
    if [[ -f /etc/ssh/sshd_config ]]; then
        local root_login
        root_login="$(grep -i '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')"
        local pass_auth
        pass_auth="$(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')"
        
        if [[ "$root_login" == "yes" ]]; then
            add_warning "SSH root login permitted | Security risk | Set PermitRootLogin no"
        fi
        if [[ "$pass_auth" == "yes" ]]; then
            add_info "SSH password authentication enabled | Consider key-only auth"
        fi
        
        print_data "Root login: ${root_login:-default} | Password auth: ${pass_auth:-default}"
        
        # Проверка синтаксиса sshd_config
        if check_tool sshd; then
            local sshd_test
            sshd_test="$(safe_sudo_cmd 'sshd -t' 2>&1)"
            if [[ -n "$sshd_test" && "$sshd_test" != "[NEEDS_ROOT]" ]]; then
                print_issues "SSHD config errors: $sshd_test"
                add_critical "SSH configuration syntax errors | Run 'sshd -t' to diagnose"
            else
                print_data "SSHD config syntax: OK"
            fi
        fi
    else
        print_status "SKIPPED [No SSH server installed]"
    fi
}

#-------------------------------------------------------------------------------
# ЛОГИ И ПРОБЛЕМЫ (уровень 2+)
#-------------------------------------------------------------------------------
scan_logs_analysis() {
    print_section_header "LOG_ANALYSIS"
    
    print_subsection "JOURNALCTL_CRITICAL"
    if check_tool journalctl; then
        local critical_entries
        critical_entries="$(journalctl -p err -xb --no-pager 2>/dev/null | tail -10)"
        if [[ -n "$critical_entries" ]]; then
            print_issues "Error entries in journal"
            print_raw_logs "$critical_entries"
            add_warning "System errors logged | Review with 'journalctl -p err -xb'"
        else
            print_data "Journalctl: No critical errors in current boot"
        fi
    else
        print_status "SKIPPED [TOOL_MISSING: journalctl or systemd]"
    fi
    
    print_subsection "DMESG_ISSUES"
    local dmesg_errors
    dmesg_errors="$(dmesg 2>/dev/null | grep -iE 'segfault|oom|out of memory|i/o error' | tail -5)"
    if [[ -n "$dmesg_errors" ]]; then
        print_issues "Critical kernel messages"
        print_raw_logs "$dmesg_errors"
        
        if echo "$dmesg_errors" | grep -qi 'oom\|out of memory'; then
            add_critical "OOM killer triggered | Memory exhaustion | Check memory-hungry processes"
            add_prohibition "[НЕ ДЕЛАТЬ] Игнорировать OOM события | Риск потери данных | Добавить swap или RAM"
        fi
        if echo "$dmesg_errors" | grep -qi 'segfault'; then
            add_warning "Segmentation faults detected | Application crashes | Review affected applications"
        fi
        if echo "$dmesg_errors" | grep -qi 'i/o error'; then
            add_critical "I/O errors detected | Storage failure likely | Backup immediately"
            add_prohibition "[НЕ ДЕЛАТЬ] Продолжать использовать диск с I/O ошибками | Риск полной потери данных | Заменить диск"
        fi
    else
        print_data "Dmesg: No critical errors found"
    fi
    
    print_subsection "LOGROTATE_STATUS"
    if [[ -d /var/log/journal ]]; then
        local journal_size
        journal_size="$(du -sh /var/log/journal 2>/dev/null | cut -f1)"
        print_data "Persistent journal size: ${journal_size:-unknown}"
    else
        print_data "Journal: Volatile (not persistent)"
    fi
}

#-------------------------------------------------------------------------------
# КОНТЕЙНЕРЫ И ВИРТУАЛИЗАЦИЯ (уровень 3)
#-------------------------------------------------------------------------------
scan_containers_virtualization() {
    print_section_header "CONTAINERS_VIRTUALIZATION"
    
    print_subsection "VIRTUALIZATION_TYPE"
    local virt_type
    if check_tool systemd-detect-virt; then
        virt_type="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    else
        virt_type="$(grep -i 'hypervisor' /proc/cpuinfo 2>/dev/null | head -1 || echo 'unknown')"
    fi
    print_data "Virtualization: $virt_type"
    
    print_subsection "DOCKER_CONTAINERS"
    if check_tool docker; then
        local docker_running
        docker_running="$(docker ps -q 2>/dev/null | wc -l)"
        local docker_total
        docker_total="$(docker ps -aq 2>/dev/null | wc -l)"
        print_data "Running containers: $docker_running | Total: $docker_total"
    else
        print_data "Docker: Not installed"
    fi
    
    print_subsection "PODMAN_LIBVIRT"
    if check_tool podman; then
        local podman_count
        podman_count="$(podman ps -q 2>/dev/null | wc -l)"
        print_data "Podman containers: $podman_count"
    fi
    if check_tool virsh; then
        local vm_running
        vm_running="$(virsh list 2>/dev/null | grep -c ' running' || echo '0')"
        print_data "Libvirt VMs running: $vm_running"
    fi
}

#-------------------------------------------------------------------------------
# ПОЛЬЗОВАТЕЛИ И CRON (уровень 2+)
#-------------------------------------------------------------------------------
scan_users_cron() {
    print_section_header "USERS_AND_SCHEDULERS"
    
    print_subsection "USER_ACCOUNTS"
    local user_count
    user_count="$(cut -d: -f1 /etc/passwd | wc -l)"
    local sudo_users
    sudo_users="$(getent group sudo 2>/dev/null | cut -d: -f4 || getent group wheel 2>/dev/null | cut -d: -f4)"
    print_data "Total users: $user_count | Sudo group: ${sudo_users:-N/A}"
    
    print_subsection "CRON_JOBS"
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
    
    print_subsection "SYSTEMD_TIMERS"
    if check_tool systemctl; then
        local failed_timers
        failed_timers="$(systemctl list-timers --failed --no-pager 2>/dev/null | tail -n +3 | wc -l)"
        if [[ $failed_timers -gt 0 ]]; then
            print_issues "Failed systemd timers: $failed_timers"
            add_warning "Failed systemd timers | Review with 'systemctl list-timers --failed'"
        else
            print_data "Systemd timers: OK"
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
        echo "║                    ✅ Сканирование завершено                  ║"
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
