#!/usr/bin/env bash
# bdfs (btrfs-dwarfs-framework) integration for IWT.
#
# Wraps the bdfs CLI and bdfs_daemon to expose the BTRFS+DwarFS hybrid
# namespace to IWT workflows:
#
#   - partition   Register/remove/list bdfs partitions
#   - blend       Mount/unmount the unified BTRFS+DwarFS namespace
#   - export      Export a BTRFS subvolume to a compressed DwarFS image
#   - import      Import a DwarFS image back into a BTRFS subvolume
#   - snapshot    CoW snapshot of a DwarFS image's BTRFS container
#   - promote     Make a DwarFS-backed path writable (extract to BTRFS)
#   - demote      Compress a BTRFS subvolume into a DwarFS image
#   - status      Show bdfs partition and blend status
#   - daemon      Start/stop/status the bdfs_daemon
#   - check       Verify host prerequisites
#   - help        Show this help
#
# Requires btrfs-dwarfs-framework to be built and installed:
#   https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework
#
# Usage:
#   setup-bdfs.sh <subcommand> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$IWT_ROOT/cli/lib.sh"
load_config

# --- Subcommands ---

cmd_partition() {
    local subcmd="${1:-help}"
    shift || true

    _require_bdfs

    case "$subcmd" in
        add)
            local type="" device="" label="" mount=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --type)    type="$2";   shift 2 ;;
                    --device)  device="$2"; shift 2 ;;
                    --label)   label="$2";  shift 2 ;;
                    --mount)   mount="$2";  shift 2 ;;
                    --help|-h) _usage_partition_add; exit 0 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$type"   ]] || die "--type is required (dwarfs-backed | btrfs-backed)"
            [[ -n "$device" ]] || die "--device is required"
            [[ -n "$label"  ]] || die "--label is required"
            [[ -n "$mount"  ]] || die "--mount is required"

            echo ""
            bold "bdfs partition add"
            info "Type:   $type"
            info "Device: $device"
            info "Label:  $label"
            info "Mount:  $mount"
            echo ""

            bdfs partition add \
                --type   "$type"   \
                --device "$device" \
                --label  "$label"  \
                --mount  "$mount"

            ok "Partition '$label' registered"
            ;;

        remove)
            local uuid="${1:?Usage: iwt vm storage bdfs-partition remove <uuid>}"
            bdfs partition remove --uuid "$uuid"
            ok "Partition $uuid removed"
            ;;

        list)
            bdfs partition list
            ;;

        show)
            local uuid="${1:?Usage: iwt vm storage bdfs-partition show <uuid>}"
            bdfs partition show --uuid "$uuid"
            ;;

        help|--help|-h)
            _usage_partition_add
            ;;

        *)
            die "Unknown partition subcommand: $subcmd"
            ;;
    esac
}

_usage_partition_add() {
    cat <<EOF
iwt vm storage bdfs-partition add - Register a bdfs partition

Options:
  --type    TYPE    dwarfs-backed | btrfs-backed  (required)
  --device  PATH    Block device, e.g. /dev/sdb1  (required)
  --label   NAME    Human-readable label           (required)
  --mount   PATH    Mount point                    (required)

Examples:
  iwt vm storage bdfs-partition add \\
      --type dwarfs-backed --device /dev/sdb1 --label archive --mount /mnt/archive

  iwt vm storage bdfs-partition add \\
      --type btrfs-backed --device /dev/sdc1 --label images --mount /mnt/images
EOF
}

cmd_blend() {
    local subcmd="${1:-help}"
    shift || true

    _require_bdfs

    case "$subcmd" in
        mount)
            local btrfs_uuid="" dwarfs_uuid="" mountpoint="" writeback=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --btrfs-uuid)   btrfs_uuid="$2";  shift 2 ;;
                    --dwarfs-uuid)  dwarfs_uuid="$2"; shift 2 ;;
                    --mountpoint)   mountpoint="$2";  shift 2 ;;
                    --writeback)    writeback=true;   shift   ;;
                    --help|-h)      _usage_blend; exit 0 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$btrfs_uuid"  ]] || die "--btrfs-uuid is required"
            [[ -n "$dwarfs_uuid" ]] || die "--dwarfs-uuid is required"
            [[ -n "$mountpoint"  ]] || die "--mountpoint is required"

            echo ""
            bold "bdfs blend mount"
            info "BTRFS partition:  $btrfs_uuid"
            info "DwarFS partition: $dwarfs_uuid"
            info "Mountpoint:       $mountpoint"
            info "Writeback:        $writeback"
            echo ""

            local args=(--btrfs-uuid "$btrfs_uuid" --dwarfs-uuid "$dwarfs_uuid" --mountpoint "$mountpoint")
            [[ "$writeback" == true ]] && args+=(--writeback)

            bdfs blend mount "${args[@]}"
            ok "Blend namespace mounted at $mountpoint"
            ;;

        umount)
            local mountpoint="${1:?Usage: iwt vm storage bdfs-blend umount <mountpoint>}"
            bdfs blend umount --mountpoint "$mountpoint"
            ok "Blend namespace unmounted: $mountpoint"
            ;;

        help|--help|-h)
            _usage_blend
            ;;

        *)
            die "Unknown blend subcommand: $subcmd"
            ;;
    esac
}

_usage_blend() {
    cat <<EOF
iwt vm storage bdfs-blend - Mount/unmount the BTRFS+DwarFS unified namespace

Subcommands:
  mount   --btrfs-uuid UUID --dwarfs-uuid UUID --mountpoint PATH [--writeback]
  umount  MOUNTPOINT

The blend layer merges a writable BTRFS upper layer with one or more read-only
DwarFS lower layers. Reads fall through BTRFS → DwarFS; writes always land on
BTRFS with automatic copy-up.

Examples:
  iwt vm storage bdfs-blend mount \\
      --btrfs-uuid <uuid> --dwarfs-uuid <uuid> --mountpoint /mnt/blend --writeback

  iwt vm storage bdfs-blend umount /mnt/blend
EOF
}

cmd_export() {
    local partition="" subvol_id="" btrfs_mount="" name="" compression="zstd" verify=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)    partition="$2";    shift 2 ;;
            --subvol-id)    subvol_id="$2";    shift 2 ;;
            --btrfs-mount)  btrfs_mount="$2";  shift 2 ;;
            --name)         name="$2";         shift 2 ;;
            --compression)  compression="$2";  shift 2 ;;
            --verify)       verify=true;       shift   ;;
            --help|-h)      _usage_export; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition"   ]] || die "--partition is required"
    [[ -n "$subvol_id"   ]] || die "--subvol-id is required"
    [[ -n "$btrfs_mount" ]] || die "--btrfs-mount is required"
    [[ -n "$name"        ]] || die "--name is required"

    _require_bdfs

    echo ""
    bold "bdfs export"
    info "Partition:   $partition"
    info "Subvol ID:   $subvol_id"
    info "BTRFS mount: $btrfs_mount"
    info "Name:        $name"
    info "Compression: $compression"
    echo ""

    local args=(
        --partition   "$partition"
        --subvol-id   "$subvol_id"
        --btrfs-mount "$btrfs_mount"
        --name        "$name"
        --compression "$compression"
    )
    [[ "$verify" == true ]] && args+=(--verify)

    bdfs export "${args[@]}"
    ok "Exported '$name' to partition $partition"
}

_usage_export() {
    cat <<EOF
iwt vm storage bdfs-export - Export a BTRFS subvolume to a compressed DwarFS image

Options:
  --partition UUID    Target bdfs partition UUID  (required)
  --subvol-id  ID     BTRFS subvolume ID          (required)
  --btrfs-mount PATH  BTRFS filesystem mount      (required)
  --name       NAME   Image name                  (required)
  --compression ALG   zstd | lz4 | zlib           (default: zstd)
  --verify            Verify image after creation

Example:
  # List subvolume IDs first:
  btrfs subvolume list /mnt/data

  iwt vm storage bdfs-export \\
      --partition <uuid> --subvol-id 256 \\
      --btrfs-mount /mnt/data --name win11_v1 --verify
EOF
}

cmd_import() {
    local partition="" image_id="" btrfs_mount="" subvol_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)    partition="$2";    shift 2 ;;
            --image-id)     image_id="$2";     shift 2 ;;
            --btrfs-mount)  btrfs_mount="$2";  shift 2 ;;
            --subvol-name)  subvol_name="$2";  shift 2 ;;
            --help|-h)      _usage_import; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition"   ]] || die "--partition is required"
    [[ -n "$image_id"    ]] || die "--image-id is required"
    [[ -n "$btrfs_mount" ]] || die "--btrfs-mount is required"
    [[ -n "$subvol_name" ]] || die "--subvol-name is required"

    _require_bdfs

    echo ""
    bold "bdfs import"
    info "Partition:   $partition"
    info "Image ID:    $image_id"
    info "BTRFS mount: $btrfs_mount"
    info "Subvol name: $subvol_name"
    echo ""

    bdfs import \
        --partition   "$partition"   \
        --image-id    "$image_id"    \
        --btrfs-mount "$btrfs_mount" \
        --subvol-name "$subvol_name"

    ok "Imported image $image_id as subvolume '$subvol_name'"
}

_usage_import() {
    cat <<EOF
iwt vm storage bdfs-import - Import a DwarFS image into a BTRFS subvolume

Options:
  --partition  UUID   Source bdfs partition UUID  (required)
  --image-id   ID     Image ID to import          (required)
  --btrfs-mount PATH  Destination BTRFS mount     (required)
  --subvol-name NAME  New subvolume name          (required)

Example:
  iwt vm storage bdfs-import \\
      --partition <uuid> --image-id 1 \\
      --btrfs-mount /mnt/data --subvol-name win11_restored
EOF
}

cmd_snapshot() {
    local partition="" image_id="" name="" readonly=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)  partition="$2"; shift 2 ;;
            --image-id)   image_id="$2";  shift 2 ;;
            --name)       name="$2";      shift 2 ;;
            --readonly)   readonly=true;  shift   ;;
            --help|-h)    _usage_snapshot; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition" ]] || die "--partition is required"
    [[ -n "$image_id"  ]] || die "--image-id is required"
    [[ -n "$name"      ]] || die "--name is required"

    _require_bdfs

    echo ""
    bold "bdfs snapshot"
    info "Partition: $partition"
    info "Image ID:  $image_id"
    info "Name:      $name"
    info "Read-only: $readonly"
    echo ""

    local args=(--partition "$partition" --image-id "$image_id" --name "$name")
    [[ "$readonly" == true ]] && args+=(--readonly)

    bdfs snapshot "${args[@]}"
    ok "Snapshot '$name' created"
}

_usage_snapshot() {
    cat <<EOF
iwt vm storage bdfs-snapshot - CoW snapshot of a DwarFS image's BTRFS container

Options:
  --partition UUID   bdfs partition UUID  (required)
  --image-id  ID     Image ID to snapshot (required)
  --name      NAME   Snapshot name        (required)
  --readonly         Create read-only snapshot

Example:
  iwt vm storage bdfs-snapshot \\
      --partition <uuid> --image-id 1 --name win11_snap_$(date +%Y%m%d) --readonly
EOF
}

cmd_promote() {
    local blend_path="" subvol_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-path)   blend_path="$2";  shift 2 ;;
            --subvol-name)  subvol_name="$2"; shift 2 ;;
            --help|-h)      _usage_promote_demote; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_path"  ]] || die "--blend-path is required"
    [[ -n "$subvol_name" ]] || die "--subvol-name is required"

    _require_bdfs

    echo ""
    bold "bdfs promote"
    info "Blend path:  $blend_path"
    info "Subvol name: $subvol_name"
    echo ""

    bdfs promote --blend-path "$blend_path" --subvol-name "$subvol_name"
    ok "Promoted '$blend_path' to writable subvolume '$subvol_name'"
}

cmd_demote() {
    local blend_path="" image_name="" compression="zstd" delete_subvol=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-path)    blend_path="$2";   shift 2 ;;
            --image-name)    image_name="$2";   shift 2 ;;
            --compression)   compression="$2";  shift 2 ;;
            --delete-subvol) delete_subvol=true; shift  ;;
            --help|-h)       _usage_promote_demote; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_path"  ]] || die "--blend-path is required"
    [[ -n "$image_name"  ]] || die "--image-name is required"

    _require_bdfs

    echo ""
    bold "bdfs demote"
    info "Blend path:     $blend_path"
    info "Image name:     $image_name"
    info "Compression:    $compression"
    info "Delete subvol:  $delete_subvol"
    echo ""

    local args=(--blend-path "$blend_path" --image-name "$image_name" --compression "$compression")
    [[ "$delete_subvol" == true ]] && args+=(--delete-subvol)

    bdfs demote "${args[@]}"
    ok "Demoted '$blend_path' to DwarFS image '$image_name'"
}

_usage_promote_demote() {
    cat <<EOF
iwt vm storage bdfs-promote - Extract a DwarFS-backed path to a writable BTRFS subvolume

  --blend-path  PATH   Path inside the blend namespace  (required)
  --subvol-name NAME   New BTRFS subvolume name         (required)

iwt vm storage bdfs-demote - Compress a BTRFS subvolume to a DwarFS image

  --blend-path    PATH   Path inside the blend namespace  (required)
  --image-name    NAME   Output DwarFS image name         (required)
  --compression   ALG    zstd | lz4 | zlib                (default: zstd)
  --delete-subvol        Remove the BTRFS subvolume after demoting

Examples:
  iwt vm storage bdfs-promote --blend-path /mnt/blend/win11 --subvol-name win11_live
  iwt vm storage bdfs-demote  --blend-path /mnt/blend/win11_live --image-name win11_archived --delete-subvol
EOF
}

cmd_status() {
    local partition="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition) partition="$2"; shift 2 ;;
            --json)      json=true;      shift   ;;
            --help|-h)   echo "Usage: iwt vm storage bdfs-status [--partition UUID] [--json]"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _require_bdfs

    local args=()
    [[ -n "$partition" ]] && args+=(--partition "$partition")
    [[ "$json" == true ]] && args+=(--json)

    bdfs status "${args[@]}"
}

cmd_daemon() {
    local subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
        start)
            if command -v systemctl &>/dev/null && systemctl list-unit-files bdfs_daemon.service &>/dev/null; then
                sudo systemctl start bdfs_daemon
                ok "bdfs_daemon started via systemd"
            else
                info "Starting bdfs_daemon in background..."
                sudo bdfs_daemon -v &
                ok "bdfs_daemon started (PID $!)"
            fi
            ;;
        stop)
            if command -v systemctl &>/dev/null && systemctl is-active bdfs_daemon &>/dev/null; then
                sudo systemctl stop bdfs_daemon
                ok "bdfs_daemon stopped"
            else
                sudo pkill -f bdfs_daemon && ok "bdfs_daemon stopped" || warn "bdfs_daemon not running"
            fi
            ;;
        status)
            if command -v systemctl &>/dev/null; then
                systemctl status bdfs_daemon 2>/dev/null || true
            fi
            if pgrep -x bdfs_daemon &>/dev/null; then
                ok "bdfs_daemon is running (PID $(pgrep -x bdfs_daemon))"
            else
                warn "bdfs_daemon is not running"
            fi
            ;;
        enable)
            sudo systemctl enable bdfs_daemon
            ok "bdfs_daemon enabled at boot"
            ;;
        disable)
            sudo systemctl disable bdfs_daemon
            ok "bdfs_daemon disabled"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm storage bdfs-daemon - Manage the bdfs_daemon process

Subcommands:
  start    Start bdfs_daemon (systemd or background)
  stop     Stop bdfs_daemon
  status   Show daemon status
  enable   Enable bdfs_daemon at boot (systemd)
  disable  Disable bdfs_daemon at boot (systemd)
EOF
            ;;
        *)
            die "Unknown daemon subcommand: $subcmd"
            ;;
    esac
}

cmd_check() {
    echo ""
    bold "bdfs (btrfs-dwarfs-framework) Host Check"
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
    _warn_chk() {
        local label="$1" msg="$2"
        warn "  $label: $msg"
    }

    # bdfs CLI
    if command -v bdfs &>/dev/null; then
        local ver
        ver=$(bdfs --version 2>/dev/null | head -1 || echo "unknown")
        _chk "bdfs CLI ($ver)" "ok"
    else
        _chk "bdfs CLI" "not found — build from https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework"
    fi

    # bdfs_daemon
    if command -v bdfs_daemon &>/dev/null; then
        _chk "bdfs_daemon" "ok"
    else
        _chk "bdfs_daemon" "not found (build btrfs-dwarfs-framework userspace)"
    fi

    # kernel module
    if modinfo btrfs_dwarfs &>/dev/null 2>&1 || lsmod | grep -q '^btrfs_dwarfs'; then
        _chk "btrfs_dwarfs kernel module (loaded)" "ok"
    elif [[ -f /dev/bdfs_ctl ]]; then
        _chk "btrfs_dwarfs kernel module (/dev/bdfs_ctl present)" "ok"
    else
        _chk "btrfs_dwarfs kernel module" "not loaded — run: sudo insmod btrfs_dwarfs.ko"
    fi

    # /dev/bdfs_ctl
    if [[ -e /dev/bdfs_ctl ]]; then
        _chk "/dev/bdfs_ctl" "ok"
    else
        _warn_chk "/dev/bdfs_ctl" "not present (module not loaded or not installed)"
    fi

    # daemon running
    if pgrep -x bdfs_daemon &>/dev/null; then
        _chk "bdfs_daemon running" "ok"
    else
        _warn_chk "bdfs_daemon" "not running (start with: iwt vm storage bdfs-daemon start)"
    fi

    # btrfs-progs (required by bdfs export/import)
    if command -v btrfs &>/dev/null; then
        _chk "btrfs-progs" "ok"
    else
        _chk "btrfs-progs" "not found (required for export/import)"
    fi

    # DwarFS tools (required by bdfs export)
    if command -v mkdwarfs &>/dev/null && command -v dwarfs &>/dev/null; then
        _chk "DwarFS tools (mkdwarfs, dwarfs)" "ok"
    else
        _chk "DwarFS tools" "not found (required for export — see https://github.com/mhx/dwarfs/releases)"
    fi

    echo ""
    info "Results: $ok_count ok, $fail_count issues"

    if [[ $fail_count -gt 0 ]]; then
        echo ""
        info "Build btrfs-dwarfs-framework:"
        info "  git clone https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework"
        info "  cd btrfs-dwarfs-framework && make all && sudo make install"
        info "  sudo insmod kernel/btrfs_dwarfs/btrfs_dwarfs.ko"
    fi

    [[ $fail_count -eq 0 ]]
}

# --- Helpers ---

_require_bdfs() {
    if ! command -v bdfs &>/dev/null; then
        die "bdfs not found. Build btrfs-dwarfs-framework and install it first.
  git clone https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework
  cd btrfs-dwarfs-framework && make all && sudo make install"
    fi
    if ! command -v bdfs_daemon &>/dev/null; then
        die "bdfs_daemon not found. Build btrfs-dwarfs-framework userspace first."
    fi
    if ! pgrep -x bdfs_daemon &>/dev/null; then
        die "bdfs_daemon is not running. Start it with: iwt vm storage bdfs-daemon start"
    fi
}

usage() {
    cat <<EOF
setup-bdfs.sh - bdfs (btrfs-dwarfs-framework) integration for IWT

Usage: setup-bdfs.sh <subcommand> [options]

Subcommands:
  partition  add|remove|list|show   Manage bdfs partitions
  blend      mount|umount           Manage the BTRFS+DwarFS blend namespace
  export                            Export a BTRFS subvolume to a DwarFS image
  import                            Import a DwarFS image into a BTRFS subvolume
  snapshot                          CoW snapshot of a DwarFS image container
  promote                           Make a DwarFS-backed path writable
  demote                            Compress a BTRFS subvolume to DwarFS
  status                            Show bdfs partition/blend status
  daemon     start|stop|status      Manage bdfs_daemon
  check                             Verify host prerequisites
  help                              Show this help

Run 'setup-bdfs.sh <subcommand> --help' for per-subcommand options.
EOF
}

# --- Dispatch ---

subcmd="${1:-help}"
shift || true

case "$subcmd" in
    partition)  cmd_partition "$@" ;;
    blend)      cmd_blend     "$@" ;;
    export)     cmd_export    "$@" ;;
    import)     cmd_import    "$@" ;;
    snapshot)   cmd_snapshot  "$@" ;;
    promote)    cmd_promote   "$@" ;;
    demote)     cmd_demote    "$@" ;;
    status)     cmd_status    "$@" ;;
    daemon)     cmd_daemon    "$@" ;;
    check)      cmd_check     "$@" ;;
    help|--help|-h) usage ;;
    *) die "Unknown subcommand: $subcmd. Run 'setup-bdfs.sh help' for usage." ;;
esac
