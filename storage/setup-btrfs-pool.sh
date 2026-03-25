#!/usr/bin/env bash
# Manage Btrfs-backed Incus storage pools and block device passthrough to VMs.
#
# When IWT_STORAGE_BACKEND=btrfs (the default), new Incus storage pools are
# created on Btrfs so that VM snapshots map to native Btrfs subvolume snapshots
# (instant, copy-on-write) rather than QCOW2 internal snapshots.
#
# The attach-btrfs subcommand passes a Btrfs subvolume through to a Windows VM
# as a raw block device. With WinBtrfs installed in the guest, Windows can then
# mount and read/write that volume natively.
#
# Usage:
#   setup-btrfs-pool.sh <subcommand> [options]
#
# Subcommands:
#   create-pool         Create a Btrfs-backed Incus storage pool
#   attach-btrfs        Pass a Btrfs block device/subvolume through to a VM
#   detach-btrfs        Remove a Btrfs block device from a VM
#   list-pools          List Incus storage pools and their Btrfs status
#   check               Check host Btrfs support
#   help                Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# Default pool name; overridden by IWT_STORAGE_POOL in config
IWT_STORAGE_POOL="${IWT_STORAGE_POOL:-iwt-btrfs}"

# --- Subcommands ---

cmd_create_pool() {
    local pool_name="$IWT_STORAGE_POOL"
    local pool_path=""
    local pool_size=""
    local loop_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)   pool_name="$2"; shift 2 ;;
            --path)   pool_path="$2"; shift 2 ;;
            --size)   pool_size="$2"; shift 2 ;;
            --loop)   loop_file="$2"; shift 2 ;;
            --help|-h) _usage_create_pool; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    echo ""
    bold "Create Btrfs Storage Pool"
    info "Pool name: $pool_name"

    # Check if pool already exists
    if incus storage show "$pool_name" &>/dev/null; then
        local driver
        driver=$(incus storage show "$pool_name" | grep '^driver:' | awk '{print $2}')
        if [[ "$driver" == "btrfs" ]]; then
            ok "Pool '$pool_name' already exists (driver: btrfs)"
            return 0
        else
            warn "Pool '$pool_name' exists but uses driver '$driver', not btrfs"
            info "To use a different pool name: --name <name>"
            return 1
        fi
    fi

    # Determine creation method
    if [[ -n "$pool_path" ]]; then
        # Use an existing Btrfs filesystem at the given path
        _check_btrfs_path "$pool_path"
        info "Creating pool on existing Btrfs filesystem: $pool_path"
        incus storage create "$pool_name" btrfs source="$pool_path"

    elif [[ -n "$loop_file" ]]; then
        # Create a loop-device-backed Btrfs pool (useful for testing / non-Btrfs hosts)
        [[ -n "$pool_size" ]] || pool_size="20G"
        info "Creating loop-backed Btrfs pool: $loop_file (${pool_size})"
        local loop_dir
        loop_dir=$(dirname "$loop_file")
        mkdir -p "$loop_dir"
        truncate -s "$pool_size" "$loop_file"
        mkfs.btrfs -f "$loop_file" &>/dev/null
        incus storage create "$pool_name" btrfs source="$loop_file"

    else
        # Let Incus manage the pool storage (creates a loop file in /var/lib/incus)
        local create_args=("$pool_name" btrfs)
        [[ -n "$pool_size" ]] && create_args+=(size="$pool_size")
        info "Creating Incus-managed Btrfs pool (size: ${pool_size:-auto})"
        incus storage create "${create_args[@]}"
    fi

    ok "Storage pool '$pool_name' created (driver: btrfs)"
    info "Set as default for new VMs with: iwt config set IWT_STORAGE_POOL=$pool_name"
}

_usage_create_pool() {
    cat <<EOF
iwt vm storage create-pool - Create a Btrfs-backed Incus storage pool

Options:
  --name NAME     Pool name (default: $IWT_STORAGE_POOL)
  --path PATH     Use an existing Btrfs filesystem at PATH
  --loop FILE     Create a loop-file-backed pool at FILE
  --size SIZE     Pool size, e.g. 50G (for loop or managed pools)

Examples:
  iwt vm storage create-pool
  iwt vm storage create-pool --name my-pool --size 100G
  iwt vm storage create-pool --path /mnt/btrfs-data
  iwt vm storage create-pool --loop /var/lib/iwt/btrfs.img --size 50G
EOF
}

_check_btrfs_path() {
    local path="$1"
    [[ -d "$path" ]] || die "Path does not exist: $path"

    local fstype
    fstype=$(stat -f -c '%T' "$path" 2>/dev/null || findmnt -n -o FSTYPE "$path" 2>/dev/null || echo "unknown")

    if [[ "$fstype" != "btrfs" ]]; then
        warn "Path '$path' is on filesystem '$fstype', not btrfs"
        warn "Incus will still create the pool, but Btrfs-native snapshots won't work"
    fi
}

cmd_attach_btrfs() {
    local vm_name="${IWT_VM_NAME:-}"
    local device_path=""
    local device_name="btrfs-data"
    local readonly=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)       vm_name="$2"; shift 2 ;;
            --device)   device_path="$2"; shift 2 ;;
            --name)     device_name="$2"; shift 2 ;;
            --readonly) readonly=true; shift ;;
            --help|-h)  _usage_attach; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$vm_name" ]]     || die "--vm is required"
    [[ -n "$device_path" ]] || die "--device is required (path to block device or image file)"

    echo ""
    bold "Attach Btrfs Device to VM"
    info "VM:     $vm_name"
    info "Device: $device_path"
    info "Name:   $device_name"

    # Resolve to absolute path
    device_path=$(realpath "$device_path")

    [[ -e "$device_path" ]] || die "Device/file not found: $device_path"

    # Determine device type
    local dev_type="disk"
    if [[ -f "$device_path" ]]; then
        info "Source is a file (will be attached as a raw disk image)"
    elif [[ -b "$device_path" ]]; then
        info "Source is a block device"
    else
        die "Not a file or block device: $device_path"
    fi

    # Check VM exists
    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    # Check for name collision
    if incus config device show "$vm_name" 2>/dev/null | grep -q "^${device_name}:"; then
        die "Device '$device_name' already attached to '$vm_name'. Use --name to choose a different name."
    fi

    local add_args=("$vm_name" "$device_name" "$dev_type" "source=${device_path}")
    [[ "$readonly" == true ]] && add_args+=("readonly=true")

    incus config device add "${add_args[@]}"

    ok "Btrfs device '$device_name' attached to '$vm_name'"
    info ""
    info "Inside the Windows guest, the device will appear as a new disk."
    info "With WinBtrfs installed, Windows will mount it automatically."
    info ""
    info "To install WinBtrfs if not already present:"
    info "  iwt vm setup-guest --vm $vm_name --install-winbtrfs"
}

_usage_attach() {
    cat <<EOF
iwt vm storage attach-btrfs - Pass a Btrfs block device through to a VM

Options:
  --vm NAME         Target VM name (required)
  --device PATH     Path to block device or raw image file (required)
  --name NAME       Device name inside Incus (default: btrfs-data)
  --readonly        Attach read-only

Examples:
  iwt vm storage attach-btrfs --vm win11 --device /dev/sdb
  iwt vm storage attach-btrfs --vm win11 --device /data/btrfs.img --name shared
  iwt vm storage attach-btrfs --vm win11 --device /dev/sdb --readonly
EOF
}

cmd_detach_btrfs() {
    local vm_name="${IWT_VM_NAME:-}"
    local device_name="btrfs-data"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)    vm_name="$2"; shift 2 ;;
            --name)  device_name="$2"; shift 2 ;;
            --help|-h) echo "Usage: iwt vm storage detach-btrfs --vm NAME [--name DEVICE]"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$vm_name" ]] || die "--vm is required"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    incus config device remove "$vm_name" "$device_name" || die "Failed to remove device '$device_name'"
    ok "Device '$device_name' detached from '$vm_name'"
}

cmd_list_pools() {
    echo ""
    bold "Incus Storage Pools:"
    echo ""

    # Header
    printf "  %-20s %-10s %-10s %s\n" "NAME" "DRIVER" "STATUS" "SOURCE"
    printf "  %-20s %-10s %-10s %s\n" "----" "------" "------" "------"

    while IFS= read -r pool_name; do
        [[ -n "$pool_name" ]] || continue
        local driver state source
        driver=$(incus storage show "$pool_name" 2>/dev/null | grep '^driver:' | awk '{print $2}' || echo "?")
        state=$(incus storage info "$pool_name" 2>/dev/null | grep -i 'state:' | awk '{print $2}' || echo "?")
        source=$(incus storage show "$pool_name" 2>/dev/null | grep 'source:' | awk '{print $2}' || echo "")

        local btrfs_marker=""
        if [[ "$driver" == "btrfs" ]]; then
            btrfs_marker=" [btrfs]"
        fi

        printf "  %-20s %-10s %-10s %s%s\n" "$pool_name" "$driver" "$state" "$source" "$btrfs_marker"
    done < <(incus storage list --format csv | cut -d',' -f1)

    echo ""
    info "Default IWT pool: ${IWT_STORAGE_POOL}"
}

cmd_check() {
    echo ""
    bold "Host Btrfs Support Check"
    echo ""

    local ok_count=0 fail_count=0

    _chk() {
        local label="$1" result="$2"
        if [[ "$result" == "ok" ]]; then
            ok "  $label"
            ok_count=$((ok_count + 1))
        else
            err "  $label: $result"
            fail_count=$((fail_count + 1))
        fi
    }

    # Kernel module
    if modinfo btrfs &>/dev/null || lsmod | grep -q '^btrfs'; then
        _chk "Btrfs kernel module" "ok"
    else
        _chk "Btrfs kernel module" "not loaded (run: modprobe btrfs)"
    fi

    # btrfs-progs
    if command -v btrfs &>/dev/null; then
        local ver
        ver=$(btrfs --version 2>/dev/null | head -1 || echo "unknown")
        _chk "btrfs-progs ($ver)" "ok"
    else
        _chk "btrfs-progs" "not found (install: btrfs-progs / btrfs-tools)"
    fi

    # mkfs.btrfs
    if command -v mkfs.btrfs &>/dev/null; then
        _chk "mkfs.btrfs" "ok"
    else
        _chk "mkfs.btrfs" "not found (install: btrfs-progs)"
    fi

    # Incus btrfs driver
    if incus storage list --format csv 2>/dev/null | grep -q ',btrfs,'; then
        _chk "Incus btrfs pool exists" "ok"
    else
        info "  No Incus btrfs pool found (create with: iwt vm storage create-pool)"
    fi

    # Check if any mounted filesystem is btrfs
    if findmnt -t btrfs &>/dev/null; then
        local btrfs_mounts
        btrfs_mounts=$(findmnt -t btrfs -o TARGET --noheadings | tr '\n' ' ')
        _chk "Btrfs filesystem mounted ($btrfs_mounts)" "ok"
    else
        info "  No Btrfs filesystem currently mounted"
    fi

    echo ""
    info "Results: $ok_count ok, $fail_count issues"
    [[ $fail_count -eq 0 ]]
}

usage() {
    cat <<EOF
iwt vm storage - Manage Btrfs storage pools and block device passthrough

Subcommands:
  create-pool     Create a Btrfs-backed Incus storage pool
  attach-btrfs    Pass a Btrfs block device/image through to a VM
  detach-btrfs    Remove a Btrfs block device from a VM
  list-pools      List Incus storage pools
  check           Check host Btrfs support

Run 'iwt vm storage <subcommand> --help' for details.

Examples:
  iwt vm storage create-pool
  iwt vm storage create-pool --path /mnt/btrfs
  iwt vm storage attach-btrfs --vm win11 --device /dev/sdb
  iwt vm storage attach-btrfs --vm win11 --device /data/shared.img --name data
  iwt vm storage detach-btrfs --vm win11 --name data
  iwt vm storage list-pools
  iwt vm storage check
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        create-pool)    cmd_create_pool "$@" ;;
        attach-btrfs)   cmd_attach_btrfs "$@" ;;
        detach-btrfs)   cmd_detach_btrfs "$@" ;;
        list-pools)     cmd_list_pools ;;
        check)          cmd_check ;;
        help|--help|-h) usage ;;
        *)
            err "Unknown storage subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
