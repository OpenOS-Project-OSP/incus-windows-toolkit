#!/usr/bin/env bash
# DwarFS integration for IWT: image packing/unpacking and shared folder mounts.
#
# DwarFS (mhx/dwarfs) is a highly compressed read-only filesystem. IWT uses it
# in two ways:
#
#   1. Image archiving: pack a built Windows image directory into a .dwarfs
#      archive for distribution/caching, and unpack it on demand.
#      Triggered by IWT_IMAGE_FORMAT=dwarfs (the default) or --format dwarfs.
#
#   2. Shared folders: mount a .dwarfs archive on the Linux host via FUSE and
#      expose it to a Windows VM as a virtiofs share. Useful for large read-only
#      datasets (game libraries, software repos) that benefit from transparent
#      decompression.
#
# Usage:
#   setup-dwarfs.sh <subcommand> [options]
#
# Subcommands:
#   pack            Pack a directory or QCOW2 image into a .dwarfs archive
#   unpack          Extract a .dwarfs archive to a directory
#   mount-share     Mount a .dwarfs archive and expose it to a VM via virtiofs
#   umount-share    Unmount a DwarFS virtiofs share
#   list-shares     List active DwarFS mounts
#   check           Check host DwarFS support
#   help            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# Runtime mount state directory
IWT_DWARFS_RUNTIME="${IWT_DWARFS_RUNTIME:-/run/iwt/dwarfs}"

# --- Subcommands ---

cmd_pack() {
    local source=""
    local output=""
    local compress_level="${IWT_DWARFS_COMPRESS_LEVEL:-7}"
    local workers
    workers=$(nproc 2>/dev/null || echo 4)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source|-s)  source="$2"; shift 2 ;;
            --output|-o)  output="$2"; shift 2 ;;
            --level|-l)   compress_level="$2"; shift 2 ;;
            --workers|-j) workers="$2"; shift 2 ;;
            --help|-h)    _usage_pack; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$source" ]] || die "--source is required"
    _require_dwarfs

    # Derive output name from source if not given
    if [[ -z "$output" ]]; then
        output="${source%.qcow2}.dwarfs"
        output="${output%/}.dwarfs"
    fi

    echo ""
    bold "DwarFS Pack"
    info "Source:     $source"
    info "Output:     $output"
    info "Level:      $compress_level"
    info "Workers:    $workers"
    echo ""

    local pack_source="$source"
    local tmp_mount=""

    # If source is a QCOW2, mount it via NBD first
    if [[ "$source" == *.qcow2 ]]; then
        [[ -f "$source" ]] || die "QCOW2 not found: $source"
        tmp_mount=$(mktemp -d)
        info "Mounting QCOW2 via NBD..."
        _mount_qcow2 "$source" "$tmp_mount"
        pack_source="$tmp_mount"
    elif [[ -d "$source" ]]; then
        : # directory — pack directly
    else
        die "Source must be a directory or .qcow2 file: $source"
    fi

    info "Packing with mkdwarfs..."
    mkdwarfs \
        -i "$pack_source" \
        -o "$output" \
        --compress-level="$compress_level" \
        --num-workers="$workers" \
        --progress=simple \
        2>&1 | while IFS= read -r line; do info "  $line"; done

    local exit_code=${PIPESTATUS[0]}

    if [[ -n "$tmp_mount" ]]; then
        _umount_qcow2 "$tmp_mount"
        rm -rf "$tmp_mount"
    fi

    [[ $exit_code -eq 0 ]] || die "mkdwarfs failed (exit $exit_code)"

    local size
    size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
    ok "Packed: $output ($(human_size "$size"))"
}

_usage_pack() {
    cat <<EOF
iwt image pack - Pack a directory or QCOW2 image into a .dwarfs archive

Options:
  --source PATH   Source directory or .qcow2 file (required)
  --output PATH   Output .dwarfs file (default: <source>.dwarfs)
  --level N       Compression level 1-9 (default: 7)
  --workers N     Parallel workers (default: nproc)

Examples:
  iwt image pack --source windows-x86_64.qcow2
  iwt image pack --source /mnt/game-library --output games.dwarfs --level 9
EOF
}

cmd_unpack() {
    local source=""
    local output=""
    local workers
    workers=$(nproc 2>/dev/null || echo 4)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source|-s)  source="$2"; shift 2 ;;
            --output|-o)  output="$2"; shift 2 ;;
            --workers|-j) workers="$2"; shift 2 ;;
            --help|-h)    _usage_unpack; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$source" ]] || die "--source is required"
    [[ -f "$source" ]] || die "Archive not found: $source"
    _require_dwarfs

    if [[ -z "$output" ]]; then
        output="${source%.dwarfs}"
        [[ "$output" == "$source" ]] && output="${source}-extracted"
    fi

    echo ""
    bold "DwarFS Unpack"
    info "Source:  $source"
    info "Output:  $output"
    echo ""

    mkdir -p "$output"

    info "Extracting with dwarfsextract..."
    dwarfsextract \
        -i "$source" \
        -o "$output" \
        --num-workers="$workers" \
        2>&1 | while IFS= read -r line; do info "  $line"; done

    local exit_code=${PIPESTATUS[0]}
    [[ $exit_code -eq 0 ]] || die "dwarfsextract failed (exit $exit_code)"

    ok "Extracted to: $output"
}

_usage_unpack() {
    cat <<EOF
iwt image unpack - Extract a .dwarfs archive to a directory

Options:
  --source PATH   Source .dwarfs archive (required)
  --output PATH   Output directory (default: <source> without .dwarfs suffix)
  --workers N     Parallel workers (default: nproc)

Examples:
  iwt image unpack --source windows-x86_64.dwarfs
  iwt image unpack --source games.dwarfs --output /mnt/games
EOF
}

cmd_mount_share() {
    local archive=""
    local share_name=""
    local vm_name="${IWT_VM_NAME:-}"
    local mount_point=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive|-a)  archive="$2"; shift 2 ;;
            --name|-n)     share_name="$2"; shift 2 ;;
            --vm)          vm_name="$2"; shift 2 ;;
            --mountpoint)  mount_point="$2"; shift 2 ;;
            --help|-h)     _usage_mount; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$archive" ]]    || die "--archive is required"
    [[ -f "$archive" ]]    || die "Archive not found: $archive"
    [[ -n "$share_name" ]] || share_name=$(basename "${archive%.dwarfs}")
    [[ -n "$vm_name" ]]    || die "--vm is required"

    _require_dwarfs
    _require_fuse

    echo ""
    bold "DwarFS Mount Share"
    info "Archive:    $archive"
    info "Share name: $share_name"
    info "VM:         $vm_name"
    echo ""

    # Create FUSE mount point
    if [[ -z "$mount_point" ]]; then
        mount_point="${IWT_DWARFS_RUNTIME}/${share_name}"
    fi
    mkdir -p "$mount_point"

    # Mount the .dwarfs archive via FUSE
    if mountpoint -q "$mount_point" 2>/dev/null; then
        warn "Already mounted at $mount_point"
    else
        info "Mounting $archive at $mount_point..."
        dwarfs "$archive" "$mount_point" -o ro,allow_other 2>/dev/null || \
        dwarfs "$archive" "$mount_point" -o ro \
            || die "dwarfs FUSE mount failed"
        ok "Mounted at $mount_point"
    fi

    # Attach to VM as a virtiofs share
    info "Attaching to VM '$vm_name' as virtiofs share '$share_name'..."

    # Check if device already exists
    if incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
        warn "Share '$share_name' already attached to '$vm_name'"
    else
        incus config device add "$vm_name" "$share_name" disk \
            source="$mount_point" \
            path="/mnt/${share_name}" \
            || die "Failed to attach virtiofs share to VM"
        ok "Share '$share_name' attached to '$vm_name'"
    fi

    # Persist mount state so umount-share can clean up
    mkdir -p "$IWT_DWARFS_RUNTIME"
    echo "${archive}|${mount_point}|${vm_name}|${share_name}" \
        >> "${IWT_DWARFS_RUNTIME}/mounts.state"

    echo ""
    ok "DwarFS share ready"
    info "Inside the Windows guest, the share appears at: \\\\wsl.localhost\\${share_name}"
    info "Or mount it with: iwt-mount-shares.ps1 ${share_name} Z"
}

_usage_mount() {
    cat <<EOF
iwt vm storage mount-share - Mount a .dwarfs archive and expose it to a VM

Options:
  --archive PATH   Path to .dwarfs archive (required)
  --vm NAME        Target VM name (required)
  --name NAME      Share name (default: archive basename without .dwarfs)
  --mountpoint DIR Host FUSE mount point (default: /run/iwt/dwarfs/<name>)

Examples:
  iwt vm storage mount-share --archive games.dwarfs --vm win11
  iwt vm storage mount-share --archive /data/tools.dwarfs --vm win11 --name tools
EOF
}

cmd_umount_share() {
    local share_name=""
    local vm_name="${IWT_VM_NAME:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n) share_name="$2"; shift 2 ;;
            --vm)      vm_name="$2"; shift 2 ;;
            --help|-h) echo "Usage: iwt vm storage umount-share --name NAME --vm VM"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$share_name" ]] || die "--name is required"
    [[ -n "$vm_name" ]]    || die "--vm is required"

    echo ""
    bold "DwarFS Umount Share"
    info "Share: $share_name  VM: $vm_name"
    echo ""

    # Detach from VM
    if incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
        incus config device remove "$vm_name" "$share_name"
        ok "Detached '$share_name' from '$vm_name'"
    else
        warn "Share '$share_name' not found on '$vm_name'"
    fi

    # Unmount FUSE
    local mount_point="${IWT_DWARFS_RUNTIME}/${share_name}"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || umount "$mount_point" 2>/dev/null || true
        ok "Unmounted $mount_point"
    fi

    # Remove from state file
    local state_file="${IWT_DWARFS_RUNTIME}/mounts.state"
    if [[ -f "$state_file" ]]; then
        grep -v "|${vm_name}|${share_name}$" "$state_file" > "${state_file}.tmp" || true
        mv "${state_file}.tmp" "$state_file"
    fi

    ok "Share '$share_name' removed"
}

cmd_list_shares() {
    echo ""
    bold "Active DwarFS Shares:"
    echo ""

    local state_file="${IWT_DWARFS_RUNTIME}/mounts.state"
    if [[ ! -f "$state_file" ]]; then
        info "No active DwarFS shares"
        return 0
    fi

    printf "  %-20s %-15s %-30s %s\n" "SHARE" "VM" "MOUNT POINT" "ARCHIVE"
    printf "  %-20s %-15s %-30s %s\n" "-----" "--" "-----------" "-------"

    while IFS='|' read -r archive mount_point vm_name share_name; do
        [[ -n "$share_name" ]] || continue
        local mounted="no"
        mountpoint -q "$mount_point" 2>/dev/null && mounted="yes"
        printf "  %-20s %-15s %-30s %s (mounted: %s)\n" \
            "$share_name" "$vm_name" "$mount_point" "$(basename "$archive")" "$mounted"
    done < "$state_file"
}

cmd_check() {
    echo ""
    bold "Host DwarFS Support Check"
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

    if command -v mkdwarfs &>/dev/null; then
        local ver
        ver=$(mkdwarfs --version 2>&1 | head -1 || echo "unknown")
        _chk "mkdwarfs ($ver)" "ok"
    else
        _chk "mkdwarfs" "not found (install dwarfs-tools or build from https://github.com/mhx/dwarfs)"
    fi

    if command -v dwarfs &>/dev/null; then
        _chk "dwarfs (FUSE)" "ok"
    else
        _chk "dwarfs" "not found"
    fi

    if command -v dwarfsextract &>/dev/null; then
        _chk "dwarfsextract" "ok"
    else
        _chk "dwarfsextract" "not found"
    fi

    if command -v dwarfsck &>/dev/null; then
        _chk "dwarfsck" "ok"
    else
        _chk "dwarfsck" "not found (optional)"
    fi

    # FUSE support
    if [[ -e /dev/fuse ]]; then
        _chk "FUSE (/dev/fuse)" "ok"
    else
        _chk "FUSE" "not available (/dev/fuse missing)"
    fi

    if command -v fusermount &>/dev/null || command -v fusermount3 &>/dev/null; then
        _chk "fusermount" "ok"
    else
        _chk "fusermount" "not found (install fuse or fuse3)"
    fi

    echo ""
    info "Results: $ok_count ok, $fail_count issues"

    if [[ $fail_count -gt 0 ]]; then
        echo ""
        info "Install DwarFS:"
        info "  Ubuntu/Debian: check https://github.com/mhx/dwarfs/releases for .deb packages"
        info "  Arch:          paru -S dwarfs"
        info "  From source:   https://github.com/mhx/dwarfs#building-and-installing"
    fi

    [[ $fail_count -eq 0 ]]
}

# --- Helpers ---

_require_dwarfs() {
    local missing=()
    command -v mkdwarfs      &>/dev/null || missing+=(mkdwarfs)
    command -v dwarfsextract &>/dev/null || missing+=(dwarfsextract)
    command -v dwarfs        &>/dev/null || missing+=(dwarfs)

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing DwarFS tools: ${missing[*]}"
        err "Install from: https://github.com/mhx/dwarfs/releases"
        err "Or run: iwt vm storage check"
        exit 1
    fi
}

_require_fuse() {
    [[ -e /dev/fuse ]] || die "FUSE not available (/dev/fuse missing). Install fuse or fuse3."
}

_mount_qcow2() {
    local qcow2="$1" mount_point="$2"
    require_cmd qemu-nbd
    local nbd_dev
    # Find a free NBD device
    for dev in /dev/nbd{0..15}; do
        if ! lsblk "$dev" &>/dev/null || ! lsblk -n -o MOUNTPOINT "$dev" | grep -q .; then
            nbd_dev="$dev"
            break
        fi
    done
    [[ -n "$nbd_dev" ]] || die "No free NBD device found"

    sudo modprobe nbd max_part=8 2>/dev/null || true
    sudo qemu-nbd --connect="$nbd_dev" "$qcow2"
    sleep 1
    sudo mount "${nbd_dev}p3" "$mount_point" 2>/dev/null || \
    sudo mount "${nbd_dev}p1" "$mount_point" 2>/dev/null || \
    sudo mount "$nbd_dev"     "$mount_point" \
        || die "Failed to mount QCOW2 partition"
}

_umount_qcow2() {
    local mount_point="$1"
    sudo umount "$mount_point" 2>/dev/null || true
    # Disconnect NBD — find which device is backing this mount
    local nbd_dev
    nbd_dev=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null | sed 's/p[0-9]*$//' || true)
    if [[ -n "$nbd_dev" && "$nbd_dev" == /dev/nbd* ]]; then
        sudo qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
    fi
}

usage() {
    cat <<EOF
iwt image/vm storage dwarfs - DwarFS image packing and shared folder mounts

Subcommands:
  pack            Pack a directory or QCOW2 into a .dwarfs archive
  unpack          Extract a .dwarfs archive to a directory
  mount-share     Mount a .dwarfs archive and expose it to a VM via virtiofs
  umount-share    Unmount a DwarFS virtiofs share
  list-shares     List active DwarFS mounts
  check           Check host DwarFS tool availability

Run 'iwt image pack --help' or 'iwt vm storage mount-share --help' for details.

Examples:
  iwt image pack --source windows-x86_64.qcow2
  iwt image unpack --source windows-x86_64.dwarfs
  iwt vm storage mount-share --archive games.dwarfs --vm win11
  iwt vm storage umount-share --name games --vm win11
  iwt vm storage list-shares
  iwt vm storage check
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        pack)           cmd_pack "$@" ;;
        unpack)         cmd_unpack "$@" ;;
        mount-share)    cmd_mount_share "$@" ;;
        umount-share)   cmd_umount_share "$@" ;;
        list-shares)    cmd_list_shares ;;
        check)          cmd_check ;;
        help|--help|-h) usage ;;
        *)
            err "Unknown dwarfs subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
