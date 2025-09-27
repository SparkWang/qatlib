#!/usr/bin/env bash

# Intel QAT troubleshooting script
# Collects environment details relevant for performance analysis.

set -o pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"

print_section() {
    local title="$1"
    echo
    echo "========================================"
    echo "$title"
    echo "========================================"
}

run_cmd() {
    local description="$1"
    shift || true
    local command="$*"

    print_section "$description"
    if [[ -z "$command" ]]; then
        echo "No command provided"
        return
    fi

    echo "\$ $command"
    if ! bash -lc "$command"; then
        local rc=$?
        echo "Command failed with exit code $rc"
    fi
}

print_intro() {
    cat <<INTRO
Intel QAT Troubleshooting Report
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Script version: $SCRIPT_VERSION
Hostname: $(hostname)
INTRO
}

collect_os_info() {
    print_section "Operating system information"
    echo "\n$ uname -a"
    uname -a || echo "Unable to collect kernel info"

    if [[ -f /etc/os-release ]]; then
        echo "\n$ cat /etc/os-release"
        cat /etc/os-release
    else
        echo "/etc/os-release not found"
    fi

    if command -v lsb_release >/dev/null 2>&1; then
        echo "\n$ lsb_release -a"
        lsb_release -a
    fi
}

collect_cpu_info() {
    print_section "CPU and topology"
    if command -v lscpu >/dev/null 2>&1; then
        echo "\n$ lscpu"
        lscpu
    else
        echo "lscpu is not available"
    fi

    if command -v numactl >/dev/null 2>&1; then
        echo "\n$ numactl --hardware"
        numactl --hardware
    else
        echo "numactl is not available"
    fi
}

collect_memory_info() {
    print_section "Memory configuration"
    echo "\n$ free -h"
    free -h || echo "free command failed"

    if command -v dmidecode >/dev/null 2>&1; then
        echo "\n$ dmidecode -t memory | egrep 'Locator|Size|Speed|Configured Clock Speed|Data Width'"
        sudo dmidecode -t memory 2>/dev/null | egrep 'Locator|Size|Speed|Configured Clock Speed|Data Width' || \
            dmidecode -t memory 2>/dev/null | egrep 'Locator|Size|Speed|Configured Clock Speed|Data Width'
    else
        echo "dmidecode is not available (required for channel configuration)"
    fi
}

collect_qat_devices() {
    print_section "Detected QAT PCI devices"
    if ! command -v lspci >/dev/null 2>&1; then
        echo "lspci is not available"
        return
    fi

    local devices
    devices=$(lspci -Dn | grep -i 'QuickAssist' | awk '{print $1" "substr($0, index($0,$3))}')

    if [[ -z "$devices" ]]; then
        echo "No QAT devices detected via lspci"
        return
    fi

    echo "$devices"

    while read -r line; do
        [[ -z "$line" ]] && continue
        local bdf description
        bdf=$(awk '{print $1}' <<<"$line")
        description=$(cut -d' ' -f2- <<<"$line")
        echo
        echo "--- $bdf : $description ---"

        local sysfs_path="/sys/bus/pci/devices/$bdf"
        if [[ -d "$sysfs_path" ]]; then
            [[ -f "$sysfs_path/numa_node" ]] && echo "NUMA node: $(cat "$sysfs_path/numa_node")"
            [[ -f "$sysfs_path/current_link_speed" ]] && echo "Current link speed: $(cat "$sysfs_path/current_link_speed")"
            [[ -f "$sysfs_path/current_link_width" ]] && echo "Current link width: $(cat "$sysfs_path/current_link_width")"
            [[ -f "$sysfs_path/max_link_speed" ]] && echo "Max link speed: $(cat "$sysfs_path/max_link_speed")"
            [[ -f "$sysfs_path/max_link_width" ]] && echo "Max link width: $(cat "$sysfs_path/max_link_width")"
            if [[ -L "$sysfs_path/driver" ]]; then
                echo "Driver: $(basename "$(readlink "$sysfs_path/driver")")"
            fi
            if [[ -f "$sysfs_path/sriov_totalvfs" ]]; then
                echo "SR-IOV total VFs: $(cat "$sysfs_path/sriov_totalvfs")"
                [[ -f "$sysfs_path/sriov_numvfs" ]] && echo "SR-IOV enabled VFs: $(cat "$sysfs_path/sriov_numvfs")"
            fi
        else
            echo "Sysfs path $sysfs_path not found"
        fi

        echo
        echo "lspci -vv -s $bdf"
        lspci -vv -s "$bdf"
    done <<<"$devices"
}

collect_driver_info() {
    print_section "QAT driver modules"
    if ! command -v lsmod >/dev/null 2>&1; then
        echo "lsmod is not available"
        return
    fi

    lsmod | grep -E '^qat|usdm' || echo "No QAT-related kernel modules currently loaded"

    local modules
    modules=$(lsmod | awk '/^qat_/ {print $1}' | sort -u)
    if [[ -n "$modules" ]]; then
        while read -r module; do
            [[ -z "$module" ]] && continue
            echo
            echo "modinfo $module"
            if command -v modinfo >/dev/null 2>&1; then
                modinfo "$module" | egrep 'filename:|version:|vermagic:|description:'
            else
                echo "modinfo not available"
                break
            fi
        done <<<"$modules"
    fi

    if command -v modinfo >/dev/null 2>&1 && lsmod | grep -q '^usdm_drv'; then
        echo
        echo "modinfo usdm_drv"
        modinfo usdm_drv | egrep 'filename:|version:|vermagic:|description:'
    fi
}

collect_firmware_info() {
    print_section "QAT firmware status"
    if command -v adf_ctl >/dev/null 2>&1; then
        echo "\n$ adf_ctl status"
        adf_ctl status
        echo
        echo "Firmware versions detected:"
        adf_ctl status 2>/dev/null | grep -i 'Firmware version' | sort -u || echo "Unable to parse firmware version"
    else
        echo "adf_ctl is not available"
    fi

    if command -v qat_service >/dev/null 2>&1; then
        echo "\n$ qat_service status"
        qat_service status
    elif command -v systemctl >/dev/null 2>&1; then
        if [[ -d /run/systemd/system ]]; then
            echo "\n$ systemctl --no-pager status qat_service"
            systemctl --no-pager status qat_service
        else
            echo "systemctl is present but systemd is not the active init system"
        fi
    else
        echo "qat_service utility is not available"
    fi
}

collect_library_info() {
    print_section "QAT library versions"

    if command -v pkg-config >/dev/null 2>&1; then
        echo "\n$ pkg-config --modversion qat"
        pkg-config --modversion qat 2>&1 || true

        echo "\n$ pkg-config --modversion usdm"
        pkg-config --modversion usdm 2>&1 || true
    else
        echo "pkg-config not available"
    fi

    if command -v ldconfig >/dev/null 2>&1; then
        echo "\n$ ldconfig -p | grep -i qat"
        ldconfig -p | grep -i qat || echo "No QAT libraries registered in ldconfig"
    fi

    if command -v rpm >/dev/null 2>&1; then
        echo "\n$ rpm -qa | grep -i qat"
        rpm -qa | grep -i qat || echo "No QAT RPM packages installed"
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        echo "\n$ dpkg-query -W | grep -i qat"
        dpkg-query -W | grep -i qat || echo "No QAT Debian packages installed"
    fi
}

collect_device_nodes() {
    print_section "Character devices"
    if compgen -G '/dev/qat*' >/dev/null 2>&1; then
        ls -l /dev/qat*
    else
        echo "No /dev/qat* device nodes found"
    fi
}

collect_logs() {
    print_section "Kernel and service logs"

    if command -v dmesg >/dev/null 2>&1; then
        echo "\n$ dmesg | grep -i qat | tail -n 100"
        dmesg | grep -i qat | tail -n 100 || echo "No QAT messages in dmesg"
    fi

    if command -v journalctl >/dev/null 2>&1; then
        if [[ -d /run/systemd/system ]]; then
            echo "\n$ journalctl -u qat_service --no-pager -n 200"
            journalctl -u qat_service --no-pager -n 200 2>&1 || echo "Unable to read journalctl for qat_service"
        else
            echo "journalctl is present but systemd is not the active init system"
        fi
    fi
}

collect_perf_settings() {
    print_section "Performance-related settings"

    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "Transparent hugepages: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    fi

    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
        echo "Transparent hugepage defrag: $(cat /sys/kernel/mm/transparent_hugepage/defrag)"
    fi

    if [[ -f /proc/sys/kernel/nmi_watchdog ]]; then
        echo "NMI watchdog: $(cat /proc/sys/kernel/nmi_watchdog)"
    fi

    if command -v tuned-adm >/dev/null 2>&1; then
        echo "\n$ tuned-adm active"
        tuned-adm active
    fi

    if command -v cpupower >/dev/null 2>&1; then
        echo "\n$ cpupower frequency-info"
        cpupower frequency-info
    fi
}

main() {
    print_intro
    collect_os_info
    collect_cpu_info
    collect_memory_info
    collect_qat_devices
    collect_driver_info
    collect_firmware_info
    collect_library_info
    collect_device_nodes
    collect_logs
    collect_perf_settings
}

main "$@"
