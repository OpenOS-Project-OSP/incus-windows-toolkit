#!/usr/bin/env bash
# Check for updates and self-update IWT.
#
# Usage:
#   update.sh [subcommand]
#
# Subcommands:
#   check         Check for new versions (default)
#   install       Download and install the latest version
#   --help        Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

GITHUB_REPO="OSPF1896/incus-windows-toolkit"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# --- Version comparison ---

# Compare semver strings. Returns 0 if $1 > $2, 1 otherwise.
version_gt() {
    local v1="$1" v2="$2"
    # Strip leading 'v'
    v1="${v1#v}"
    v2="${v2#v}"

    local -a a1 a2
    IFS='.' read -ra a1 <<< "$v1"
    IFS='.' read -ra a2 <<< "$v2"

    local i
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}"
        local n2="${a2[$i]:-0}"
        if [[ "$n1" -gt "$n2" ]]; then
            return 0
        elif [[ "$n1" -lt "$n2" ]]; then
            return 1
        fi
    done
    return 1  # equal
}

# --- Check for updates ---

cmd_check() {
    local current_version
    current_version=$(grep '^VERSION=' "$IWT_ROOT/cli/iwt.sh" | cut -d'"' -f2)

    info "Current version: v${current_version}"
    info "Checking GitHub for updates..."

    local release_json
    release_json=$(curl --disable --silent --fail \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API" 2>/dev/null) || {
        warn "Could not reach GitHub API"
        info "Check manually: https://github.com/${GITHUB_REPO}/releases"
        return 1
    }

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
    local latest_version="${latest_tag#v}"

    if [[ -z "$latest_version" ]]; then
        warn "Could not determine latest version"
        return 1
    fi

    info "Latest version: v${latest_version}"

    if version_gt "$latest_version" "$current_version"; then
        echo ""
        bold "Update available: v${current_version} -> v${latest_version}"
        echo ""

        # Show release notes
        local body
        body=$(echo "$release_json" | jq -r '.body // empty' | head -20)
        if [[ -n "$body" ]]; then
            info "Release notes:"
            echo "$body" | sed 's/^/  /'
            echo ""
        fi

        local tarball_url
        tarball_url=$(echo "$release_json" | jq -r '.tarball_url // empty')
        info "Update with: iwt update install"
        info "Or download: $tarball_url"
    else
        ok "IWT is up to date (v${current_version})"
    fi
}

# --- Install update ---

cmd_install() {
    local current_version
    current_version=$(grep '^VERSION=' "$IWT_ROOT/cli/iwt.sh" | cut -d'"' -f2)

    info "Current version: v${current_version}"
    info "Fetching latest release..."

    local release_json
    release_json=$(curl --disable --silent --fail \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API" 2>/dev/null) || die "Could not reach GitHub API"

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
    local latest_version="${latest_tag#v}"

    if [[ -z "$latest_version" ]]; then
        die "Could not determine latest version"
    fi

    if ! version_gt "$latest_version" "$current_version"; then
        ok "Already up to date (v${current_version})"
        return 0
    fi

    bold "Updating: v${current_version} -> v${latest_version}"
    echo ""

    local tarball_url
    tarball_url=$(echo "$release_json" | jq -r '.tarball_url // empty')
    [[ -n "$tarball_url" ]] || die "No tarball URL in release"

    # Determine install method
    if [[ -d "$IWT_ROOT/.git" ]]; then
        # Git-based install: pull latest
        info "Git repository detected. Pulling latest..."
        (cd "$IWT_ROOT" && git fetch origin && git checkout "v${latest_version}" 2>/dev/null || git pull origin main) || \
            die "Git pull failed"
        ok "Updated via git to v${latest_version}"
    else
        # Tarball-based install: download and replace
        local tmp_dir
        tmp_dir=$(mktemp -d)
        local tmp_tar="$tmp_dir/iwt-${latest_version}.tar.gz"

        info "Downloading v${latest_version}..."
        curl --disable --silent --location --fail \
            --output "$tmp_tar" "$tarball_url" || die "Download failed"

        info "Extracting..."
        tar xzf "$tmp_tar" -C "$tmp_dir" --strip-components=1

        # Check if installed system-wide
        if [[ -f /usr/local/bin/iwt || -f /usr/bin/iwt ]]; then
            info "System install detected. Running make install..."
            (cd "$tmp_dir" && sudo make install) || die "make install failed"
        else
            # Replace in-place
            info "Replacing files in $IWT_ROOT..."
            rsync -a --exclude='.git' --exclude='node_modules' \
                "$tmp_dir/" "$IWT_ROOT/" 2>/dev/null || \
                cp -r "$tmp_dir"/. "$IWT_ROOT/"
        fi

        rm -rf "$tmp_dir"
        ok "Updated to v${latest_version}"
    fi

    # Verify
    local new_version
    new_version=$(grep '^VERSION=' "$IWT_ROOT/cli/iwt.sh" | cut -d'"' -f2)
    info "Verified: v${new_version}"
}

# --- Help ---

usage() {
    cat <<EOF
iwt update - Check for updates and self-update

Subcommands:
  check       Check for new versions (default)
  install     Download and install the latest version

Examples:
  iwt update
  iwt update check
  iwt update install
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-check}"
    shift || true

    case "$subcmd" in
        check)            cmd_check ;;
        install|upgrade)  cmd_install ;;
        help|--help|-h)   usage ;;
        *)
            err "Unknown update subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
