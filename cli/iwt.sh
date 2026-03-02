#!/usr/bin/env bash
# iwt - Incus Windows Toolkit
# Unified CLI for Windows VM management on Incus.
#
# Usage: iwt <command> [subcommand] [options]

set -euo pipefail

VERSION="0.2.0"

# Resolve install location
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    IWT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && cd .. && pwd)"
else
    IWT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
fi

# If installed to /usr/local/bin, data is in /usr/local/share/iwt
if [[ ! -d "$IWT_ROOT/image-pipeline" ]]; then
    IWT_ROOT="${IWT_ROOT%/bin}/share/iwt"
fi

export IWT_ROOT

# Source shared library
source "$IWT_ROOT/cli/lib.sh"

# Load user config
load_config

# --- Help ---

show_help() {
    cat <<EOF
iwt - Incus Windows Toolkit v${VERSION}

Usage: iwt <command> [subcommand] [options]

Commands:
  image       Build and manage Windows VM images
  vm          Create, start, stop, and manage Windows VMs
  profiles    Install and manage Incus VM profiles
  remoteapp   Launch Windows apps as seamless Linux windows
  doctor      Check system prerequisites
  config      Manage IWT configuration
  version     Show version

Run 'iwt <command> --help' for details on each command.
EOF
}

# --- Doctor (prerequisite check) ---

cmd_doctor() {
    local auto_install=false
    [[ "${1:-}" == "--install" ]] && auto_install=true

    info "Checking prerequisites..."
    local ok_count=0
    local fail_count=0
    local failed_cmds=()

    check() {
        local name="$1" cmd="$2"
        if command -v "$cmd" &>/dev/null; then
            ok "$name ($cmd)"
            ok_count=$((ok_count + 1))
        else
            err "$name not found ($cmd)"
            fail_count=$((fail_count + 1))
            failed_cmds+=("$cmd")
        fi
    }

    check "Incus"           incus
    check "QEMU (img)"      qemu-img
    check "curl"            curl
    check "xfreerdp3"       xfreerdp3
    check "wimlib"          wimlib-imagex
    check "hivex"           hivexsh

    # Check for at least one ISO tool
    if command -v xorriso &>/dev/null; then
        ok "ISO tool (xorriso)"
        ok_count=$((ok_count + 1))
    elif command -v mkisofs &>/dev/null; then
        ok "ISO tool (mkisofs)"
        ok_count=$((ok_count + 1))
    else
        err "ISO tool not found (need xorriso or mkisofs)"
        fail_count=$((fail_count + 1))
        failed_cmds+=("xorriso")
    fi

    check "shellcheck"      shellcheck

    # Check KVM
    if [[ -e /dev/kvm ]]; then
        ok "KVM (/dev/kvm)"
        ok_count=$((ok_count + 1))
    elif [[ -r /proc/cpuinfo ]] && grep -qE '(vmx|svm)' /proc/cpuinfo; then
        warn "KVM supported by CPU but /dev/kvm missing (load kvm module?)"
        fail_count=$((fail_count + 1))
    else
        err "KVM not available (/dev/kvm missing)"
        fail_count=$((fail_count + 1))
    fi

    # Architecture
    local arch
    arch=$(detect_arch)
    info "Host architecture: $arch"

    # Incus connectivity
    if command -v incus &>/dev/null; then
        if incus info &>/dev/null 2>&1; then
            ok "Incus daemon reachable"
            ok_count=$((ok_count + 1))
        else
            err "Incus daemon not reachable (is incusd running?)"
            fail_count=$((fail_count + 1))
        fi
    fi

    echo ""
    info "Results: $ok_count passed, $fail_count failed"

    # Show install suggestions for failures
    if [[ $fail_count -gt 0 ]]; then
        echo ""
        info "Install suggestions:"
        for cmd in "${failed_cmds[@]}"; do
            suggest_install "$cmd"
        done

        if [[ "$auto_install" == true ]]; then
            echo ""
            info "Auto-install is not yet implemented. Install the packages above manually."
        fi
    fi

    [[ $fail_count -eq 0 ]] && return 0 || return 1
}

# --- Config commands ---

cmd_config() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        init)
            init_config
            ;;
        show)
            if [[ -f "$IWT_CONFIG_FILE" ]]; then
                cat "$IWT_CONFIG_FILE"
            else
                info "No config file found. Run 'iwt config init' to create one."
            fi
            ;;
        edit)
            if [[ ! -f "$IWT_CONFIG_FILE" ]]; then
                init_config
            fi
            "${EDITOR:-vi}" "$IWT_CONFIG_FILE"
            ;;
        path)
            echo "$IWT_CONFIG_FILE"
            ;;
        help|--help|-h)
            cat <<EOF
iwt config - Manage IWT configuration

Subcommands:
  init    Create default config file
  show    Display current config
  edit    Open config in \$EDITOR
  path    Print config file path

Config location: \$HOME/.config/iwt/config
Override with: IWT_CONFIG_FILE=/path/to/config
EOF
            ;;
        *)
            err "Unknown config subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Image commands ---

cmd_image() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        build)
            exec "$IWT_ROOT/image-pipeline/scripts/build-image.sh" "$@"
            ;;
        download)
            exec "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" "$@"
            ;;
        list)
            exec "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-versions
            ;;
        help|--help|-h)
            cat <<EOF
iwt image - Build and download Windows images for Incus

Subcommands:
  download    Download a Windows ISO from Microsoft
  build       Build an Incus-ready image from an ISO
  list        List available Windows versions

Download options:
  --version VER       10 | 11 | server-2022 | server-2025 (default: 11)
  --lang LANG         Language (default: "English (United States)")
  --arch ARCH         x86_64 | arm64 (default: auto-detect)
  --output-dir DIR    Download directory (default: current directory)
  --list-langs        List available languages for a version

Build options:
  --iso PATH          Path to Windows ISO (required)
  --arch ARCH         x86_64 | arm64 (default: auto-detect)
  --edition EDITION   Windows edition (default: Pro)
  --slim              Strip bloatware (tiny11-style)
  --output PATH       Output image path
  --inject-drivers    Inject VirtIO + platform drivers
  --woa-drivers PATH  WOA driver directory (ARM only)
  --size SIZE         Disk size (default: 64G)
  --keep-work         Preserve work directory for debugging

Examples:
  iwt image list
  iwt image download --version 11 --lang "English (United States)"
  iwt image download --version server-2022
  iwt image download --version 11 --arch arm64
  iwt image build --iso Win11_24H2.iso --slim
EOF
            ;;
        *)
            err "Unknown image subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- VM commands ---

cmd_vm() {
    local subcmd="${1:-help}"
    shift || true

    # Source the backend for VM operations
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"

    case "$subcmd" in
        create)
            cmd_vm_create "$@"
            ;;
        start)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            vm_start
            ;;
        stop)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            vm_stop
            ;;
        status)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            if vm_is_running; then
                local ip
                ip=$(vm_get_ip 2>/dev/null || echo "unknown")
                ok "$IWT_VM_NAME is running (IP: $ip)"
            elif vm_exists; then
                info "$IWT_VM_NAME is stopped"
            else
                err "VM '$IWT_VM_NAME' does not exist"
                return 1
            fi
            ;;
        list)
            info "Incus VMs:"
            incus list --format table type=virtual-machine
            ;;
        rdp)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            shift || true
            vm_start
            vm_wait_for_rdp
            rdp_connect_full "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm - Manage Windows VMs

Subcommands:
  create [options]    Create a new Windows VM
  start [name]        Start a VM
  stop [name]         Stop a VM
  status [name]       Show VM status
  list                List all Incus VMs
  rdp [name]          Open full RDP desktop session

Create options:
  --name NAME         VM name (default: windows)
  --profile PROFILE   Incus profile to use (default: windows-desktop)
  --image PATH        Path to modified ISO from 'iwt image build'
  --disk PATH         Path to QCOW2 disk image

Example:
  iwt vm create --name win11 --image windows-modified.iso
  iwt vm rdp win11
EOF
            ;;
        *)
            err "Unknown vm subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_create() {
    local name="windows"
    local profile="windows-desktop"
    local image=""
    local disk=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    name="$2"; shift 2 ;;
            --profile) profile="$2"; shift 2 ;;
            --image)   image="$2"; shift 2 ;;
            --disk)    disk="$2"; shift 2 ;;
            *)         err "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Check if VM already exists
    if incus info "$name" &>/dev/null; then
        die "VM '$name' already exists. Delete it first: incus delete $name"
    fi

    # Check if profile exists, install if not
    if ! incus profile show "$profile" &>/dev/null; then
        info "Profile '$profile' not found. Installing..."
        cmd_profiles install
    fi

    info "Creating VM: $name (profile: $profile)"
    incus init "$name" --vm --empty --profile "$profile"

    if [[ -n "$image" ]]; then
        [[ -f "$image" ]] || die "ISO not found: $image"
        info "Attaching install ISO: $image"
        incus config device add "$name" install disk source="$(realpath "$image")"
    fi

    if [[ -n "$disk" ]]; then
        [[ -f "$disk" ]] || die "Disk image not found: $disk"
        info "Attaching disk image: $disk"
        incus config device add "$name" data disk source="$(realpath "$disk")"
    fi

    ok "VM '$name' created. Start with: iwt vm start $name"
}

# --- Profile commands ---

cmd_profiles() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        install)
            cmd_profiles_install "$@"
            ;;
        list)
            info "Available profiles:"
            find "$IWT_ROOT/profiles" -name '*.yaml' -printf "  %P\n" | sort
            ;;
        show)
            local profile_name="${1:?Usage: iwt profiles show <name>}"
            local arch
            arch=$(detect_arch)
            local profile_file="$IWT_ROOT/profiles/$arch/$profile_name.yaml"
            if [[ ! -f "$profile_file" ]]; then
                # Try the other arch
                profile_file=$(find "$IWT_ROOT/profiles" -name "$profile_name.yaml" -print -quit)
            fi
            if [[ -n "$profile_file" && -f "$profile_file" ]]; then
                cat "$profile_file"
            else
                die "Profile not found: $profile_name"
            fi
            ;;
        diff)
            # Show differences between local profile files and what's in Incus
            local arch
            arch=$(detect_arch)
            local profile_dir="$IWT_ROOT/profiles/$arch"
            for profile_file in "$profile_dir"/*.yaml; do
                local pname
                pname=$(basename "$profile_file" .yaml)
                if incus profile show "$pname" &>/dev/null; then
                    info "Diff for $pname:"
                    diff <(incus profile show "$pname") "$profile_file" || true
                else
                    info "$pname: not installed in Incus"
                fi
            done
            ;;
        help|--help|-h)
            cat <<EOF
iwt profiles - Manage Incus VM profiles

Subcommands:
  install [--arch ARCH]   Install profiles into Incus
  list                    List available profile files
  show <name>             Display a profile's YAML
  diff                    Compare local profiles with Incus

Options:
  --arch ARCH    Install only for this architecture (x86_64|arm64)
                 Default: auto-detect from host

Example:
  iwt profiles install
  iwt profiles show windows-desktop
  iwt profiles diff
EOF
            ;;
        *)
            err "Unknown profiles subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_profiles_install() {
    local arch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch) arch="$2"; shift 2 ;;
            *)      err "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$arch" ]]; then
        arch=$(detect_arch)
    fi

    local profile_dir="$IWT_ROOT/profiles/$arch"
    if [[ ! -d "$profile_dir" ]]; then
        die "No profiles found for architecture: $arch"
    fi

    require_cmd incus

    for profile_file in "$profile_dir"/*.yaml; do
        local profile_name
        profile_name=$(basename "$profile_file" .yaml)
        info "Installing profile: $profile_name (from $arch/$(basename "$profile_file"))"

        if incus profile show "$profile_name" &>/dev/null; then
            incus profile edit "$profile_name" < "$profile_file"
            ok "Updated: $profile_name"
        else
            incus profile create "$profile_name"
            incus profile edit "$profile_name" < "$profile_file"
            ok "Created: $profile_name"
        fi
    done
}

# --- RemoteApp commands ---

cmd_remoteapp() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        launch)
            exec "$IWT_ROOT/remoteapp/backend/launch-app.sh" "$@"
            ;;
        install)
            exec "$IWT_ROOT/remoteapp/freedesktop/generate-desktop-entries.sh" "$@"
            ;;
        discover)
            source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
            info "Discovering installed Windows applications..."
            vm_list_installed_apps
            ;;
        config)
            local conf="$IWT_ROOT/remoteapp/freedesktop/apps.conf"
            if [[ "${1:-}" == "edit" ]]; then
                "${EDITOR:-vi}" "$conf"
            else
                info "App config: $conf"
                cat "$conf"
            fi
            ;;
        help|--help|-h)
            cat <<EOF
iwt remoteapp - Run Windows apps as seamless Linux windows

Subcommands:
  launch <app>    Launch a Windows app (exe name or full path)
  install         Generate .desktop files for Linux app menus
  discover        List installed Windows applications
  config [edit]   View or edit the app configuration

Examples:
  iwt remoteapp launch notepad
  iwt remoteapp launch "C:\\Program Files\\app.exe"
  iwt remoteapp install
  iwt remoteapp discover
  iwt remoteapp config edit
EOF
            ;;
        *)
            err "Unknown remoteapp subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Tab completion ---

cmd_completion() {
    local shell="${1:-bash}"
    case "$shell" in
        bash)
            cat <<'COMP'
_iwt_completions() {
    local cur prev commands
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="image vm profiles remoteapp doctor config version help"

    case "$prev" in
        iwt)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
        image)
            COMPREPLY=($(compgen -W "download build list help" -- "$cur"))
            ;;
        vm)
            COMPREPLY=($(compgen -W "create start stop status list rdp help" -- "$cur"))
            ;;
        profiles)
            COMPREPLY=($(compgen -W "install list show diff help" -- "$cur"))
            ;;
        remoteapp)
            COMPREPLY=($(compgen -W "launch install discover config help" -- "$cur"))
            ;;
        config)
            COMPREPLY=($(compgen -W "init show edit path help" -- "$cur"))
            ;;
    esac
}
complete -F _iwt_completions iwt
COMP
            ;;
        zsh)
            cat <<'COMP'
#compdef iwt
_iwt() {
    local -a commands=(
        'image:Build and manage Windows VM images'
        'vm:Create, start, stop, and manage Windows VMs'
        'profiles:Install and manage Incus VM profiles'
        'remoteapp:Launch Windows apps as seamless Linux windows'
        'doctor:Check system prerequisites'
        'config:Manage IWT configuration'
        'version:Show version'
    )
    _arguments '1:command:->cmd' '*::arg:->args'
    case $state in
        cmd) _describe 'command' commands ;;
        args)
            case $words[1] in
                image)     _values 'subcommand' download build list help ;;
                vm)        _values 'subcommand' create start stop status list rdp help ;;
                profiles)  _values 'subcommand' install list show diff help ;;
                remoteapp) _values 'subcommand' launch install discover config help ;;
                config)    _values 'subcommand' init show edit path help ;;
            esac
            ;;
    esac
}
_iwt
COMP
            ;;
        *)
            err "Unsupported shell: $shell (use bash or zsh)"
            exit 1
            ;;
    esac
}

# --- Main dispatch ---

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        image)      cmd_image "$@" ;;
        vm)         cmd_vm "$@" ;;
        profiles)   cmd_profiles "$@" ;;
        remoteapp)  cmd_remoteapp "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        config)     cmd_config "$@" ;;
        completion) cmd_completion "$@" ;;
        version)    echo "iwt v${VERSION}" ;;
        help|--help|-h) show_help ;;
        *)
            err "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
