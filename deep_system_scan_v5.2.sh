#!/usr/bin/env bash
#===============================================================================
# Deep System Scan v5.2 - Production-Ready System Diagnostics
# Architecture: Modular, Read-Only, AI-Parsable Output
# Levels: MINIMAL(1), MEDIUM(2), TOTAL(3), PROFILING_STRESS(4)
#===============================================================================

set -o pipefail
# set -e is intentionally NOT used for graceful error handling

#-------------------------------------------------------------------------------
# Configuration & Constants
#-------------------------------------------------------------------------------
readonly VERSION="5.2"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
readonly REPORT_FILE="${REPORT_DIR:-/tmp}/deep_system_scan_${TIMESTAMP}.log"
readonly TIMEOUT_CMD="timeout 15"
readonly SUDO_TIMEOUT=30

# Scan levels
readonly SCAN_MINIMAL=1
readonly SCAN_MEDIUM=2
readonly SCAN_TOTAL=3
readonly SCAN_PROFILING_STRESS=4

# Colors for terminal output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Global state
declare -i CURRENT_LEVEL=${SCAN_MINIMAL}
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -A TOOLS_STATUS=()
declare AUTO_INSTALL=false
declare FORCE_PROFILING=false

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
    WARNING_ISSUES+=("$*")
}

log_critical() {
    echo -e "${RED}[CRITICAL]${NC} $*" >&2
    CRITICAL_ISSUES+=("$*")
}

log_section() {
    echo -e "\n${CYAN}=== $* ===${NC}" >&2
}

# @AI: Safe sudo wrapper with timeout and graceful fallback
safe_sudo_cmd() {
    local cmd="$*"
    if [[ $EUID -eq 0 ]]; then
        timeout $SUDO_TIMEOUT bash -c "$cmd" 2>/dev/null
    elif command -v sudo &>/dev/null; then
        timeout $SUDO_TIMEOUT sudo -n bash -c "$cmd" 2>/dev/null
    else
        echo "[SUDO_REQUIRED]"
        return 1
    fi
}

# @AI: Execute command with timeout and fallback
exec_cmd() {
    local cmd="$*"
    local result
    result=$($TIMEOUT_CMD bash -c "$cmd" 2>/dev/null) || true
    echo "$result"
}

# @AI: Execute command with sudo, timeout and fallback
exec_sudo_cmd() {
    local cmd="$*"
    local result
    result=$(safe_sudo_cmd "$cmd") || true
    echo "$result"
}

# @AI: Detect package manager
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

# @AI: Check and optionally install required tools
check_and_install_tools() {
    log_section "Checking Required Tools"
    
    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)
    local -a missing_tools=()
    local -a installed_tools=()
    
    # Define required tools and their packages
    declare -A tool_packages=(
        ["smartctl"]="smartmontools"
        ["sensors"]="lm-sensors"
        ["dmidecode"]="dmidecode"
        ["perf"]="linux-tools-generic"
        ["stress-ng"]="stress-ng"
        ["fio"]="fio"
        ["edac-util"]="edac-utils"
        ["bpftrace"]="bpftrace"
        ["lsof"]="lsof"
        ["ss"]="iproute2"
        ["jq"]="jq"
        ["pciutils"]="pciutils"
        ["usbutils"]="usbutils"
        ["hwinfo"]="hwinfo"
        ["inxi"]="inxi"
        ["powertop"]="powertop"
        ["turbostat"]="linux-tools-generic"
        ["ras-mc-ctl"]="rasdaemon"
        ["mcelog"]="mcelog"
    )
    
    echo ""
    for tool in "${!tool_packages[@]}"; do
        if command -v "$tool" &>/dev/null; then
            TOOLS_STATUS["$tool"]="installed"
            installed_tools+=("${tool_packages[$tool]}")
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            TOOLS_STATUS["$tool"]="missing"
            missing_tools+=("${tool_packages[$tool]}")
            echo -e "  ${RED}✗${NC} $tool [TOOL_MISSING: $tool]"
        fi
    done
    
    # Handle missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo ""
        log_warning "Missing tools detected: ${missing_tools[*]}"
        
        if [[ "$AUTO_INSTALL" == true ]] || [[ "$CURRENT_LEVEL" -ge $SCAN_TOTAL ]]; then
            if [[ "$pkg_mgr" != "unknown" ]]; then
                echo ""
                read -rp "Install missing packages? (y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]] || [[ "$AUTO_INSTALL" == true ]]; then
                    log_info "Installing packages via $pkg_mgr..."
                    
                    local install_cmd=""
                    case "$pkg_mgr" in
                        apt)
                            install_cmd="sudo apt update && sudo apt install -y ${missing_tools[*]}"
                            ;;
                        dnf|yum)
                            install_cmd="sudo $pkg_mgr install -y ${missing_tools[*]}"
                            ;;
                        pacman)
                            install_cmd="sudo pacman -S --noconfirm ${missing_tools[*]}"
                            ;;
                        zypper)
                            install_cmd="sudo zypper install -y ${missing_tools[*]}"
                            ;;
                    esac
                    
                    if eval "$install_cmd" 2>/dev/null; then
                        log_success "Packages installed successfully"
                        echo ""
                        echo -e "${GREEN}📦 Установлены пакеты:${NC} ${missing_tools[*]}"
                        echo -e "${YELLOW}Для удаления выполните:${NC} sudo $pkg_mgr remove ${missing_tools[*]}"
                        echo ""
                        
                        # Re-check tools
                        for tool in "${!tool_packages[@]}"; do
                            if command -v "$tool" &>/dev/null; then
                                TOOLS_STATUS["$tool"]="installed"
                            fi
                        done
                    else
                        log_critical "Failed to install packages"
                    fi
                fi
            else
                log_warning "Unknown package manager. Please install tools manually."
            fi
        else
            log_info "Continuing with available tools. Some features may be limited."
        fi
    else
        log_success "All required tools are available"
    fi
}

#-------------------------------------------------------------------------------
# Report Generation Functions
#-------------------------------------------------------------------------------

write_report_header() {
    cat > "$REPORT_FILE" << EOF
================================================================================
DEEP SYSTEM SCAN v${VERSION}
Generated: $(date)
Hostname: $(hostname)
Kernel: $(uname -r)
Scan Level: ${CURRENT_LEVEL}
================================================================================

EOF
}

write_section() {
    local section_name="$1"
    local content="$2"
    local status="${3:-OK}"
    local issues="${4:-}"
    
    cat >> "$REPORT_FILE" << EOF

## [$section_name]
• STATUS: $status
• DATA:
$content
EOF
    
    if [[ -n "$issues" ]]; then
        echo "• ISSUES_FOUND: $issues" >> "$REPORT_FILE"
    fi
}

write_raw_logs() {
    local section_name="$1"
    local raw_data="$2"
    
    cat >> "$REPORT_FILE" << EOF
• RAW_LOGS:
$raw_data
---
EOF
}

generate_ai_summary() {
    cat >> "$REPORT_FILE" << EOF

## [AI_SUMMARY]
### METADATA
• SCAN_VERSION: $VERSION
• SCAN_TIMESTAMP: $TIMESTAMP
• SCAN_LEVEL: $CURRENT_LEVEL
• HOSTNAME: $(hostname)
• KERNEL: $(uname -r)
• TOOLS_AVAILABLE: ${#TOOLS_STATUS[@]}

### CRITICAL_ISSUES
EOF
    
    if [[ ${#CRITICAL_ISSUES[@]} -eq 0 ]]; then
        echo "• None" >> "$REPORT_FILE"
    else
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "• $issue" >> "$REPORT_FILE"
        done
    fi
    
    cat >> "$REPORT_FILE" << EOF

### WARNING_ISSUES
EOF
    
    if [[ ${#WARNING_ISSUES[@]} -eq 0 ]]; then
        echo "• None" >> "$REPORT_FILE"
    else
        for issue in "${WARNING_ISSUES[@]}"; do
            echo "• $issue" >> "$REPORT_FILE"
        done
    fi
    
    cat >> "$REPORT_FILE" << EOF

### INFO_ISSUES
EOF
    
    if [[ ${#INFO_ISSUES[@]} -eq 0 ]]; then
        echo "• None" >> "$REPORT_FILE"
    else
        for issue in "${INFO_ISSUES[@]}"; do
            echo "• $issue" >> "$REPORT_FILE"
        done
    fi
    
    echo "" >> "$REPORT_FILE"
    echo "================================================================================">> "$REPORT_FILE"
    echo "END OF REPORT">> "$REPORT_FILE"
    echo "================================================================================">> "$REPORT_FILE"
}

#-------------------------------------------------------------------------------
# CPU Diagnostics
#-------------------------------------------------------------------------------

scan_cpu() {
    log_section "CPU Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # Basic CPU info
    content+="### CPU_MODEL\n"
    local cpu_model
    cpu_model=$(exec_cmd "grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs")
    content+="• Model: $cpu_model\n"
    
    # Physical/Logical cores
    content+="### CPU_CORES\n"
    local phys_cores logic_cores
    phys_cores=$(exec_cmd "grep 'physical id' /proc/cpuinfo | sort -u | wc -l")
    logic_cores=$(exec_cmd "grep -c processor /proc/cpuinfo")
    content+="• Physical Cores: $phys_cores\n"
    content+="• Logical Cores: $logic_cores\n"
    
    if [[ $phys_cores -lt 2 ]]; then
        issues+="Low core count; "
        status="WARNING"
    fi
    
    # Frequencies
    content+="### CPU_FREQUENCIES\n"
    local base_freq
    base_freq=$(exec_cmd "grep 'cpu MHz' /proc/cpuinfo | head -1 | awk '{print \$4}'")
    content+="• Current Frequency: ${base_freq} MHz\n"
    
    if [[ -f /proc/cpuinfo ]]; then
        local bogomips
        bogomips=$(exec_cmd "grep 'bogomips' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs")
        content+="• BogoMIPS: $bogomips\n"
    fi
    
    # Cache info
    content+="### CPU_CACHE\n"
    if [[ -d /sys/devices/system/cpu/cpu0/cache ]]; then
        for cache in /sys/devices/system/cpu/cpu0/cache/index*; do
            local level size type
            level=$(cat "$cache/level" 2>/dev/null || echo "?")
            size=$(cat "$cache/size" 2>/dev/null || echo "unknown")
            type=$(cat "$cache/type" 2>/dev/null || echo "unknown")
            content+="• L${level} ${type}: $size\n"
        done
    fi
    
    # CPU flags/instructions
    content+="### CPU_INSTRUCTIONS\n"
    local flags has_sse has_avx has_aes
    flags=$(exec_cmd "grep 'flags' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs")
    has_sse=$(echo "$flags" | grep -q sse && echo "yes" || echo "no")
    has_avx=$(echo "$flags" | grep -q avx && echo "yes" || echo "no")
    has_aes=$(echo "$flags" | grep -q aes && echo "yes" || echo "no")
    content+="• SSE: $has_sse\n"
    content+="• AVX: $has_avx\n"
    content+="• AES-NI: $has_aes\n"
    
    # Architecture
    content+="### CPU_ARCHITECTURE\n"
    local arch
    arch=$(uname -m)
    content+="• Architecture: $arch\n"
    
    # Stepping
    content+="### CPU_STEPPING\n"
    local stepping
    stepping=$(exec_cmd "grep 'stepping' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs")
    content+="• Stepping: $stepping\n"
    
    # Temperature (if sensors available)
    content+="### CPU_TEMPERATURE\n"
    if command -v sensors &>/dev/null; then
        local temps
        temps=$(exec_cmd "sensors | grep -E '(Core|Package|Tdie)' | head -5")
        if [[ -n "$temps" ]]; then
            content+="$temps\n"
        else
            content+="• Temperature data unavailable\n"
        fi
    else
        content+="• [TOOL_MISSING: sensors]\n"
    fi
    
    # Governor and turbo status
    content+="### CPU_GOVERNOR\n"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local governor
        governor=$(exec_cmd "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")
        content+="• Governor: $governor\n"
    fi
    
    content+="### TURBO_STATUS\n"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local turbo_status
        turbo_status=$(exec_cmd "cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null")
        if [[ "$turbo_status" == "0" ]]; then
            content+="• Turbo Boost: Enabled\n"
        else
            content+="• Turbo Boost: Disabled\n"
            issues+="Turbo disabled; "
        fi
    else
        content+="• Turbo status: N/A (AMD or unsupported)\n"
    fi
    
    # RAPL power (Intel only)
    content+="### RAPL_POWER\n"
    if [[ -d /sys/class/powercap/intel-rapl ]]; then
        local rapl_data
        rapl_data=$(exec_cmd "cat /sys/class/powercap/intel-rapl/*/name 2>/dev/null | tr '\n' ' '")
        content+="• RAPL domains: $rapl_data\n"
    else
        content+="• RAPL: Not available\n"
    fi
    
    # Thermal throttling check
    content+="### THERMAL_THROTTLING\n"
    local throttle
    throttle=$(exec_cmd "grep -c 'PROCHOT' /var/log/syslog 2>/dev/null || echo 0")
    if [[ $throttle -gt 0 ]]; then
        content+="• Throttling events detected: $throttle\n"
        issues+="Thermal throttling detected; "
        status="WARNING"
    else
        content+="• No throttling events detected\n"
    fi
    
    # ECC errors (if available)
    content+="### ECC_ERRORS\n"
    if command -v edac-util &>/dev/null; then
        local ecc_errors
        ecc_errors=$(exec_sudo_cmd "edac-util -v 2>/dev/null | grep -i 'ecc\|error' | head -5")
        if [[ -n "$ecc_errors" ]]; then
            content+="$ecc_errors\n"
            issues+="ECC errors detected; "
            status="WARNING"
        else
            content+="• No ECC errors reported\n"
        fi
    else
        content+="• [TOOL_MISSING: edac-util]\n"
    fi
    
    write_section "CPU" "$content" "$status" "$issues"
    log_success "CPU scan completed"
}

#-------------------------------------------------------------------------------
# RAM Diagnostics
#-------------------------------------------------------------------------------

scan_ram() {
    log_section "RAM Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # Total memory
    content+="### RAM_TOTAL\n"
    local total_mem
    total_mem=$(exec_cmd "grep MemTotal /proc/meminfo | awk '{printf \"%.2f GB\", \$2/1024/1024}'")
    content+="• Total Memory: $total_mem\n"
    
    # Available memory
    content+="### RAM_AVAILABLE\n"
    local avail_mem
    avail_mem=$(exec_cmd "grep MemAvailable /proc/meminfo | awk '{printf \"%.2f GB\", \$2/1024/1024}'")
    content+="• Available Memory: $avail_mem\n"
    
    local mem_percent
    mem_percent=$(exec_cmd "awk '/MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{printf \"%.0f\", (t-a)/t*100}' /proc/meminfo")
    content+="• Memory Usage: ${mem_percent}%\n"
    
    if [[ "$mem_percent" =~ ^[0-9]+$ ]] && [[ "$mem_percent" -gt 90 ]]; then
        issues+="High memory usage (>90%); "
        status="WARNING"
    fi
    
    # Memory type and speed from dmidecode
    content+="### RAM_TYPE_SPEED\n"
    if command -v dmidecode &>/dev/null; then
        local mem_type mem_speed
        mem_type=$(exec_sudo_cmd "dmidecode -t memory | grep 'Type:' | head -1 | cut -d':' -f2 | xargs")
        content+="• Type: ${mem_type:-Unknown}\n"
        
        mem_speed=$(exec_sudo_cmd "dmidecode -t memory | grep 'Speed:' | head -1 | cut -d':' -f2 | xargs")
        content+="• Speed: ${mem_speed:-Unknown}\n"
    else
        content+="• [TOOL_MISSING: dmidecode]\n"
    fi
    
    # Slots information
    content+="### RAM_SLOTS\n"
    if command -v dmidecode &>/dev/null; then
        local total_slots populated_slots
        total_slots=$(exec_sudo_cmd "dmidecode -t memory | grep -c 'Memory Device'")
        populated_slots=$(exec_sudo_cmd "dmidecode -t memory | grep -A1 'Memory Device' | grep -c 'Size: [0-9]'")
        content+="• Total Slots: $total_slots\n"
        content+="• Populated Slots: $populated_slots\n"
    fi
    
    # Channel configuration
    content+="### RAM_CHANNELS\n"
    if command -v dmidecode &>/dev/null; then
        local channel_info
        channel_info=$(exec_sudo_cmd "dmidecode -t memory | grep 'Interleaved' | head -1")
        if [[ -n "$channel_info" ]]; then
            content+="• Channel Config: $channel_info\n"
        else
            content+="• Channel Config: Unknown\n"
        fi
    fi
    
    # SPD data (manufacturer, serial)
    content+="### SPD_DATA\n"
    if command -v dmidecode &>/dev/null; then
        local spd_manufacturer spd_serial
        spd_manufacturer=$(exec_sudo_cmd "dmidecode -t memory | grep 'Manufacturer:' | head -1 | cut -d':' -f2 | xargs")
        content+="• Manufacturer: ${spd_manufacturer:-Unknown}\n"
        
        spd_serial=$(exec_sudo_cmd "dmidecode -t memory | grep 'Serial Number:' | head -1 | cut -d':' -f2 | xargs")
        content+="• Serial: ${spd_serial:-Unknown}\n"
    fi
    
    # Swap/ZRAM
    content+="### SWAP_ZRAM\n"
    local swap_total swap_free
    swap_total=$(exec_cmd "grep SwapTotal /proc/meminfo | awk '{printf \"%.2f GB\", \$2/1024/1024}'")
    swap_free=$(exec_cmd "grep SwapFree /proc/meminfo | awk '{printf \"%.2f GB\", \$2/1024/1024}'")
    content+="• Swap Total: $swap_total\n"
    content+="• Swap Free: $swap_free\n"
    
    if [[ -d /sys/block/zram0 ]]; then
        content+="• ZRAM: Detected\n"
    else
        content+="• ZRAM: Not detected\n"
    fi
    
    # Page faults and OOM statistics
    content+="### PAGEFAULTS_OOM\n"
    local pagefaults oom_kills
    pagefaults=$(exec_cmd "grep pgfault /proc/vmstat | awk '{print \$2}'")
    content+="• Page Faults: $pagefaults\n"
    
    oom_kills=$(exec_sudo_cmd "dmesg | grep -c 'Out of memory' 2>/dev/null" || echo "0")
    oom_kills=$(echo "$oom_kills" | tr -d '[:space:]')
    [[ -z "$oom_kills" || ! "$oom_kills" =~ ^[0-9]+$ ]] && oom_kills=0
    content+="• OOM Kills: $oom_kills\n"
    
    if [[ "$oom_kills" -gt 0 ]]; then
        issues+="OOM kills detected; "
        status="WARNING"
    fi
    
    # ECC errors for RAM
    content+="### RAM_ECC_ERRORS\n"
    if command -v edac-util &>/dev/null; then
        local ram_ecc
        ram_ecc=$(exec_sudo_cmd "edac-util 2>/dev/null")
        if [[ -n "$ram_ecc" ]] && ! echo "$ram_ecc" | grep -q "0 errors"; then
            content+="$ram_ecc\n"
            issues+="RAM ECC errors; "
            status="WARNING"
        else
            content+="• No RAM ECC errors\n"
        fi
    else
        content+="• [TOOL_MISSING: edac-util]\n"
    fi
    
    write_section "RAM" "$content" "$status" "$issues"
    log_success "RAM scan completed"
}

#-------------------------------------------------------------------------------
# Storage Diagnostics
#-------------------------------------------------------------------------------

scan_storage() {
    log_section "Storage Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # List block devices
    content+="### STORAGE_DEVICES\n"
    if command -v lsblk &>/dev/null; then
        local lsblk_output
        lsblk_output=$(exec_cmd "lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null")
        content+="$lsblk_output\n"
    else
        content+="• [TOOL_MISSING: lsblk]\n"
    fi
    
    # SMART data for each drive
    content+="### SMART_DATA\n"
    if command -v smartctl &>/dev/null; then
        local drives
        drives=$(exec_cmd "lsblk -ndo NAME 2>/dev/null | grep -E '^sd|^nvme|^hd'")
        
        for drive in $drives; do
            content+="#### Drive: /dev/$drive\n"
            
            # Basic SMART info
            local smart_info
            smart_info=$(exec_sudo_cmd "smartctl -i /dev/$drive 2>/dev/null | grep -E 'Model|Serial|Capacity|Interface'")
            if [[ -n "$smart_info" ]]; then
                content+="$smart_info\n"
            else
                content+="• SMART info unavailable for /dev/$drive\n"
            fi
            
            # SMART health
            local smart_health
            smart_health=$(exec_sudo_cmd "smartctl -H /dev/$drive 2>/dev/null | grep 'SMART overall-health'")
            if [[ -n "$smart_health" ]]; then
                content+="$smart_health\n"
                if echo "$smart_health" | grep -qi "failed\|fail"; then
                    issues+="SMART failure on /dev/$drive; "
                    status="CRITICAL"
                fi
            fi
            
            # Temperature
            local temp
            temp=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i temperature | head -1")
            if [[ -n "$temp" ]]; then
                content+="$temp\n"
            fi
            
            # Power-On Hours
            local poh
            poh=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i 'power-on hours'")
            if [[ -n "$poh" ]]; then
                content+="$poh\n"
            fi
            
            # Reallocated sectors
            local reallocated realloc_count
            reallocated=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i 'reallocated sector'")
            if [[ -n "$reallocated" ]]; then
                content+="$reallocated\n"
                realloc_count=$(echo "$reallocated" | awk '{print $NF}')
                if [[ "$realloc_count" =~ ^[0-9]+$ ]] && [[ $realloc_count -gt 0 ]]; then
                    issues+="Reallocated sectors on /dev/$drive; "
                    status="WARNING"
                fi
            fi
            
            # Pending sectors
            local pending pending_count
            pending=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i 'pending sector'")
            if [[ -n "$pending" ]]; then
                content+="$pending\n"
                pending_count=$(echo "$pending" | awk '{print $NF}')
                if [[ "$pending_count" =~ ^[0-9]+$ ]] && [[ $pending_count -gt 0 ]]; then
                    issues+="Pending sectors on /dev/$drive; "
                    status="WARNING"
                fi
            fi
            
            # NVMe specific
            if [[ $drive == nvme* ]]; then
                local nvme_health
                nvme_health=$(exec_sudo_cmd "smartctl -a /dev/$drive 2>/dev/null | grep -E 'Critical Warning|Percentage Used|Data Units Written'")
                if [[ -n "$nvme_health" ]]; then
                    content+="$nvme_health\n"
                fi
            fi
        done
    else
        content+="• [TOOL_MISSING: smartctl]\n"
    fi
    
    # Filesystem information
    content+="### FILESYSTEM_INFO\n"
    if command -v df &>/dev/null; then
        local df_output high_usage
        df_output=$(exec_cmd "df -hT 2>/dev/null")
        content+="$df_output\n"
        
        # Check for high usage
        high_usage=$(exec_cmd "df -h 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\"); if(\$5>90) print \$6\" at \"\$5\"%\"}'")
        if [[ -n "$high_usage" ]]; then
            content+="• High Usage Partitions:\n$high_usage\n"
            issues+="High disk usage (>90%); "
            status="WARNING"
        fi
    fi
    
    # I/O scheduler
    content+="### IO_SCHEDULER\n"
    for dev in /sys/block/sd* /sys/block/nvme*; do
        if [[ -e "$dev/queue/scheduler" ]]; then
            local sched dev_name
            sched=$(exec_cmd "cat $dev/queue/scheduler 2>/dev/null")
            dev_name=$(basename "$dev")
            content+="• $dev_name: $sched\n"
        fi
    done
    
    # TRIM status
    content+="### TRIM_STATUS\n"
    local trim_support
    trim_support=$(exec_sudo_cmd "fstrim -v / 2>&1 | head -1")
    if [[ "$trim_support" == *"not supported"* ]]; then
        content+="• TRIM: Not supported\n"
    else
        content+="• TRIM: Supported\n"
    fi
    
    write_section "STORAGE" "$content" "$status" "$issues"
    log_success "Storage scan completed"
}

#-------------------------------------------------------------------------------
# GPU Diagnostics
#-------------------------------------------------------------------------------

scan_gpu() {
    log_section "GPU Diagnostics"
    local content=""
    local status="OK"
    
    # Basic GPU info from lspci
    content+="### GPU_BASIC\n"
    local gpu_info
    gpu_info=$(exec_cmd "lspci | grep -i vga")
    if [[ -n "$gpu_info" ]]; then
        content+="$gpu_info\n"
    else
        gpu_info=$(exec_cmd "lspci | grep -i 3d")
        if [[ -n "$gpu_info" ]]; then
            content+="$gpu_info\n"
        else
            content+="• No discrete GPU detected\n"
        fi
    fi
    
    # NVIDIA specific
    content+="### NVIDIA_GPU\n"
    if command -v nvidia-smi &>/dev/null; then
        local nvidia_status
        nvidia_status=$(exec_cmd "nvidia-smi --query-gpu=name,memory.total,driver_version,temperature.gpu,utilization.gpu --format=csv,noheader 2>/dev/null")
        if [[ -n "$nvidia_status" ]]; then
            content+="$nvidia_status\n"
        else
            content+="• NVIDIA GPU detected but nvidia-smi failed\n"
        fi
    else
        content+="• [TOOL_MISSING: nvidia-smi]\n"
    fi
    
    # AMD GPU
    content+="### AMD_GPU\n"
    if [[ -d /sys/class/drm ]]; then
        local amd_cards
        amd_cards=$(exec_cmd "find /sys/class/drm -name '*card*' -type d 2>/dev/null | wc -l")
        content+="• DRM cards detected: $amd_cards\n"
        
        if lsmod | grep -q amdgpu; then
            content+="• AMDGPU driver: Loaded\n"
        fi
    fi
    
    # Intel GPU
    content+="### INTEL_GPU\n"
    if lsmod | grep -q i915; then
        content+="• Intel i915 driver: Loaded\n"
        
        if [[ -f /sys/kernel/debug/dri/0/i915_guc_status ]]; then
            local guc_status
            guc_status=$(exec_sudo_cmd "cat /sys/kernel/debug/dri/0/i915_guc_status 2>/dev/null")
            content+="• GuC Status: $guc_status\n"
        fi
    fi
    
    # OpenGL/Vulkan info
    content+="### GPU_API\n"
    if command -v glxinfo &>/dev/null; then
        local opengl_version
        opengl_version=$(exec_cmd "glxinfo | grep 'OpenGL version' | head -1")
        content+="$opengl_version\n"
    else
        content+="• [TOOL_MISSING: glxinfo]\n"
    fi
    
    if command -v vulkaninfo &>/dev/null; then
        content+="• Vulkan: Available\n"
    else
        content+="• [TOOL_MISSING: vulkaninfo]\n"
    fi
    
    # Driver/module info
    content+="### GPU_DRIVER\n"
    local gpu_modules
    gpu_modules=$(exec_cmd "lsmod | grep -E 'nvidia|amdgpu|radeon|i915|nouveau'")
    if [[ -n "$gpu_modules" ]]; then
        content+="$gpu_modules\n"
    else
        content+="• No GPU modules loaded\n"
    fi
    
    write_section "GPU" "$content" "$status"
    log_success "GPU scan completed"
}

#-------------------------------------------------------------------------------
# Battery Diagnostics
#-------------------------------------------------------------------------------

scan_battery() {
    log_section "Battery Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    if [[ -d /sys/class/power_supply ]]; then
        local batteries
        batteries=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' 2>/dev/null)
        
        if [[ -n "$batteries" ]]; then
            for bat in $batteries; do
                local bat_name model design_cap full_cap wear_level cycles status_bat voltage current temp
                bat_name=$(basename "$bat")
                content+="### BATTERY_$bat_name\n"
                
                model=$(exec_cmd "cat $bat/model_name 2>/dev/null || echo 'Unknown'")
                content+="• Model: $model\n"
                
                design_cap=$(exec_cmd "cat $bat/design_capacity 2>/dev/null || echo 'N/A'")
                full_cap=$(exec_cmd "cat $bat/full_charge_capacity 2>/dev/null || echo 'N/A'")
                content+="• Design Capacity: $design_cap mAh\n"
                content+="• Full Charge Capacity: $full_cap mAh\n"
                
                if [[ "$design_cap" != "N/A" ]] && [[ "$full_cap" != "N/A" ]] && [[ "$design_cap" =~ ^[0-9]+$ ]] && [[ $design_cap -gt 0 ]]; then
                    wear_level=$(( (design_cap - full_cap) * 100 / design_cap ))
                    content+="• Wear Level: ${wear_level}%\n"
                    if [[ $wear_level -gt 20 ]]; then
                        issues+="High battery wear (${wear_level}%); "
                        status="WARNING"
                    fi
                fi
                
                cycles=$(exec_cmd "cat $bat/cycle_count 2>/dev/null || echo 'N/A'")
                content+="• Cycle Count: $cycles\n"
                
                status_bat=$(exec_cmd "cat $bat/status 2>/dev/null || echo 'Unknown'")
                content+="• Status: $status_bat\n"
                
                voltage=$(exec_cmd "cat $bat/voltage_now 2>/dev/null || echo 'N/A'")
                content+="• Voltage: $voltage µV\n"
                
                current=$(exec_cmd "cat $bat/current_now 2>/dev/null || echo 'N/A'")
                content+="• Current: $current µA\n"
                
                temp=$(exec_cmd "cat $bat/temp 2>/dev/null || echo 'N/A'")
                content+="• Temperature: ${temp}°C\n"
            done
        else
            content+="• No battery detected (desktop system?)\n"
            INFO_ISSUES+=("No battery detected")
        fi
    else
        content+="• Battery subsystem not available\n"
    fi
    
    # TLP/powertop policy
    content+="### POWER_MANAGEMENT\n"
    if command -v tlp-stat &>/dev/null; then
        local tlp_status
        tlp_status=$(exec_cmd "tlp-stat -s 2>/dev/null | head -5")
        content+="$tlp_status\n"
    else
        content+="• [TOOL_MISSING: tlp-stat]\n"
    fi
    
    if command -v powertop &>/dev/null; then
        content+="• PowerTop: Available\n"
    else
        content+="• [TOOL_MISSING: powertop]\n"
    fi
    
    write_section "BATTERY" "$content" "$status" "$issues"
    log_success "Battery scan completed"
}

#-------------------------------------------------------------------------------
# Cooling & Thermal Diagnostics
#-------------------------------------------------------------------------------

scan_cooling() {
    log_section "Cooling & Thermal Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # Temperatures from sensors
    content+="### TEMPERATURES\n"
    if command -v sensors &>/dev/null; then
        local sensors_output high_temp
        sensors_output=$(exec_cmd "sensors 2>/dev/null")
        if [[ -n "$sensors_output" ]]; then
            content+="$sensors_output\n"
            
            high_temp=$(echo "$sensors_output" | grep -E 'Core.*\+[6-9][0-9]°C|Package.*\+[6-9][0-9]°C|Tdie.*\+[6-9][0-9]°C')
            if [[ -n "$high_temp" ]]; then
                content+="• HIGH TEMPERATURE DETECTED:\n$high_temp\n"
                issues+="High temperature detected; "
                status="WARNING"
            fi
        else
            content+="• No sensor data available\n"
        fi
    else
        content+="• [TOOL_MISSING: sensors]\n"
    fi
    
    # Fan speeds
    content+="### FAN_SPEEDS\n"
    if command -v sensors &>/dev/null; then
        local fan_data
        fan_data=$(exec_cmd "sensors 2>/dev/null | grep -i 'fan\|rpm'")
        if [[ -n "$fan_data" ]]; then
            content+="$fan_data\n"
        else
            content+="• No fan speed data available\n"
        fi
    fi
    
    # PWM controls
    content+="### PWM_CONTROLS\n"
    local pwm_files
    pwm_files=$(find /sys/class/hwmon -name 'pwm*' 2>/dev/null | head -5)
    if [[ -n "$pwm_files" ]]; then
        for pwm in $pwm_files; do
            local value
            value=$(exec_cmd "cat $pwm 2>/dev/null")
            content+="• $(basename "$pwm"): $value\n"
        done
    else
        content+="• No PWM controls found\n"
    fi
    
    # Thermal trip points
    content+="### THERMAL_TRIP_POINTS\n"
    if [[ -d /sys/class/thermal ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            local zone_type zone_temp
            zone_type=$(exec_cmd "cat $zone/type 2>/dev/null")
            zone_temp=$(exec_cmd "cat $zone/temp 2>/dev/null")
            if [[ -n "$zone_type" ]]; then
                content+="• $zone_type: ${zone_temp}m°C\n"
            fi
        done
    fi
    
    # Voltages
    content+="### VOLTAGES\n"
    if command -v sensors &>/dev/null; then
        local voltage_data
        voltage_data=$(exec_cmd "sensors 2>/dev/null | grep -E 'Vcore|3\.3V|5V|12V'")
        if [[ -n "$voltage_data" ]]; then
            content+="$voltage_data\n"
        else
            content+="• No voltage data available\n"
        fi
    fi
    
    write_section "COOLING" "$content" "$status" "$issues"
    log_success "Cooling scan completed"
}

#-------------------------------------------------------------------------------
# Network Diagnostics
#-------------------------------------------------------------------------------

scan_network() {
    log_section "Network Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # Network interfaces
    content+="### NETWORK_INTERFACES\n"
    if command -v ip &>/dev/null; then
        local ip_output
        ip_output=$(exec_cmd "ip -br addr 2>/dev/null")
        content+="$ip_output\n"
    else
        content+="• [TOOL_MISSING: ip]\n"
    fi
    
    # Detailed interface info
    content+="### INTERFACE_DETAILS\n"
    for iface in /sys/class/net/*; do
        local iface_name mac speed driver rx_errors tx_errors rx_dropped tx_dropped
        iface_name=$(basename "$iface")
        content+="#### Interface: $iface_name\n"
        
        mac=$(exec_cmd "cat $iface/address 2>/dev/null")
        content+="• MAC: $mac\n"
        
        speed=$(exec_cmd "cat $iface/speed 2>/dev/null || echo 'N/A'")
        content+="• Speed: ${speed} Mbps\n"
        
        driver=$(exec_cmd "ethtool -i $iface_name 2>/dev/null | grep driver | cut -d: -f2 | xargs")
        content+="• Driver: ${driver:-Unknown}\n"
        
        rx_errors=$(exec_cmd "cat $iface/statistics/rx_errors 2>/dev/null || echo 0")
        tx_errors=$(exec_cmd "cat $iface/statistics/tx_errors 2>/dev/null || echo 0")
        rx_dropped=$(exec_cmd "cat $iface/statistics/rx_dropped 2>/dev/null || echo 0")
        tx_dropped=$(exec_cmd "cat $iface/statistics/tx_dropped 2>/dev/null || echo 0")
        
        content+="• RX Errors: $rx_errors\n"
        content+="• TX Errors: $tx_errors\n"
        content+="• RX Dropped: $rx_dropped\n"
        content+="• TX Dropped: $tx_dropped\n"
        
        if [[ "$rx_errors" =~ ^[0-9]+$ ]] && [[ $rx_errors -gt 100 ]] || [[ "$tx_errors" =~ ^[0-9]+$ ]] && [[ $tx_errors -gt 100 ]]; then
            issues+="Network errors on $iface_name; "
            status="WARNING"
        fi
    done
    
    # Wi-Fi specific
    content+="### WIFI_INFO\n"
    if command -v iwconfig &>/dev/null; then
        local wifi_info
        wifi_info=$(exec_cmd "iwconfig 2>/dev/null | grep -v 'no wireless'")
        if [[ -n "$wifi_info" ]]; then
            content+="$wifi_info\n"
        else
            content+="• No wireless interfaces\n"
        fi
    fi
    
    if command -v iw &>/dev/null; then
        local iw_info
        iw_info=$(exec_cmd "iw dev 2>/dev/null")
        if [[ -n "$iw_info" ]]; then
            content+="$iw_info\n"
        fi
    else
        content+="• [TOOL_MISSING: iw]\n"
    fi
    
    # Routing table
    content+="### ROUTING_TABLE\n"
    if command -v ip &>/dev/null; then
        local route_output
        route_output=$(exec_cmd "ip route 2>/dev/null")
        content+="$route_output\n"
    fi
    
    # DNS configuration
    content+="### DNS_CONFIG\n"
    if [[ -f /etc/resolv.conf ]]; then
        local dns_config
        dns_config=$(exec_cmd "cat /etc/resolv.conf 2>/dev/null")
        content+="$dns_config\n"
    fi
    
    # TCP statistics
    content+="### TCP_STATS\n"
    if command -v ss &>/dev/null; then
        local tcp_stats
        tcp_stats=$(exec_cmd "ss -s 2>/dev/null")
        content+="$tcp_stats\n"
    else
        content+="• [TOOL_MISSING: ss]\n"
    fi
    
    # Connection tracking
    content+="### CONNECTIONS\n"
    if command -v ss &>/dev/null; then
        local connections
        connections=$(exec_cmd "ss -tuln 2>/dev/null | head -20")
        content+="$connections\n"
    fi
    
    write_section "NETWORK" "$content" "$status" "$issues"
    log_success "Network scan completed"
}

#-------------------------------------------------------------------------------
# Audio Diagnostics
#-------------------------------------------------------------------------------

scan_audio() {
    log_section "Audio Diagnostics"
    local content=""
    local status="OK"
    
    # ALSA devices
    content+="### ALSA_DEVICES\n"
    if [[ -d /proc/asound ]]; then
        local alsa_cards
        alsa_cards=$(exec_cmd "cat /proc/asound/cards 2>/dev/null")
        if [[ -n "$alsa_cards" ]]; then
            content+="$alsa_cards\n"
        else
            content+="• No ALSA sound cards detected\n"
        fi
    else
        content+="• ALSA not available\n"
    fi
    
    # PulseAudio/PipeWire
    content+="### AUDIO_SERVER\n"
    if command -v pactl &>/dev/null; then
        local pulse_info
        pulse_info=$(exec_cmd "pactl info 2>/dev/null | grep -E 'Server Name|Default Sink|Default Source'")
        if [[ -n "$pulse_info" ]]; then
            content+="$pulse_info\n"
        else
            content+="• PulseAudio server not running\n"
        fi
    elif command -v pw-cli &>/dev/null; then
        content+="• PipeWire detected\n"
    else
        content+="• No audio server detected\n"
    fi
    
    # Codec info
    content+="### CODEC_INFO\n"
    if [[ -d /proc/asound ]]; then
        local codec_info
        codec_info=$(exec_cmd "find /proc/asound -name 'codec*' -exec cat {} \\; 2>/dev/null | head -20")
        if [[ -n "$codec_info" ]]; then
            content+="$codec_info\n"
        fi
    fi
    
    # Volume/mute status
    content+="### VOLUME_STATUS\n"
    if command -v amixer &>/dev/null; then
        local volume_info
        volume_info=$(exec_cmd "amixer get Master 2>/dev/null | grep -E 'Mono:|Front Left:'")
        if [[ -n "$volume_info" ]]; then
            content+="$volume_info\n"
        else
            content+="• Unable to get volume info\n"
        fi
    else
        content+="• [TOOL_MISSING: amixer]\n"
    fi
    
    write_section "AUDIO" "$content" "$status"
    log_success "Audio scan completed"
}

#-------------------------------------------------------------------------------
# Motherboard/BIOS Diagnostics
#-------------------------------------------------------------------------------

scan_motherboard() {
    log_section "Motherboard & BIOS Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # BIOS info from dmidecode
    content+="### BIOS_INFO\n"
    if command -v dmidecode &>/dev/null; then
        local bios_vendor bios_version bios_date
        bios_vendor=$(exec_sudo_cmd "dmidecode -t bios | grep 'Vendor:' | cut -d: -f2 | xargs")
        content+="• Vendor: ${bios_vendor:-Unknown}\n"
        
        bios_version=$(exec_sudo_cmd "dmidecode -t bios | grep 'Version:' | cut -d: -f2 | xargs")
        content+="• Version: ${bios_version:-Unknown}\n"
        
        bios_date=$(exec_sudo_cmd "dmidecode -t bios | grep 'Date:' | cut -d: -f2 | xargs")
        content+="• Date: ${bios_date:-Unknown}\n"
    else
        content+="• [TOOL_MISSING: dmidecode]\n"
    fi
    
    # UEFI/BIOS mode
    content+="### BOOT_MODE\n"
    if [[ -d /sys/firmware/efi ]]; then
        content+="• Boot Mode: UEFI\n"
    else
        content+="• Boot Mode: Legacy BIOS\n"
        issues+="Legacy BIOS mode; "
        status="WARNING"
    fi
    
    # Secure Boot
    content+="### SECURE_BOOT\n"
    if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
        local secure_boot
        secure_boot=$(exec_sudo_cmd "od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}'")
        if [[ "$secure_boot" == "1" ]]; then
            content+="• Secure Boot: Enabled\n"
        else
            content+="• Secure Boot: Disabled\n"
        fi
    else
        content+="• Secure Boot: N/A (Legacy mode)\n"
    fi
    
    # Motherboard info
    content+="### MOTHERBOARD_INFO\n"
    if command -v dmidecode &>/dev/null; then
        local mb_manufacturer mb_product mb_serial
        mb_manufacturer=$(exec_sudo_cmd "dmidecode -t baseboard | grep 'Manufacturer:' | cut -d: -f2 | xargs")
        content+="• Manufacturer: ${mb_manufacturer:-Unknown}\n"
        
        mb_product=$(exec_sudo_cmd "dmidecode -t baseboard | grep 'Product Name:' | cut -d: -f2 | xargs")
        content+="• Product: ${mb_product:-Unknown}\n"
        
        mb_serial=$(exec_sudo_cmd "dmidecode -t baseboard | grep 'Serial Number:' | cut -d: -f2 | xargs")
        content+="• Serial: ${mb_serial:-Unknown}\n"
    fi
    
    # System UUID
    content+="### SYSTEM_UUID\n"
    if [[ -f /sys/class/dmi/id/product_uuid ]]; then
        local uuid
        uuid=$(exec_sudo_cmd "cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo 'N/A'")
        content+="• UUID: $uuid\n"
    fi
    
    # Virtualization support
    content+="### VIRTUALIZATION\n"
    local virt_flags
    virt_flags=$(exec_cmd "grep -E 'vmx|svm' /proc/cpuinfo | head -1")
    if [[ -n "$virt_flags" ]]; then
        if echo "$virt_flags" | grep -q vmx; then
            content+="• Intel VT-x: Supported\n"
        else
            content+="• AMD-V: Supported\n"
        fi
    else
        content+="• Hardware Virtualization: Not detected\n"
        issues+="No hardware virtualization support; "
    fi
    
    # IOMMU status
    content+="### IOMMU_STATUS\n"
    if exec_cmd "dmesg | grep -q 'DMAR\|IOMMU'"; then
        content+="• IOMMU: Enabled\n"
    else
        content+="• IOMMU: Not detected\n"
    fi
    
    # TPM
    content+="### TPM_STATUS\n"
    if [[ -d /sys/class/tpm ]]; then
        content+="• TPM: Detected\n"
    else
        content+="• TPM: Not detected\n"
    fi
    
    # Firmware updates
    content+="### FIRMWARE_UPDATES\n"
    if command -v fwupdmgr &>/dev/null; then
        local fw_status
        fw_status=$(exec_cmd "fwupdmgr get-devices 2>/dev/null | head -10")
        if [[ -n "$fw_status" ]]; then
            content+="$fw_status\n"
        fi
    else
        content+="• [TOOL_MISSING: fwupdmgr]\n"
    fi
    
    # PCIe AER errors
    content+="### PCIE_AER_ERRORS\n"
    local aer_errors
    aer_errors=$(exec_sudo_cmd "dmesg | grep -i 'aer\|pcie.*error' | tail -5")
    if [[ -n "$aer_errors" ]]; then
        content+="$aer_errors\n"
        issues+="PCIe AER errors detected; "
        status="WARNING"
    else
        content+="• No PCIe AER errors detected\n"
    fi
    
    write_section "MOTHERBOARD_BIOS" "$content" "$status" "$issues"
    log_success "Motherboard/BIOS scan completed"
}

#-------------------------------------------------------------------------------
# System Metrics
#-------------------------------------------------------------------------------

scan_system_metrics() {
    log_section "System Metrics"
    local content=""
    local status="OK"
    
    # Uptime
    content+="### UPTIME\n"
    local uptime_info
    uptime_info=$(exec_cmd "uptime 2>/dev/null")
    content+="$uptime_info\n"
    
    # Load average
    content+="### LOAD_AVERAGE\n"
    local load_avg
    load_avg=$(exec_cmd "cat /proc/loadavg 2>/dev/null")
    content+="• Load Average: $load_avg\n"
    
    # Interrupts
    content+="### INTERRUPTS\n"
    local interrupts
    interrupts=$(exec_cmd "wc -l < /proc/interrupts 2>/dev/null")
    content+="• Total Interrupt Types: $interrupts\n"
    
    # Context switches
    content+="### CONTEXT_SWITCHES\n"
    local ctx_switches
    ctx_switches=$(exec_cmd "grep ctxt /proc/vmstat | awk '{print \$2}'")
    content+="• Context Switches: $ctx_switches\n"
    
    # CPU time breakdown
    content+="### CPU_TIME\n"
    local cpu_time
    cpu_time=$(exec_cmd "head -1 /proc/stat 2>/dev/null")
    content+="$cpu_time\n"
    
    # Loaded modules
    content+="### LOADED_MODULES\n"
    local module_count recent_modules
    module_count=$(exec_cmd "lsmod | wc -l")
    content+="• Loaded Modules: $module_count\n"
    
    recent_modules=$(exec_cmd "lsmod | head -10")
    content+="$recent_modules\n"
    
    # Kernel messages
    content+="### KERNEL_MESSAGES\n"
    local dmesg_recent
    dmesg_recent=$(exec_cmd "dmesg --level=err,warn 2>/dev/null | tail -10")
    if [[ -n "$dmesg_recent" ]]; then
        content+="Recent kernel warnings/errors:\n$dmesg_recent\n"
    else
        content+="• No recent kernel warnings/errors\n"
    fi
    
    # Inodes
    content+="### INODES\n"
    local inode_usage
    inode_usage=$(exec_cmd "df -i 2>/dev/null | head -5")
    content+="$inode_usage\n"
    
    # Cgroups info
    content+="### CGROUPS\n"
    if [[ -d /sys/fs/cgroup ]]; then
        content+="• Cgroups v2: Detected\n"
    elif [[ -d /sys/fs/cgroup/systemd ]]; then
        content+="• Cgroups v1: Detected\n"
    else
        content+="• Cgroups: Not detected\n"
    fi
    
    # Virtualization status
    content+="### VIRT_STATUS\n"
    if command -v systemd-detect-virt &>/dev/null; then
        local virt_type
        virt_type=$(exec_cmd "systemd-detect-virt 2>/dev/null")
        content+="• Virtualization Type: $virt_type\n"
    fi
    
    # TCP retransmits
    content+="### TCP_RETRANSMITS\n"
    local retransmits
    retransmits=$(exec_cmd "netstat -s 2>/dev/null | grep -i retransmit | head -1")
    if [[ -n "$retransmits" ]]; then
        content+="$retransmits\n"
    else
        content+="• TCP retransmit data unavailable\n"
    fi
    
    write_section "SYSTEM_METRICS" "$content" "$status"
    log_success "System metrics scan completed"
}

#-------------------------------------------------------------------------------
# Kernel & Syscalls
#-------------------------------------------------------------------------------

scan_kernel() {
    log_section "Kernel & Syscalls"
    local content=""
    local status="OK"
    
    # Kernel version
    content+="### KERNEL_VERSION\n"
    local kernel_ver kernel_config
    kernel_ver=$(exec_cmd "uname -r")
    content+="• Version: $kernel_ver\n"
    
    kernel_config=$(exec_cmd "uname -v")
    content+="• Build Info: $kernel_config\n"
    
    # PREEMPT status
    content+="### PREEMPT_STATUS\n"
    if [[ -f /boot/config-$(uname -r) ]]; then
        local preempt_config
        preempt_config=$(exec_cmd "grep CONFIG_PREEMPT /boot/config-$(uname -r) 2>/dev/null")
        content+="$preempt_config\n"
    elif [[ -f /proc/config.gz ]]; then
        local preempt_config
        preempt_config=$(exec_cmd "zcat /proc/config.gz 2>/dev/null | grep CONFIG_PREEMPT")
        content+="$preempt_config\n"
    else
        content+="• Preempt config: Unavailable\n"
    fi
    
    # HZ value
    content+="### HZ_VALUE\n"
    local hz_value
    hz_value=$(exec_cmd "grep HZ /boot/config-$(uname -r) 2>/dev/null | head -1")
    if [[ -n "$hz_value" ]]; then
        content+="$hz_value\n"
    else
        content+="• HZ value: Unavailable\n"
    fi
    
    # Buddy info
    content+="### BUDDY_INFO\n"
    local buddy_info
    buddy_info=$(exec_cmd "cat /proc/buddyinfo 2>/dev/null | head -5")
    if [[ -n "$buddy_info" ]]; then
        content+="$buddy_info\n"
    fi
    
    # Page type info
    content+="### PAGE_TYPE_INFO\n"
    if [[ -f /proc/pagetypeinfo ]]; then
        local page_type
        page_type=$(exec_cmd "head -20 /proc/pagetypeinfo 2>/dev/null")
        content+="$page_type\n"
    else
        content+="• Page type info: Unavailable\n"
    fi
    
    # SoftIRQ/HardIRQ balance
    content+="### IRQ_BALANCE\n"
    local softirq
    softirq=$(exec_cmd "grep softirq /proc/stat 2>/dev/null")
    content+="$softirq\n"
    
    # Lock stats (if enabled)
    content+="### LOCK_STATS\n"
    if [[ -f /proc/lock_stat ]]; then
        local lock_stat
        lock_stat=$(exec_sudo_cmd "head -30 /proc/lock_stat 2>/dev/null")
        content+="$lock_stat\n"
    else
        content+="• Lock stats: Not enabled\n"
    fi
    
    # Module dependencies
    content+="### MODULE_DEPS\n"
    local mod_deps
    mod_deps=$(exec_cmd "lsmod | head -5")
    content+="$mod_deps\n"
    
    write_section "KERNEL_SYSCALLS" "$content" "$status"
    log_success "Kernel scan completed"
}

#-------------------------------------------------------------------------------
# Security Diagnostics
#-------------------------------------------------------------------------------

scan_security() {
    log_section "Security Diagnostics"
    local content=""
    local status="OK"
    local issues=""
    
    # SELinux status
    content+="### SELINUX_STATUS\n"
    if command -v getenforce &>/dev/null; then
        local selinux_mode
        selinux_mode=$(exec_cmd "getenforce 2>/dev/null")
        content+="• SELinux Mode: $selinux_mode\n"
    else
        content+="• SELinux: Not installed\n"
    fi
    
    # AppArmor status
    content+="### APPARMOR_STATUS\n"
    if command -v aa-status &>/dev/null; then
        local apparmor_status
        apparmor_status=$(exec_sudo_cmd "aa-status 2>/dev/null | head -10")
        if [[ -n "$apparmor_status" ]]; then
            content+="$apparmor_status\n"
        else
            content+="• AppArmor: Not active\n"
        fi
    else
        content+="• AppArmor: Not installed\n"
    fi
    
    # Firewall status
    content+="### FIREWALL_STATUS\n"
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(exec_sudo_cmd "ufw status 2>/dev/null | head -5")
        content+="$ufw_status\n"
    elif command -v firewall-cmd &>/dev/null; then
        local firewalld_status
        firewalld_status=$(exec_sudo_cmd "firewall-cmd --state 2>/dev/null")
        content+="• Firewalld: $firewalld_status\n"
    elif command -v nft &>/dev/null; then
        local nft_rules
        nft_rules=$(exec_sudo_cmd "nft list ruleset 2>/dev/null | head -10")
        if [[ -n "$nft_rules" ]]; then
            content+="• NFTables rules present\n"
        else
            content+="• NFTables: No rules\n"
        fi
    else
        content+="• Firewall: Unknown\n"
    fi
    
    # SUID files
    content+="### SUID_FILES\n"
    local suid_count suid_files
    suid_count=$(exec_sudo_cmd "find / -perm -4000 -type f 2>/dev/null | wc -l")
    content+="• SUID Files Count: $suid_count\n"
    
    suid_files=$(exec_sudo_cmd "find /usr -perm -4000 -type f 2>/dev/null | head -10")
    if [[ -n "$suid_files" ]]; then
        content+="Common SUID binaries:\n$suid_files\n"
    fi
    
    # SSH login attempts
    content+="### SSH_LOGINS\n"
    if [[ -f /var/log/auth.log ]]; then
        local ssh_failures
        ssh_failures=$(exec_cmd "grep 'Failed password' /var/log/auth.log 2>/dev/null | wc -l")
        content+="• Failed SSH Attempts: $ssh_failures\n"
        if [[ "$ssh_failures" =~ ^[0-9]+$ ]] && [[ $ssh_failures -gt 10 ]]; then
            issues+="Multiple failed SSH attempts; "
            status="WARNING"
        fi
    elif [[ -f /var/log/secure ]]; then
        local ssh_failures
        ssh_failures=$(exec_cmd "grep 'Failed password' /var/log/secure 2>/dev/null | wc -l")
        content+="• Failed SSH Attempts: $ssh_failures\n"
    else
        content+="• SSH logs: Unavailable\n"
    fi
    
    # Rootkit detection tools
    content+="### ROOTKIT_DETECTION\n"
    if command -v rkhunter &>/dev/null; then
        content+="• RKHunter: Installed\n"
    else
        content+="• RKHunter: Not installed\n"
    fi
    
    if command -v chkrootkit &>/dev/null; then
        content+="• Chkrootkit: Installed\n"
    else
        content+="• Chkrootkit: Not installed\n"
    fi
    
    # Package integrity
    content+="### PACKAGE_INTEGRITY\n"
    if command -v debsums &>/dev/null; then
        content+="• Debsums: Available\n"
    elif command -v rpm &>/dev/null; then
        local rpm_verify
        rpm_verify=$(exec_sudo_cmd "rpm -Va 2>/dev/null | wc -l")
        content+="• RPM Verify Issues: $rpm_verify\n"
    else
        content+="• Package integrity tools: Unavailable\n"
    fi
    
    # Audit daemon
    content+="### AUDIT_DAEMON\n"
    if command -v auditctl &>/dev/null; then
        local audit_status
        audit_status=$(exec_sudo_cmd "auditctl -s 2>/dev/null | head -5")
        if [[ -n "$audit_status" ]]; then
            content+="$audit_status\n"
        else
            content+="• Audit daemon: Not active\n"
        fi
    else
        content+="• Audit daemon: Not installed\n"
    fi
    
    write_section "SECURITY" "$content" "$status" "$issues"
    log_success "Security scan completed"
}

#-------------------------------------------------------------------------------
# Filesystem & I/O
#-------------------------------------------------------------------------------

scan_filesystem() {
    log_section "Filesystem & I/O"
    local content=""
    local status="OK"
    
    # Mount options
    content+="### MOUNT_OPTIONS\n"
    local mount_opts
    mount_opts=$(exec_cmd "mount | grep -E '^/dev' | head -10")
    content+="$mount_opts\n"
    
    # Check for noatime
    if ! echo "$mount_opts" | grep -q "noatime"; then
        content+="• Note: noatime not enabled on root filesystem\n"
        INFO_ISSUES+=("Consider enabling noatime for performance")
    fi
    
    # Filesystem fragmentation (ext4)
    content+="### FRAGMENTATION\n"
    if command -v e4defrag &>/dev/null; then
        content+="• e4defrag: Available\n"
    else
        content+="• Fragmentation analysis: Tool unavailable\n"
    fi
    
    # Journal info
    content+="### JOURNAL_INFO\n"
    if command -v dumpe2fs &>/dev/null; then
        local journal_info
        journal_info=$(exec_sudo_cmd "dumpe2fs -h /dev/sda1 2>/dev/null | grep -i journal")
        if [[ -n "$journal_info" ]]; then
            content+="$journal_info\n"
        fi
    else
        content+="• Journal info: Tool unavailable\n"
    fi
    
    # Dirty pages
    content+="### DIRTY_PAGES\n"
    local dirty_ratio dirty_background_ratio
    dirty_ratio=$(exec_cmd "cat /proc/sys/vm/dirty_ratio 2>/dev/null")
    dirty_background_ratio=$(exec_cmd "cat /proc/sys/vm/dirty_background_ratio 2>/dev/null")
    content+="• Dirty Ratio: $dirty_ratio\n"
    content+="• Dirty Background Ratio: $dirty_background_ratio\n"
    
    # Writeback threads
    content+="### WRITEBACK_THREADS\n"
    local bdi_threads
    bdi_threads=$(exec_cmd "ps aux | grep -c '[w]riteback' 2>/dev/null")
    content+="• Writeback Threads: $bdi_threads\n"
    
    # Block device queue depth
    content+="### QUEUE_DEPTH\n"
    for dev in /sys/block/sd* /sys/block/nvme*; do
        if [[ -e "$dev/queue/nr_requests" ]]; then
            local nr_req dev_name
            nr_req=$(exec_cmd "cat $dev/queue/nr_requests 2>/dev/null")
            dev_name=$(basename "$dev")
            content+="• $dev_name nr_requests: $nr_req\n"
        fi
    done
    
    write_section "FILESYSTEM_IO" "$content" "$status"
    log_success "Filesystem scan completed"
}

#-------------------------------------------------------------------------------
# Power Management
#-------------------------------------------------------------------------------

scan_power_mgmt() {
    log_section "Power Management"
    local content=""
    local status="OK"
    
    # CPU frequency scaling
    content+="### CPU_FREQ_SCALING\n"
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local available_governors current_governor freq_range
        available_governors=$(exec_cmd "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null")
        content+="• Available Governors: $available_governors\n"
        
        current_governor=$(exec_cmd "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")
        content+="• Current Governor: $current_governor\n"
        
        freq_range="$(exec_cmd "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null")-$(exec_cmd "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null")"
        content+="• Frequency Range: ${freq_range} kHz\n"
    fi
    
    # C-states
    content+="### C_STATES\n"
    local cstate_count
    cstate_count=$(find /sys/devices/system/cpu/cpu0/cpuidle -maxdepth 1 -name 'state*' 2>/dev/null | wc -l)
    content+="• Available C-states: $cstate_count\n"
    
    # P-states
    content+="### P_STATES\n"
    if [[ -f /sys/devices/system/cpu/intel_pstate/status ]]; then
        local pstate_status
        pstate_status=$(exec_cmd "cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null")
        content+="• Intel P-state: $pstate_status\n"
    fi
    
    # Runtime PM
    content+="### RUNTIME_PM\n"
    local autosuspend_delay
    autosuspend_delay=$(exec_cmd "cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null")
    content+="• USB Autosuspend Delay: $autosuspend_delay\n"
    
    # Wakeup sources
    content+="### WAKEUP_SOURCES\n"
    if [[ -f /proc/acpi/wakeup ]]; then
        local wakeup_devices
        wakeup_devices=$(exec_cmd "cat /proc/acpi/wakeup 2>/dev/null | head -10")
        content+="$wakeup_devices\n"
    fi
    
    # ASPM status
    content+="### ASPM_STATUS\n"
    local aspm_status
    aspm_status=$(exec_cmd "dmesg | grep -i aspm | tail -3")
    if [[ -n "$aspm_status" ]]; then
        content+="$aspm_status\n"
    else
        content+="• ASPM status: Unknown\n"
    fi
    
    # Powercap
    content+="### POWERCAP\n"
    if [[ -d /sys/class/powercap ]]; then
        local powercap_domains
        powercap_domains=$(exec_cmd "find /sys/class/powercap -name 'name' -exec cat {} \\; 2>/dev/null")
        content+="• Powercap Domains: $powercap_domains\n"
    fi
    
    write_section "POWER_MGMT" "$content" "$status"
    log_success "Power management scan completed"
}

#-------------------------------------------------------------------------------
# User-space Analysis
#-------------------------------------------------------------------------------

scan_userspace() {
    log_section "User-space Analysis"
    local content=""
    local status="OK"
    
    # Process count
    content+="### PROCESS_COUNT\n"
    local proc_count
    proc_count=$(exec_cmd "ps aux | wc -l")
    content+="• Total Processes: $proc_count\n"
    
    # Top memory consumers
    content+="### TOP_MEMORY\n"
    local top_mem
    top_mem=$(exec_cmd "ps aux --sort=-%mem | head -6")
    content+="$top_mem\n"
    
    # Top CPU consumers
    content+="### TOP_CPU\n"
    local top_cpu
    top_cpu=$(exec_cmd "ps aux --sort=-%cpu | head -6")
    content+="$top_cpu\n"
    
    # FD limits
    content+="### FD_LIMITS\n"
    local fd_limit fd_usage
    fd_limit=$(exec_cmd "ulimit -n 2>/dev/null")
    content+="• Open Files Limit: $fd_limit\n"
    
    fd_usage=$(exec_cmd "cat /proc/sys/fs/file-nr 2>/dev/null")
    content+="• File Handles in Use: $fd_usage\n"
    
    # Core dumps
    content+="### CORE_DUMPS\n"
    if command -v coredumpctl &>/dev/null; then
        local coredump_count
        coredump_count=$(exec_cmd "coredumpctl list 2>/dev/null | wc -l")
        content+="• Core Dumps: $coredump_count\n"
    else
        content+="• Coredumpctl: Not available\n"
    fi
    
    # Library dependencies (sample)
    content+="### LIBRARY_DEPS\n"
    if command -v ldd &>/dev/null; then
        local bash_deps
        bash_deps=$(exec_cmd "ldd /bin/bash 2>/dev/null | wc -l")
        content+="• Bash Dependencies: $bash_deps libraries\n"
    fi
    
    write_section "USER_SPACE" "$content" "$status"
    log_success "User-space scan completed"
}

#-------------------------------------------------------------------------------
# Observability Tools
#-------------------------------------------------------------------------------

scan_observability() {
    log_section "Observability Tools"
    local content=""
    local status="OK"
    
    # eBPF/BCC tools
    content+="### EBPF_TOOLS\n"
    if command -v bpftrace &>/dev/null; then
        content+="• bpftrace: Available\n"
    else
        content+="• bpftrace: Not installed\n"
    fi
    
    if [[ -d /usr/share/bcc/tools ]]; then
        content+="• BCC tools: Installed\n"
    else
        content+="• BCC tools: Not installed\n"
    fi
    
    # Monitoring tools
    content+="### MONITORING_TOOLS\n"
    local monitoring_tools=("prometheus" "node_exporter" "grafana" "netdata" "glances" "btop" "htop")
    for tool in "${monitoring_tools[@]}"; do
        if command -v "$tool" &>/dev/null || pgrep -x "$tool" &>/dev/null; then
            content+="• $tool: Available/Running\n"
        fi
    done
    
    # Python psutil
    content+="### PYTHON_MONITORING\n"
    if python3 -c "import psutil" 2>/dev/null; then
        content+="• Python psutil: Available\n"
    else
        content+="• Python psutil: Not installed\n"
    fi
    
    # hw-probe/inxi
    content+="### HARDWARE_PROBE\n"
    if command -v inxi &>/dev/null; then
        content+="• inxi: Available\n"
    else
        content+="• inxi: Not installed\n"
    fi
    
    if command -v hw-probe &>/dev/null; then
        content+="• hw-probe: Available\n"
    fi
    
    write_section "OBSERVABILITY" "$content" "$status"
    log_success "Observability scan completed"
}

#-------------------------------------------------------------------------------
# MCE/Hardware Errors
#-------------------------------------------------------------------------------

scan_mce_errors() {
    log_section "MCE & Hardware Errors"
    local content=""
    local status="OK"
    local issues=""
    
    # mcelog
    content+="### MCELOG\n"
    if command -v mcelog &>/dev/null; then
        local mce_records
        mce_records=$(exec_sudo_cmd "mcelog --client 2>/dev/null | head -10")
        if [[ -n "$mce_records" ]]; then
            content+="$mce_records\n"
            issues+="MCE records found; "
            status="WARNING"
        else
            content+="• No MCE records\n"
        fi
    else
        content+="• mcelog: Not installed\n"
    fi
    
    # ras-mc-ctl
    content+="### RAS_MC_CTL\n"
    if command -v ras-mc-ctl &>/dev/null; then
        local ras_status
        ras_status=$(exec_sudo_cmd "ras-mc-ctl --errors 2>/dev/null")
        if [[ -n "$ras_status" ]] && ! echo "$ras_status" | grep -q "0 errors"; then
            content+="$ras_status\n"
            issues+="RAS errors detected; "
            status="WARNING"
        else
            content+="• No RAS errors\n"
        fi
    else
        content+="• ras-mc-ctl: Not installed\n"
    fi
    
    # EDAC
    content+="### EDAC_STATUS\n"
    if [[ -d /sys/devices/system/edac ]]; then
        local edac_status
        edac_status=$(exec_cmd "find /sys/devices/system/edac -name '*count*' -exec cat {} \\; 2>/dev/null")
        if [[ -n "$edac_status" ]]; then
            content+="$edac_status\n"
        else
            content+="• EDAC: No errors recorded\n"
        fi
    fi
    
    # Hardware errors in dmesg
    content+="### DMESG_HW_ERRORS\n"
    local hw_errors
    hw_errors=$(exec_cmd "dmesg | grep -iE 'hardware error|mce|machine check' | tail -5")
    if [[ -n "$hw_errors" ]]; then
        content+="$hw_errors\n"
        issues+="Hardware errors in dmesg; "
        status="WARNING"
    else
        content+="• No hardware errors in dmesg\n"
    fi
    
    # Watchdog resets
    content+="### WATCHDOG_RESETS\n"
    local watchdog_resets
    watchdog_resets=$(exec_cmd "dmesg | grep -c 'watchdog' 2>/dev/null || echo 0")
    watchdog_resets=$(echo "$watchdog_resets" | tr -d '[:space:]')
    [[ ! "$watchdog_resets" =~ ^[0-9]+$ ]] && watchdog_resets=0
    content+="• Watchdog Events: $watchdog_resets\n"
    
    write_section "MCE_HW_ERRORS" "$content" "$status" "$issues"
    log_success "MCE/HW errors scan completed"
}

#-------------------------------------------------------------------------------
# Logs Analysis
#-------------------------------------------------------------------------------

scan_logs() {
    log_section "Logs Analysis"
    local content=""
    local status="OK"
    local issues=""
    
    # Panic/OOPS
    content+="### PANIC_OOPS\n"
    local panic_count
    panic_count=$(exec_cmd "dmesg | grep -c -i 'panic\|oops' 2>/dev/null || echo 0")
    panic_count=$(echo "$panic_count" | tr -d '[:space:]')
    [[ ! "$panic_count" =~ ^[0-9]+$ ]] && panic_count=0
    content+="• Panic/OOPS Count: $panic_count\n"
    if [[ $panic_count -gt 0 ]]; then
        local panic_logs
        panic_logs=$(exec_cmd "dmesg | grep -i 'panic\|oops' | tail -5")
        content+="$panic_logs\n"
        issues+="Kernel panic/oops detected; "
        status="CRITICAL"
    fi
    
    # Lockups
    content+="### LOCKUPS\n"
    local lockup_count
    lockup_count=$(exec_cmd "dmesg | grep -c -i 'lockup\|hung task' 2>/dev/null || echo 0")
    lockup_count=$(echo "$lockup_count" | tr -d '[:space:]')
    [[ ! "$lockup_count" =~ ^[0-9]+$ ]] && lockup_count=0
    content+="• Lockup Events: $lockup_count\n"
    if [[ $lockup_count -gt 0 ]]; then
        issues+="Lockup events detected; "
        status="WARNING"
    fi
    
    # RCU stalls
    content+="### RCU_STALL\n"
    local rcu_stall
    rcu_stall=$(exec_cmd "dmesg | grep -c 'RCU stall' 2>/dev/null || echo 0")
    rcu_stall=$(echo "$rcu_stall" | tr -d '[:space:]')
    [[ ! "$rcu_stall" =~ ^[0-9]+$ ]] && rcu_stall=0
    content+="• RCU Stall Events: $rcu_stall\n"
    if [[ $rcu_stall -gt 0 ]]; then
        issues+="RCU stalls detected; "
        status="WARNING"
    fi
    
    # I/O errors
    content+="### IO_ERRORS\n"
    local io_errors
    io_errors=$(exec_cmd "dmesg | grep -c -i 'i/o error' 2>/dev/null || echo 0")
    io_errors=$(echo "$io_errors" | tr -d '[:space:]')
    [[ ! "$io_errors" =~ ^[0-9]+$ ]] && io_errors=0
    content+="• I/O Errors: $io_errors\n"
    if [[ $io_errors -gt 0 ]]; then
        issues+="I/O errors detected; "
        status="CRITICAL"
    fi
    
    # USB/PCIe reset cycles
    content+="### RESET_CYCLES\n"
    local usb_resets
    usb_resets=$(exec_cmd "dmesg | grep -c 'reset' 2>/dev/null || echo 0")
    usb_resets=$(echo "$usb_resets" | tr -d '[:space:]')
    [[ ! "$usb_resets" =~ ^[0-9]+$ ]] && usb_resets=0
    content+="• Reset Events: $usb_resets\n"
    
    # Journalctl critical logs
    content+="### JOURNALCTL_CRITICAL\n"
    if command -v journalctl &>/dev/null; then
        local journal_crit
        journal_crit=$(exec_sudo_cmd "journalctl -p crit --no-pager 2>/dev/null | tail -10")
        if [[ -n "$journal_crit" ]]; then
            content+="$journal_crit\n"
        else
            content+="• No critical journal entries\n"
        fi
    fi
    
    write_section "LOGS_ANALYSIS" "$content" "$status" "$issues"
    log_success "Logs analysis completed"
}

#-------------------------------------------------------------------------------
# Storage Failure Analysis
#-------------------------------------------------------------------------------

scan_storage_failure() {
    log_section "Storage Failure Analysis"
    local content=""
    local status="OK"
    local issues=""
    
    # ATA error count
    content+="### ATA_ERRORS\n"
    if command -v smartctl &>/dev/null; then
        local drives
        drives=$(exec_cmd "lsblk -ndo NAME 2>/dev/null | grep -E '^sd'")
        for drive in $drives; do
            local ata_error
            ata_error=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i 'crc\|udma crc'")
            if [[ -n "$ata_error" ]]; then
                content+="/dev/$drive: $ata_error\n"
                issues+="ATA CRC errors on /dev/$drive; "
                status="WARNING"
            fi
        done
    fi
    
    # NVMe critical warnings
    content+="### NVME_CRITICAL\n"
    if command -v smartctl &>/dev/null; then
        local nvme_drives
        nvme_drives=$(exec_cmd "lsblk -ndo NAME 2>/dev/null | grep -E '^nvme'")
        for drive in $nvme_drives; do
            local nvme_warn warn_val
            nvme_warn=$(exec_sudo_cmd "smartctl -A /dev/$drive 2>/dev/null | grep -i 'critical warning'")
            if [[ -n "$nvme_warn" ]]; then
                content+="/dev/$drive: $nvme_warn\n"
                warn_val=$(echo "$nvme_warn" | awk '{print $NF}')
                if [[ "$warn_val" =~ ^[0-9]+$ ]] && [[ $warn_val -ne 0 ]]; then
                    issues+="NVMe critical warning on /dev/$drive; "
                    status="WARNING"
                fi
            fi
        done
    fi
    
    # Badblocks check (quick)
    content+="### BADBLOCKS\n"
    content+="• Note: Full badblocks scan skipped (destructive)\n"
    
    # FS corruption signs
    content+="### FS_CORRUPTION\n"
    local fs_errors
    fs_errors=$(exec_cmd "dmesg | grep -i 'corrupt\|ext4.*error\|xfs.*error' | tail -5")
    if [[ -n "$fs_errors" ]]; then
        content+="$fs_errors\n"
        issues+="Filesystem corruption signs; "
        status="CRITICAL"
    else
        content+="• No filesystem corruption signs\n"
    fi
    
    write_section "STORAGE_FAILURE" "$content" "$status" "$issues"
    log_success "Storage failure analysis completed"
}

#-------------------------------------------------------------------------------
# Thermal/Electrical Analysis
#-------------------------------------------------------------------------------

scan_thermal_elec() {
    log_section "Thermal & Electrical Analysis"
    local content=""
    local status="OK"
    local issues=""
    
    # Thermal trip points
    content+="### THERMAL_TRIPS\n"
    if [[ -d /sys/class/thermal ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            local zone_name trip_points
            zone_name=$(exec_cmd "cat $zone/type 2>/dev/null")
            trip_points=$(find "$zone" -name 'trip_point_*_temp' -exec echo -n "{}: " \; -exec cat {} \; 2>/dev/null)
            if [[ -n "$zone_name" ]]; then
                content+="• $zone_name:\n$trip_points\n"
            fi
        done
    fi
    
    # Voltage sensors
    content+="### VOLTAGE_SENSORS\n"
    if command -v sensors &>/dev/null; then
        local voltages
        voltages=$(exec_cmd "sensors 2>/dev/null | grep -E 'V|volt'")
        if [[ -n "$voltages" ]]; then
            content+="$voltages\n"
        fi
    fi
    
    # Previous boot thermal shutdowns
    content+="### PREVIOUS_THERMAL_SHUTDOWN\n"
    local thermal_shutdown
    thermal_shutdown=$(exec_cmd "journalctl -b -1 | grep -i 'thermal\|overheat' 2>/dev/null | tail -5")
    if [[ -n "$thermal_shutdown" ]]; then
        content+="$thermal_shutdown\n"
        issues+="Previous thermal shutdown detected; "
        status="WARNING"
    else
        content+="• No previous thermal shutdowns\n"
    fi
    
    write_section "THERMAL_ELEC" "$content" "$status" "$issues"
    log_success "Thermal/electrical analysis completed"
}

#-------------------------------------------------------------------------------
# Performance Profiling (Level 4 Only)
#-------------------------------------------------------------------------------

scan_profiling_stress() {
    log_section "Performance Profiling & Stress Tests"
    local content=""
    local status="SKIPPED"
    local issues=""
    
    if [[ $CURRENT_LEVEL -lt $SCAN_PROFILING_STRESS ]]; then
        content+="• SKIPPED: Requires scan level 4 (PROFILING_STRESS)\n"
        content+="• Use --force-profiling flag or select level 4 to enable\n"
        write_section "PROFILING_STRESS" "$content" "SKIPPED"
        return
    fi
    
    if [[ "$FORCE_PROFILING" != true ]]; then
        echo ""
        echo -e "${RED}⚠️  WARNING: Performance profiling and stress tests can impact system stability${NC}" >&2
        read -rp "Continue with stress tests? (NO/yes): " confirm
        if [[ $confirm != "yes" ]]; then
            content+="• SKIPPED: User declined stress tests\n"
            write_section "PROFILING_STRESS" "$content" "SKIPPED"
            return
        fi
    fi
    
    status="OK"
    
    # perf record (short sample)
    content+="### PERF_SAMPLE\n"
    if command -v perf &>/dev/null; then
        log_info "Running perf sample (10 seconds)..."
        local perf_output perf_report
        perf_output=$(exec_sudo_cmd "perf record -a -g sleep 10 2>&1")
        content+="$perf_output\n"
        
        perf_report=$(exec_sudo_cmd "perf report --stdio -n --sort comm,dso 2>/dev/null | head -20")
        content+="$perf_report\n"
    else
        content+="• [TOOL_MISSING: perf]\n"
    fi
    
    # Cache misses
    content+="### CACHE_MISSES\n"
    if command -v perf &>/dev/null; then
        local cache_stats
        cache_stats=$(exec_sudo_cmd "perf stat -a -e cache-references,cache-misses sleep 5 2>&1")
        content+="$cache_stats\n"
    fi
    
    # Branch misses
    content+="### BRANCH_MISSES\n"
    if command -v perf &>/dev/null; then
        local branch_stats
        branch_stats=$(exec_sudo_cmd "perf stat -a -e branches,branch-misses sleep 5 2>&1")
        content+="$branch_stats\n"
    fi
    
    # IPC (Instructions Per Cycle)
    content+="### IPC\n"
    if command -v perf &>/dev/null; then
        local ipc_stats
        ipc_stats=$(exec_sudo_cmd "perf stat -a -e instructions,cycles sleep 5 2>&1 | grep -E 'instructions|cycles'")
        content+="$ipc_stats\n"
    fi
    
    # Block I/O tracing (brief)
    content+="### BLOCK_IO_TRACE\n"
    if command -v bpftrace &>/dev/null; then
        local biostats
        biostats=$(exec_sudo_cmd "bpftrace -e 'tracepoint:block:block_rq_issue { @bytes = sum(args->bytes); } interval:s:5 { print(@bytes); exit(); }' 2>&1")
        content+="$biostats\n"
    else
        content+="• [TOOL_MISSING: bpftrace]\n"
    fi
    
    # Network tracing (brief)
    content+="### NET_TRACE\n"
    if command -v bpftrace &>/dev/null; then
        content+="• BPF network tracing available\n"
    fi
    
    # systemd-analyze blame
    content+="### BOOT_ANALYSIS\n"
    if command -v systemd-analyze &>/dev/null; then
        local boot_blame
        boot_blame=$(exec_cmd "systemd-analyze blame 2>/dev/null | head -10")
        content+="$boot_blame\n"
    fi
    
    # Stress test (CPU - very brief)
    content+="### STRESS_TEST_CPU\n"
    if command -v stress-ng &>/dev/null; then
        log_info "Running brief CPU stress test (5 seconds)..."
        local stress_result mce_during_stress
        stress_result=$(exec_cmd "stress-ng --cpu 2 --timeout 5s 2>&1")
        content+="$stress_result\n"
        
        mce_during_stress=$(exec_cmd "dmesg | tail -20 | grep -i 'mce\|error'")
        if [[ -n "$mce_during_stress" ]]; then
            content+="Errors during stress test:\n$mce_during_stress\n"
            issues+="Errors during stress test; "
            status="WARNING"
        fi
    else
        content+="• [TOOL_MISSING: stress-ng]\n"
    fi
    
    # Memory stress (very brief)
    content+="### STRESS_TEST_MEMORY\n"
    if command -v stress-ng &>/dev/null; then
        log_info "Running brief memory stress test (5 seconds)..."
        local mem_stress
        mem_stress=$(exec_cmd "stress-ng --vm 1 --vm-bytes 256M --timeout 5s 2>&1")
        content+="$mem_stress\n"
    fi
    
    # I/O stress (very brief)
    content+="### STRESS_TEST_IO\n"
    if command -v fio &>/dev/null; then
        log_info "Running brief I/O stress test (5 seconds)..."
        local io_stress
        io_stress=$(exec_cmd "fio --name=stress --ioengine=libaio --rw=randread --bs=4k --numjobs=2 --size=64M --runtime=5 --time_based 2>&1 | tail -20")
        content+="$io_stress\n"
    elif command -v stress-ng &>/dev/null; then
        local io_stress
        io_stress=$(exec_cmd "stress-ng --hdd 1 --timeout 5s 2>&1")
        content+="$io_stress\n"
    else
        content+="• [TOOL_MISSING: fio/stress-ng]\n"
    fi
    
    write_section "PROFILING_STRESS" "$content" "$status" "$issues"
    log_success "Profiling/stress scan completed"
}

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

show_banner() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║           DEEP SYSTEM SCAN v5.2 - System Diagnostics         ║
║              Production-Ready Read-Only Scanner              ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -l, --level LEVEL     Set scan level (1-4, default: 1)
                        1 = MINIMAL (basic hardware, logs, disk space)
                        2 = MEDIUM (services, packages, SMART, network)
                        3 = TOTAL (full diagnostics, security, validation)
                        4 = PROFILING_STRESS (heavy metrics, stress tests)
  -f, --force-profiling Force enable profiling/stress tests (level 4)
  -a, --auto-install    Auto-install missing tools without prompt
  -o, --output FILE     Specify output file path
  -h, --help            Show this help message

Examples:
  $SCRIPT_NAME                     # Run minimal scan (level 1)
  $SCRIPT_NAME -l 2                # Run medium scan (level 2)
  $SCRIPT_NAME -l 3 -a             # Run total scan with auto-install
  $SCRIPT_NAME -l 4 --force-profiling  # Run full profiling with stress tests

Note: Level 4 requires explicit confirmation due to stress tests.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--level)
                CURRENT_LEVEL="$2"
                if [[ ! $CURRENT_LEVEL =~ ^[1-4]$ ]]; then
                    echo "Error: Level must be 1-4" >&2
                    exit 1
                fi
                shift 2
                ;;
            -f|--force-profiling)
                FORCE_PROFILING=true
                shift
                ;;
            -a|--auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            -o|--output)
                REPORT_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
}

interactive_level_select() {
    echo ""
    echo "Select scan level:" >&2
    echo "  1) MINIMAL - Basic hardware, logs, disk space (~30 sec)" >&2
    echo "  2) MEDIUM - Services, packages, SMART, network (~2 min)" >&2
    echo "  3) TOTAL - Full diagnostics, security, validation (~5 min)" >&2
    echo "  4) PROFILING_STRESS - Heavy metrics, stress tests (~10 min)" >&2
    echo "" >&2
    
    if [[ -t 0 ]]; then
        read -rp "Enter level [1-4] (default: 1): " level_input
        if [[ $level_input =~ ^[1-4]$ ]]; then
            CURRENT_LEVEL=$level_input
        fi
    fi
}

main() {
    show_banner
    parse_args "$@"
    
    # Interactive level selection only if running in interactive terminal without pre-set level
    if [[ $CURRENT_LEVEL -eq $SCAN_MINIMAL ]] && [[ -t 0 ]] && [[ -z "${INTERACTIVE_DISABLED:-}" ]]; then
        interactive_level_select
    fi
    
    echo "" >&2
    log_info "Starting Deep System Scan v${VERSION}" >&2
    log_info "Scan Level: ${CURRENT_LEVEL}" >&2
    log_info "Report File: ${REPORT_FILE}" >&2
    echo "" >&2
    
    # Setup trap for cleanup
    trap 'log_info "Scan interrupted"; exit 130' INT TERM
    
    # Initialize report
    write_report_header
    
    # Check and install tools
    check_and_install_tools
    
    # Run scans based on level
    log_section "Starting Diagnostic Scans"
    
    # Level 1: MINIMAL
    scan_cpu
    scan_ram
    scan_storage
    scan_system_metrics
    
    if [[ $CURRENT_LEVEL -ge $SCAN_MEDIUM ]]; then
        # Level 2: MEDIUM
        scan_gpu
        scan_battery
        scan_cooling
        scan_network
        scan_audio
        scan_motherboard
        scan_kernel
        scan_filesystem
        scan_power_mgmt
        scan_userspace
    fi
    
    if [[ $CURRENT_LEVEL -ge $SCAN_TOTAL ]]; then
        # Level 3: TOTAL
        scan_security
        scan_observability
        scan_mce_errors
        scan_logs
        scan_storage_failure
        scan_thermal_elec
    fi
    
    if [[ $CURRENT_LEVEL -ge $SCAN_PROFILING_STRESS ]]; then
        # Level 4: PROFILING_STRESS
        scan_profiling_stress
    fi
    
    # Generate AI summary
    generate_ai_summary
    
    # Final output
    echo "" >&2
    log_success "Scan completed successfully!" >&2
    log_info "Report saved to: ${REPORT_FILE}" >&2
    echo "" >&2
    
    # Summary
    echo "=== SCAN SUMMARY ===" >&2
    echo "Critical Issues: ${#CRITICAL_ISSUES[@]}" >&2
    echo "Warnings: ${#WARNING_ISSUES[@]}" >&2
    echo "Info: ${#INFO_ISSUES[@]}" >&2
    echo "" >&2
    
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}CRITICAL ISSUES:${NC}" >&2
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "  • $issue" >&2
        done
        echo "" >&2
    fi
    
    if [[ ${#WARNING_ISSUES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}WARNINGS:${NC}" >&2
        for issue in "${WARNING_ISSUES[@]}"; do
            echo "  • $issue" >&2
        done
        echo "" >&2
    fi
    
    echo "Review the full report at: ${REPORT_FILE}" >&2
    echo "" >&2
}

# Run main function
main "$@"
