#!/usr/bin/env bash
# Download and install WinBtrfs inside a running Windows VM via the Incus agent.
#
# WinBtrfs (maharmstone/btrfs) is a Windows kernel driver that enables reading
# and writing Btrfs volumes natively. Installing it in the guest allows Windows
# to access Btrfs-formatted block devices passed through from the Linux host,
# enabling cross-OS data sharing without virtiofs/9p overhead.
#
# Usage:
#   setup-winbtrfs.sh [options]
#
# Options:
#   --vm NAME       Target VM (default: $IWT_VM_NAME)
#   --version VER   WinBtrfs release tag, e.g. v1.9 (default: latest)
#   --check         Only check if WinBtrfs is installed, don't install
#   --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

WINBTRFS_VERSION=""   # empty = resolve latest from GitHub API
CHECK_ONLY=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)      IWT_VM_NAME="$2"; shift 2 ;;
            --version) WINBTRFS_VERSION="$2"; shift 2 ;;
            --check)   CHECK_ONLY=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

# --- Status check ---

winbtrfs_check() {
    local result
    result=$(incus exec "$IWT_VM_NAME" -- powershell -Command '
        $result = @{}

        # Check for the driver binary
        $driverPath = "C:\Windows\System32\drivers\btrfs.sys"
        $result.DriverPresent = (Test-Path $driverPath)

        # Check for the shell extension DLL (present after full install)
        $shellExt = "C:\Windows\System32\shellbtrfs.dll"
        $result.ShellExtPresent = (Test-Path $shellExt)

        # Check the btrfs service entry
        $svc = Get-Service -Name "btrfs" -ErrorAction SilentlyContinue
        $result.ServiceStatus = if ($svc) { $svc.Status.ToString() } else { "NotInstalled" }

        # Try to read version from driver file metadata
        if ($result.DriverPresent) {
            $ver = (Get-Item $driverPath -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
            $result.Version = if ($ver) { $ver } else { "unknown" }
        } else {
            $result.Version = "NotInstalled"
        }

        # Check mkbtrfs.exe (format tool, present after full install)
        $result.MkBtrfsPresent = (Test-Path "C:\Windows\System32\mkbtrfs.exe")

        $result | ConvertTo-Json
    ' 2>/dev/null) || {
        err "Cannot reach VM agent. Is the VM running?"
        return 1
    }

    echo "$result"
}

winbtrfs_is_installed() {
    local status_json
    status_json=$(winbtrfs_check) || return 1
    local present
    present=$(echo "$status_json" | jq -r '.DriverPresent // false')
    [[ "$present" == "true" || "$present" == "True" ]]
}

# --- Release URL resolution ---

winbtrfs_get_download_url() {
    local version="$1"
    local api_url

    if [[ -n "$version" ]]; then
        api_url="https://api.github.com/repos/maharmstone/btrfs/releases/tags/${version}"
    else
        api_url="https://api.github.com/repos/maharmstone/btrfs/releases/latest"
    fi

    local release_json
    release_json=$(curl --disable --silent --fail \
        -H "Accept: application/vnd.github+json" \
        "$api_url") || {
        # Fallback: construct a known URL pattern for v1.9
        local fallback_ver="${version:-v1.9}"
        warn "GitHub API unavailable, using fallback URL for ${fallback_ver}"
        echo "https://github.com/maharmstone/btrfs/releases/download/${fallback_ver}/btrfs-${fallback_ver#v}.zip"
        return
    }

    # Prefer the .zip asset (contains signed .inf + .sys + .dll)
    local zip_url
    zip_url=$(echo "$release_json" | jq -r \
        '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -1)

    if [[ -z "$zip_url" ]]; then
        # Fall back to tarball
        zip_url=$(echo "$release_json" | jq -r '.zipball_url // empty')
    fi

    if [[ -z "$zip_url" ]]; then
        local tag
        tag=$(echo "$release_json" | jq -r '.tag_name // "v1.9"')
        zip_url="https://github.com/maharmstone/btrfs/releases/download/${tag}/btrfs-${tag#v}.zip"
    fi

    echo "$zip_url"
}

# --- Installation ---

winbtrfs_install() {
    info "Resolving WinBtrfs download URL..."
    local zip_url
    zip_url=$(winbtrfs_get_download_url "$WINBTRFS_VERSION")
    info "URL: $zip_url"

    info "Downloading WinBtrfs inside guest..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'Stop'
        \$zipPath = 'C:\Windows\Temp\winbtrfs.zip'
        \$extractPath = 'C:\Windows\Temp\winbtrfs'

        Write-Host 'IWT: Downloading WinBtrfs...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri '${zip_url}' -OutFile \$zipPath -UseBasicParsing

        if (-not (Test-Path \$zipPath)) {
            Write-Host 'IWT: ERROR - Download failed'
            exit 1
        }

        \$size = (Get-Item \$zipPath).Length
        Write-Host \"IWT: Downloaded WinBtrfs zip (\$size bytes)\"

        # Extract
        if (Test-Path \$extractPath) { Remove-Item \$extractPath -Recurse -Force }
        Expand-Archive -Path \$zipPath -DestinationPath \$extractPath -Force
        Write-Host 'IWT: Extracted WinBtrfs'
    " || die "Failed to download WinBtrfs in guest"

    info "Installing WinBtrfs driver (pnputil)..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'Stop'
        \$extractPath = 'C:\Windows\Temp\winbtrfs'

        # Find the .inf file (may be in a subdirectory)
        \$infFile = Get-ChildItem \$extractPath -Recurse -Filter 'btrfs.inf' |
                    Select-Object -First 1

        if (-not \$infFile) {
            Write-Host 'IWT: ERROR - btrfs.inf not found in archive'
            Get-ChildItem \$extractPath -Recurse | Select-Object FullName
            exit 1
        }

        Write-Host \"IWT: Installing driver from \$(\$infFile.FullName)\"

        # pnputil /add-driver installs the driver package into the driver store
        # and optionally installs it on matching devices immediately (/install)
        \$result = & pnputil /add-driver \$infFile.FullName /install 2>&1
        Write-Host \$result

        # Verify the driver service was created
        \$svc = Get-Service -Name 'btrfs' -ErrorAction SilentlyContinue
        if (\$svc) {
            Write-Host \"IWT: btrfs service status: \$(\$svc.Status)\"
        } else {
            # pnputil succeeded but service may not appear until a Btrfs volume
            # is attached. This is expected behaviour.
            Write-Host 'IWT: btrfs service not yet visible (normal if no Btrfs volume attached)'
        }

        # Clean up
        Remove-Item 'C:\Windows\Temp\winbtrfs.zip' -Force -ErrorAction SilentlyContinue
        Remove-Item \$extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'IWT: WinBtrfs driver installed'
    " || die "WinBtrfs driver installation failed"

    ok "WinBtrfs installed in $IWT_VM_NAME"
}

# --- Secure Boot note ---

print_secureboot_note() {
    echo ""
    warn "Secure Boot note:"
    warn "  WinBtrfs uses a non-Microsoft signing chain. If Secure Boot is enabled"
    warn "  in the VM, the driver may be blocked on Windows 10/11."
    warn "  To allow it, run inside the guest (as Administrator):"
    warn "    reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy /v UpgradedSystem /t REG_DWORD /d 1 /f"
    warn "  Then reboot the VM. Alternatively, disable Secure Boot in the VM profile."
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "WinBtrfs Guest Setup"
    info "VM: $IWT_VM_NAME"
    echo ""

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    info "Checking WinBtrfs status..."
    local status_json
    status_json=$(winbtrfs_check) || exit 1

    local driver_present svc_status version
    driver_present=$(echo "$status_json" | jq -r '.DriverPresent // false')
    svc_status=$(echo "$status_json"     | jq -r '.ServiceStatus // "NotInstalled"')
    version=$(echo "$status_json"        | jq -r '.Version // "unknown"')

    if [[ "$driver_present" == "true" || "$driver_present" == "True" ]]; then
        ok "WinBtrfs driver present (version: $version)"
        case "$svc_status" in
            Running) ok "btrfs service: running" ;;
            Stopped) warn "btrfs service: stopped (starts on first Btrfs volume attach)" ;;
            *)       info "btrfs service: $svc_status" ;;
        esac

        if [[ "$CHECK_ONLY" == true ]]; then
            return 0
        fi

        ok "WinBtrfs already installed, nothing to do"
        print_secureboot_note
        return 0
    fi

    if [[ "$CHECK_ONLY" == true ]]; then
        err "WinBtrfs is not installed"
        return 1
    fi

    winbtrfs_install
    print_secureboot_note

    echo ""
    ok "Guest Btrfs setup complete"
    info "Attach a Btrfs block device to the VM with: iwt vm storage attach-btrfs --vm $IWT_VM_NAME --device <path>"
}

main "$@"
