#!/usr/bin/env bash
# IWT test runner.
# Runs unit tests (no Incus/QEMU required) and optionally integration tests.
#
# Usage:
#   run-tests.sh              Run unit tests only
#   run-tests.sh --all        Run unit + integration tests (requires Incus)
#   run-tests.sh --lint       Run shellcheck only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$IWT_ROOT/cli/lib.sh"

PASSED=0
FAILED=0
SKIPPED=0

run_test() {
    local name="$1"
    shift
    if "$@" 2>/dev/null; then
        ok "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        err "FAIL: $name"
        FAILED=$((FAILED + 1))
    fi
}

skip_test() {
    local name="$1" reason="$2"
    warn "SKIP: $name ($reason)"
    SKIPPED=$((SKIPPED + 1))
}

# --- Unit tests (no external deps) ---

test_cli_help() {
    "$IWT_ROOT/cli/iwt.sh" help | grep -q "Incus Windows Toolkit"
}

test_cli_version() {
    "$IWT_ROOT/cli/iwt.sh" version | grep -qP '^iwt v\d+\.\d+\.\d+'
}

test_cli_subcommands() {
    "$IWT_ROOT/cli/iwt.sh" image --help | grep -q "build"
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "create"
    "$IWT_ROOT/cli/iwt.sh" profiles --help | grep -q "install"
    "$IWT_ROOT/cli/iwt.sh" remoteapp --help | grep -q "launch"
    "$IWT_ROOT/cli/iwt.sh" config --help | grep -q "init"
}

test_cli_unknown_command() {
    ! "$IWT_ROOT/cli/iwt.sh" nonexistent 2>/dev/null
}

test_config_init() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init
    [[ -f "$tmp_config" ]]
    grep -q "IWT_VM_NAME" "$tmp_config"
    rm -f "$tmp_config"
}

test_config_show() {
    local tmp_config
    tmp_config=$(mktemp)
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config show | grep -q "IWT_VM_NAME"
    rm -f "$tmp_config"
}

test_completion_bash() {
    "$IWT_ROOT/cli/iwt.sh" completion bash | grep -q "_iwt_completions"
}

test_completion_zsh() {
    "$IWT_ROOT/cli/iwt.sh" completion zsh | grep -q "compdef"
}

test_profiles_list() {
    "$IWT_ROOT/cli/iwt.sh" profiles list | grep -q "windows-desktop"
}

test_profiles_show() {
    "$IWT_ROOT/cli/iwt.sh" profiles show windows-desktop | grep -q "description:"
}

test_profiles_validate() {
    "$IWT_ROOT/profiles/validate.sh"
}

test_lib_detect_arch() {
    source "$IWT_ROOT/cli/lib.sh"
    local arch
    arch=$(detect_arch)
    [[ "$arch" =~ ^(x86_64|arm64)$ ]]
}

test_lib_arch_to_windows() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(arch_to_windows x86_64)" == "amd64" ]]
    [[ "$(arch_to_windows arm64)" == "arm64" ]]
}

test_lib_arch_to_qemu() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(arch_to_qemu x86_64)" == "x86_64" ]]
    [[ "$(arch_to_qemu arm64)" == "aarch64" ]]
}

test_lib_human_size() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(human_size 1073741824)" == "1G" ]]
    [[ "$(human_size 1048576)" == "1M" ]]
    [[ "$(human_size 1024)" == "1K" ]]
    [[ "$(human_size 500)" == "500B" ]]
}

test_build_image_requires_iso() {
    ! "$IWT_ROOT/image-pipeline/scripts/build-image.sh" 2>/dev/null
}

test_download_list_versions() {
    local out
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-versions)
    echo "$out" | grep -q "11"
    echo "$out" | grep -q "server-2022"
}

test_download_list_langs() {
    local out
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-langs --version 11)
    echo "$out" | grep -q "English"
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-langs --version server-2022)
    echo "$out" | grep -q "English"
}

test_download_help() {
    "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --help | grep -q "version"
}

test_cli_image_list() {
    "$IWT_ROOT/cli/iwt.sh" image list | grep -q "Consumer"
}

test_cli_image_download_help() {
    "$IWT_ROOT/cli/iwt.sh" image --help | grep -q "download"
}

test_cli_vm_snapshot_help() {
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "create"
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "restore"
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "auto"
}

test_cli_vm_help_mentions_snapshot() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "snapshot"
}

test_backend_snapshot_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f snapshot_create &>/dev/null
    declare -f snapshot_restore &>/dev/null
    declare -f snapshot_delete &>/dev/null
    declare -f snapshot_list &>/dev/null
    declare -f snapshot_schedule_set &>/dev/null
    declare -f snapshot_schedule_show &>/dev/null
    declare -f snapshot_schedule_disable &>/dev/null
}

test_apps_conf_format() {
    local conf="$IWT_ROOT/remoteapp/freedesktop/apps.conf"
    [[ -f "$conf" ]]
    # Every non-comment, non-empty line should have 4 pipe-separated fields
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        local fields
        fields=$(echo "$line" | tr '|' '\n' | wc -l)
        [[ "$fields" -eq 4 ]] || return 1
    done < "$conf"
}

# --- Lint ---

test_shellcheck() {
    find "$IWT_ROOT" -name '*.sh' -exec shellcheck -x -S warning {} +
}

# --- Integration tests (require Incus) ---

test_incus_profiles_install() {
    "$IWT_ROOT/cli/iwt.sh" profiles install
    incus profile show windows-desktop | grep -q "description:"
}

test_incus_vm_create_delete() {
    local name="iwt-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"
    incus info "$name" | grep -q "Status:"
    incus delete "$name" --force
}

test_incus_snapshot_lifecycle() {
    local name="iwt-snap-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"

    # Create snapshot
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot create --name test-snap

    # List snapshots
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot list | grep -q "test-snap"

    # Delete snapshot
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot delete test-snap

    # Cleanup
    incus delete "$name" --force
}

# --- Runner ---

run_unit_tests() {
    bold "Unit Tests"
    echo ""

    run_test "CLI help"                test_cli_help
    run_test "CLI version"             test_cli_version
    run_test "CLI subcommands"         test_cli_subcommands
    run_test "CLI unknown command"     test_cli_unknown_command
    run_test "Config init"             test_config_init
    run_test "Config show"             test_config_show
    run_test "Completion bash"         test_completion_bash
    run_test "Completion zsh"          test_completion_zsh
    run_test "Profiles list"           test_profiles_list
    run_test "Profiles show"           test_profiles_show
    run_test "Profiles validate"       test_profiles_validate
    run_test "Lib detect_arch"         test_lib_detect_arch
    run_test "Lib arch_to_windows"     test_lib_arch_to_windows
    run_test "Lib arch_to_qemu"        test_lib_arch_to_qemu
    run_test "Lib human_size"          test_lib_human_size
    run_test "Build requires --iso"    test_build_image_requires_iso
    run_test "Download list versions"  test_download_list_versions
    run_test "Download list langs"     test_download_list_langs
    run_test "Download help"           test_download_help
    run_test "CLI image list"          test_cli_image_list
    run_test "CLI image download help" test_cli_image_download_help
    run_test "CLI vm snapshot help"    test_cli_vm_snapshot_help
    run_test "CLI vm help has snapshot" test_cli_vm_help_mentions_snapshot
    run_test "Backend snapshot funcs"  test_backend_snapshot_functions_exist
    run_test "apps.conf format"        test_apps_conf_format
}

run_lint() {
    bold "Lint"
    echo ""
    run_test "shellcheck" test_shellcheck
}

run_integration_tests() {
    bold "Integration Tests"
    echo ""

    if ! command -v incus &>/dev/null; then
        skip_test "Incus profiles install" "incus not found"
        skip_test "Incus VM create/delete" "incus not found"
        return
    fi

    if ! incus info &>/dev/null 2>&1; then
        skip_test "Incus profiles install" "incusd not reachable"
        skip_test "Incus VM create/delete" "incusd not reachable"
        return
    fi

    run_test "Incus profiles install"  test_incus_profiles_install
    run_test "Incus VM create/delete"  test_incus_vm_create_delete
    run_test "Incus snapshot lifecycle" test_incus_snapshot_lifecycle
}

# --- Main ---

main() {
    local mode="${1:-unit}"

    echo ""
    bold "IWT Test Suite"
    echo ""

    case "$mode" in
        --lint)
            run_lint
            ;;
        --all)
            run_unit_tests
            echo ""
            run_lint
            echo ""
            run_integration_tests
            ;;
        *)
            run_unit_tests
            echo ""
            run_lint
            ;;
    esac

    echo ""
    bold "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"

    [[ $FAILED -eq 0 ]]
}

main "$@"
