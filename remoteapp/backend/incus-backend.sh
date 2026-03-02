#!/usr/bin/env bash
# Incus backend for RemoteApp integration.
# Provides functions to query VM state, get RDP connection info,
# and manage the Windows VM lifecycle through Incus.
#
# Sourced by the remoteapp launcher and CLI -- not run directly.

set -euo pipefail

# Source shared library if not already loaded
if [[ -z "${IWT_ROOT:-}" ]]; then
    IWT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if ! declare -f info &>/dev/null; then
    source "$IWT_ROOT/cli/lib.sh"
fi

# --- Configuration ---

IWT_VM_NAME="${IWT_VM_NAME:-windows}"
IWT_RDP_PORT="${IWT_RDP_PORT:-3389}"
IWT_RDP_USER="${IWT_RDP_USER:-User}"
IWT_RDP_PASS="${IWT_RDP_PASS:-}"
IWT_RDP_TIMEOUT="${IWT_RDP_TIMEOUT:-120}"
IWT_AGENT_TIMEOUT="${IWT_AGENT_TIMEOUT:-60}"

# --- VM lifecycle ---

vm_exists() {
    incus info "$IWT_VM_NAME" &>/dev/null
}

vm_is_running() {
    local status
    status=$(incus info "$IWT_VM_NAME" 2>/dev/null | grep "^Status:" | awk '{print $2}')
    [[ "$status" == "RUNNING" ]]
}

vm_start() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist. Create it with: iwt vm create --name $IWT_VM_NAME"
    fi

    if vm_is_running; then
        info "VM '$IWT_VM_NAME' is already running"
        return 0
    fi

    info "Starting VM: $IWT_VM_NAME"
    incus start "$IWT_VM_NAME"
    vm_wait_for_agent
}

vm_stop() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if ! vm_is_running; then
        info "VM '$IWT_VM_NAME' is already stopped"
        return 0
    fi

    info "Stopping VM: $IWT_VM_NAME"
    incus stop "$IWT_VM_NAME"
    ok "VM stopped"
}

vm_wait_for_agent() {
    info "Waiting for incus-agent (timeout: ${IWT_AGENT_TIMEOUT}s)..."
    local attempts=0
    while ! incus exec "$IWT_VM_NAME" -- cmd /c "echo ready" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_AGENT_TIMEOUT ]]; then
            die "Timed out waiting for agent after ${IWT_AGENT_TIMEOUT}s"
        fi
        sleep 1
    done
    ok "Agent ready"
}

# --- Network info ---

vm_get_ip() {
    # Get the first IPv4 address from the VM (skip loopback)
    local ip
    ip=$(incus info "$IWT_VM_NAME" 2>/dev/null | \
        grep -A1 "inet:" | grep -oP '\d+\.\d+\.\d+\.\d+' | \
        grep -v '^127\.' | head -1)

    if [[ -z "$ip" ]]; then
        # Fallback: try the network leases
        ip=$(incus network list-leases incusbr0 2>/dev/null | \
            grep "$IWT_VM_NAME" | awk '{print $3}' | head -1)
    fi

    echo "$ip"
}

vm_wait_for_rdp() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP address. Is the VM running?"

    info "Waiting for RDP on ${ip}:${IWT_RDP_PORT} (timeout: ${IWT_RDP_TIMEOUT}s)..."
    local attempts=0
    while ! timeout 1 bash -c "echo >/dev/tcp/$ip/$IWT_RDP_PORT" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_RDP_TIMEOUT ]]; then
            die "RDP not available after ${IWT_RDP_TIMEOUT}s. Check that RDP is enabled in the VM."
        fi
        # Print progress every 10 seconds
        if [[ $((attempts % 10)) -eq 0 ]]; then
            info "  Still waiting... (${attempts}s)"
        fi
        sleep 1
    done
    ok "RDP ready at ${ip}:${IWT_RDP_PORT}"
}

# --- RDP connection ---

# Detect available FreeRDP binary
_freerdp_cmd() {
    if command -v xfreerdp3 &>/dev/null; then
        echo "xfreerdp3"
    elif command -v xfreerdp &>/dev/null; then
        echo "xfreerdp"
    else
        die "FreeRDP not found. Install xfreerdp3 or xfreerdp."
    fi
}

rdp_connect_full() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Connecting to $ip via $rdp_cmd"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /microphone:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

rdp_launch_remoteapp() {
    # Launch a single Windows application as a seamless Linux window
    local app_name="$1"
    shift
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Launching RemoteApp: $app_name"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /app:"||$app_name" \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

# --- App discovery ---

vm_list_installed_apps() {
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command '
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -notmatch "Update|Hotfix|KB\d+" } |
            Select-Object DisplayName, InstallLocation |
            Sort-Object DisplayName |
            ForEach-Object {
                $loc = if ($_.InstallLocation) { $_.InstallLocation } else { "(unknown)" }
                "$($_.DisplayName)|$loc"
            }
    '
}

vm_find_exe() {
    local exe_name="$1"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$paths = @(
            'C:\\Program Files',
            'C:\\Program Files (x86)',
            'C:\\Windows\\System32',
            'C:\\Windows\\SysWOW64'
        )
        foreach (\$p in \$paths) {
            \$found = Get-ChildItem -Path \$p -Filter '$exe_name' -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
            if (\$found) { Write-Output \$found.FullName; return }
        }
    "
}

# --- Icon extraction ---

vm_extract_icon() {
    # Extract an application icon from the VM and save it locally.
    # Returns the local path to the extracted icon.
    local exe_path="$1"
    local output_dir="${2:-$HOME/.local/share/icons/iwt}"

    mkdir -p "$output_dir"

    local icon_name
    icon_name=$(basename "$exe_path" .exe | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local icon_file="$output_dir/${icon_name}.png"

    if [[ -f "$icon_file" ]]; then
        echo "$icon_file"
        return 0
    fi

    if ! vm_is_running; then
        warn "VM not running; cannot extract icon"
        echo ""
        return 1
    fi

    # Use PowerShell to extract the icon and base64 encode it
    local b64
    b64=$(incus exec "$IWT_VM_NAME" -- powershell -Command "
        Add-Type -AssemblyName System.Drawing
        try {
            \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon('$exe_path')
            if (\$icon) {
                \$bmp = \$icon.ToBitmap()
                \$ms = New-Object System.IO.MemoryStream
                \$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png)
                [Convert]::ToBase64String(\$ms.ToArray())
            }
        } catch {}
    " 2>/dev/null || true)

    if [[ -n "$b64" ]]; then
        echo "$b64" | base64 -d > "$icon_file"
        echo "$icon_file"
    else
        echo ""
    fi
}

# --- Snapshot management ---

snapshot_create() {
    local name="${1:-}"
    local stateful="${2:-false}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local args=()
    if [[ "$stateful" == true ]]; then
        if ! vm_is_running; then
            die "VM must be running for stateful snapshots"
        fi
        args+=(--stateful)
    fi

    if [[ -n "$name" ]]; then
        info "Creating snapshot: $IWT_VM_NAME/$name"
        incus snapshot create "$IWT_VM_NAME" "$name" "${args[@]}"
    else
        info "Creating snapshot of $IWT_VM_NAME (auto-named)"
        incus snapshot create "$IWT_VM_NAME" "${args[@]}"
    fi

    ok "Snapshot created"
}

snapshot_restore() {
    local name="$1"
    local stateful="${2:-false}"

    [[ -n "$name" ]] || die "Snapshot name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local args=()
    if [[ "$stateful" == true ]]; then
        args+=(--stateful)
    fi

    # Warn if VM is running -- restore will stop it
    if vm_is_running; then
        warn "VM is running. It will be stopped before restore."
        incus stop "$IWT_VM_NAME" --force
    fi

    info "Restoring snapshot: $IWT_VM_NAME/$name"
    incus snapshot restore "$IWT_VM_NAME" "$name" "${args[@]}"
    ok "Snapshot restored: $name"
}

snapshot_delete() {
    local name="$1"

    [[ -n "$name" ]] || die "Snapshot name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "Deleting snapshot: $IWT_VM_NAME/$name"
    incus snapshot delete "$IWT_VM_NAME" "$name"
    ok "Snapshot deleted: $name"
}

snapshot_list() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    # Parse snapshot info from incus info output
    local snap_info
    snap_info=$(incus info "$IWT_VM_NAME" 2>/dev/null)

    local in_snapshots=false
    local snap_count=0

    while IFS= read -r line; do
        if [[ "$line" == "Snapshots:" ]]; then
            in_snapshots=true
            continue
        fi

        if [[ "$in_snapshots" == true ]]; then
            # End of snapshots section (next top-level key)
            if [[ "$line" =~ ^[A-Z] && "$line" != "  "* ]]; then
                break
            fi
            if [[ -n "$line" ]]; then
                echo "$line"
                snap_count=$((snap_count + 1))
            fi
        fi
    done <<< "$snap_info"

    if [[ $snap_count -eq 0 ]]; then
        info "No snapshots for $IWT_VM_NAME"
    fi
}

snapshot_schedule_set() {
    local schedule="$1"
    local expiry="${2:-}"
    local pattern="${3:-iwt-snap%d}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "Setting snapshot schedule: $schedule"
    incus config set "$IWT_VM_NAME" snapshots.schedule "$schedule"
    incus config set "$IWT_VM_NAME" snapshots.pattern "$pattern"
    incus config set "$IWT_VM_NAME" snapshots.schedule.stopped false

    if [[ -n "$expiry" ]]; then
        info "Setting snapshot expiry: $expiry"
        incus config set "$IWT_VM_NAME" snapshots.expiry "$expiry"
    fi

    ok "Auto-snapshot configured"
}

snapshot_schedule_show() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local schedule expiry pattern
    schedule=$(incus config get "$IWT_VM_NAME" snapshots.schedule 2>/dev/null || echo "(not set)")
    expiry=$(incus config get "$IWT_VM_NAME" snapshots.expiry 2>/dev/null || echo "(not set)")
    pattern=$(incus config get "$IWT_VM_NAME" snapshots.pattern 2>/dev/null || echo "(not set)")

    echo "VM:        $IWT_VM_NAME"
    echo "Schedule:  $schedule"
    echo "Expiry:    $expiry"
    echo "Pattern:   $pattern"
}

snapshot_schedule_disable() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    incus config unset "$IWT_VM_NAME" snapshots.schedule
    ok "Auto-snapshot disabled for $IWT_VM_NAME"
}

