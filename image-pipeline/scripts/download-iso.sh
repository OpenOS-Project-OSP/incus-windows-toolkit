#!/usr/bin/env bash
# Download Windows ISO images from Microsoft.
#
# Uses Microsoft's software download connector API for consumer editions
# (Windows 10/11) and the eval center for Server editions.
# ARM64 ISOs are fetched via the UUP dump API.
#
# Adapted from quickemu/Mido (Elliot Killick, MIT license).
#
# Usage:
#   download-iso.sh [options]
#
# Options:
#   --version VER       Windows version: 10 | 11 | server-2022 | server-2025 (default: 11)
#   --lang LANG         Language (default: "English (United States)")
#   --arch ARCH         Architecture: x86_64 | arm64 (default: auto-detect)
#   --output-dir DIR    Download directory (default: current directory)
#   --list-versions     List available Windows versions
#   --list-langs        List available languages for a version
#   --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# Defaults
WIN_VERSION="11"
LANG_NAME="English (United States)"
ARCH=""
OUTPUT_DIR="."
LIST_VERSIONS=false
LIST_LANGS=false

USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
MS_DOWNLOAD_PROFILE="606624d44113"

# --- Available versions and languages ---

CONSUMER_VERSIONS=(10 11)
SERVER_VERSIONS=(server-2022 server-2025 server-2019 server-2016)

CONSUMER_LANGUAGES=(
    "Arabic"
    "Brazilian Portuguese"
    "Bulgarian"
    "Chinese (Simplified)"
    "Chinese (Traditional)"
    "Croatian"
    "Czech"
    "Danish"
    "Dutch"
    "English (United States)"
    "English International"
    "Estonian"
    "Finnish"
    "French"
    "French Canadian"
    "German"
    "Greek"
    "Hebrew"
    "Hungarian"
    "Italian"
    "Japanese"
    "Korean"
    "Latvian"
    "Lithuanian"
    "Norwegian"
    "Polish"
    "Portuguese"
    "Romanian"
    "Russian"
    "Serbian Latin"
    "Slovak"
    "Slovenian"
    "Spanish"
    "Spanish (Mexico)"
    "Swedish"
    "Thai"
    "Turkish"
    "Ukrainian"
)

SERVER_LANGUAGES=(
    "English (United States)"
    "Chinese (Simplified)"
    "French"
    "German"
    "Italian"
    "Japanese"
    "Korean"
    "Portuguese (Brazil)"
    "Russian"
    "Spanish"
)

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)       WIN_VERSION="$2"; shift 2 ;;
            --lang)          LANG_NAME="$2"; shift 2 ;;
            --arch)          ARCH="$2"; shift 2 ;;
            --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
            --list-versions) LIST_VERSIONS=true; shift ;;
            --list-langs)    LIST_LANGS=true; shift ;;
            --help)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)               die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$ARCH" ]]; then
        ARCH=$(detect_arch)
    fi
}

# --- List commands ---

do_list_versions() {
    bold "Available Windows versions:"
    echo ""
    echo "  Consumer:"
    for v in "${CONSUMER_VERSIONS[@]}"; do
        echo "    $v"
    done
    echo ""
    echo "  Server (evaluation):"
    for v in "${SERVER_VERSIONS[@]}"; do
        echo "    $v"
    done
    echo ""
    echo "  Architecture support:"
    echo "    x86_64: all versions"
    echo "    arm64:  10, 11 (via UUP dump)"
}

do_list_langs() {
    if [[ "$WIN_VERSION" == server-* ]]; then
        bold "Available languages for $WIN_VERSION:"
        printf '  %s\n' "${SERVER_LANGUAGES[@]}"
    else
        bold "Available languages for Windows $WIN_VERSION:"
        printf '  %s\n' "${CONSUMER_LANGUAGES[@]}"
    fi
}

# --- Consumer Windows download (10/11 x86_64) ---

download_consumer_x86_64() {
    local version="$1"

    require_cmd curl jq uuidgen

    local url="https://www.microsoft.com/en-us/software-download/windows${version}"
    if [[ "$version" == "10" ]]; then
        url="${url}ISO"
    fi

    local session_id
    session_id="$(uuidgen)"

    info "Fetching download page for Windows $version..."
    local page_html
    page_html=$(curl --disable --silent --user-agent "$USER_AGENT" \
        --header "Accept:" --max-filesize 1M --fail \
        --proto =https --tlsv1.2 --http1.1 -- "$url") || \
        die "Failed to fetch download page. Microsoft may have changed the URL."

    # Extract product edition ID
    local product_id
    product_id=$(echo "$page_html" | grep -Eo '<option value="[0-9]+">Windows' | \
        cut -d '"' -f 2 | head -n 1 | tr -cd '0-9' | head -c 16)
    [[ -n "$product_id" ]] || die "Could not find product edition ID on download page"
    info "Product edition ID: $product_id"

    # Permit session
    curl --disable --silent --output /dev/null --user-agent "$USER_AGENT" \
        --header "Accept:" --max-filesize 100K --fail \
        --proto =https --tlsv1.2 --http1.1 -- \
        "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$session_id" || \
        warn "Session permit request failed (may still work)"

    # Get language -> SKU ID mapping
    info "Getting language SKU for: $LANG_NAME"
    local sku_json
    sku_json=$(curl --disable --silent --fail --max-filesize 100K \
        --proto =https --tlsv1.2 --http1.1 \
        "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=${MS_DOWNLOAD_PROFILE}&ProductEditionId=${product_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}") || \
        die "Failed to get SKU information"

    local sku_id
    sku_id=$(echo "$sku_json" | jq -r \
        '.Skus[] | select(.LocalizedLanguage=="'"$LANG_NAME"'" or .Language=="'"$LANG_NAME"'").Id')
    [[ -n "$sku_id" ]] || die "Language '$LANG_NAME' not found. Use --list-langs to see available options."
    info "SKU ID: $sku_id"

    # Get download link
    info "Requesting download link..."
    local link_json
    link_json=$(curl --disable --silent --fail \
        --referer "$url" \
        "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=${MS_DOWNLOAD_PROFILE}&productEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}") || \
        die "Failed to get download links"

    if echo "$link_json" | grep -q "Sentinel marked this request as rejected"; then
        die "Microsoft blocked the download request based on your IP. Try again later or use a VPN."
    fi

    # Extract the 64-bit ISO link
    local download_url
    download_url=$(echo "$link_json" | jq -r \
        '.ProductDownloadLinks[] | select(.DownloadType=="IsoX64").Uri // empty')

    if [[ -z "$download_url" ]]; then
        # Fallback: try any ISO link
        download_url=$(echo "$link_json" | jq -r \
            '.ProductDownloadLinks[0].Uri // empty')
    fi

    [[ -n "$download_url" ]] || die "No download URL found in Microsoft's response"

    # Download
    local filename="Win${version}_${LANG_NAME// /_}_x86_64.iso"
    filename=$(echo "$filename" | tr -d '()')
    local output_path="$OUTPUT_DIR/$filename"

    info "Downloading: $filename"
    info "URL: ${download_url:0:80}..."
    mkdir -p "$OUTPUT_DIR"

    curl --disable --location --fail --progress-bar \
        --output "$output_path" -- "$download_url" || \
        die "Download failed"

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null || echo "0")
    ok "Downloaded: $output_path ($(human_size "$size"))"
    echo "$output_path"
}

# --- ARM64 consumer Windows via UUP dump ---

download_consumer_arm64() {
    local version="$1"

    require_cmd curl jq

    info "ARM64 ISOs are not directly available from Microsoft."
    info "Using UUP dump API to find the latest ARM64 build..."

    # UUP dump API: find latest ARM64 build
    local search_query="windows ${version} arm64"
    local api_url="https://api.uupdump.net/listid.php"

    local builds_json
    builds_json=$(curl --disable --silent --fail \
        "${api_url}?search=${search_query// /+}&sortByDate=1") || \
        die "Failed to query UUP dump API"

    local build_id
    build_id=$(echo "$builds_json" | jq -r \
        '[.response.builds[] | select(.arch=="arm64")] | first | .uuid // empty')

    if [[ -z "$build_id" ]]; then
        die "No ARM64 build found on UUP dump for Windows $version"
    fi

    local build_title
    build_title=$(echo "$builds_json" | jq -r \
        '[.response.builds[] | select(.arch=="arm64")] | first | .title // "unknown"')
    info "Found build: $build_title"
    info "Build ID: $build_id"

    # Get download info for this build
    local lang_code
    case "$LANG_NAME" in
        "English (United States)") lang_code="en-us" ;;
        "English International")   lang_code="en-gb" ;;
        "Chinese (Simplified)")    lang_code="zh-cn" ;;
        "Chinese (Traditional)")   lang_code="zh-tw" ;;
        "French")                  lang_code="fr-fr" ;;
        "German")                  lang_code="de-de" ;;
        "Italian")                 lang_code="it-it" ;;
        "Japanese")                lang_code="ja-jp" ;;
        "Korean")                  lang_code="ko-kr" ;;
        "Portuguese")              lang_code="pt-pt" ;;
        "Brazilian Portuguese")    lang_code="pt-br" ;;
        "Russian")                 lang_code="ru-ru" ;;
        "Spanish")                 lang_code="es-es" ;;
        "Spanish (Mexico)")        lang_code="es-mx" ;;
        *)
            # Try lowercase with dashes
            lang_code=$(echo "$LANG_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            warn "Guessing language code: $lang_code"
            ;;
    esac

    # For ARM64, we provide the UUP dump link and instructions
    # since building the ISO requires running their converter script
    local uup_url="https://uupdump.net/selectlang.php?id=${build_id}"

    echo ""
    bold "ARM64 ISO Download"
    echo ""
    info "UUP dump does not provide pre-built ISOs. You need to:"
    echo ""
    echo "  1. Visit: $uup_url"
    echo "  2. Select language: $LANG_NAME"
    echo "  3. Select edition: Pro"
    echo "  4. Choose 'Download and convert to ISO'"
    echo "  5. Run the downloaded script to build the ISO"
    echo ""
    echo "  Alternatively, on Linux:"
    echo ""
    echo "    git clone https://github.com/uup-dump/converter"
    echo "    cd converter"
    echo "    ./convert.sh wubi ${build_id} ${lang_code} professional"
    echo ""
    info "Once you have the ISO, run:"
    echo "    iwt image build --iso <path-to-iso> --arch arm64"
    echo ""

    # Return the UUP dump URL for reference
    echo "$uup_url"
}

# --- Windows Server evaluation download ---

download_server() {
    local version="$1"

    require_cmd curl

    # Map version to eval center slug
    local eval_slug
    case "$version" in
        server-2025) eval_slug="windows-server-2025" ;;
        server-2022) eval_slug="windows-server-2022" ;;
        server-2019) eval_slug="windows-server-2019" ;;
        server-2016) eval_slug="windows-server-2016" ;;
        *)           die "Unknown server version: $version" ;;
    esac

    local url="https://www.microsoft.com/en-us/evalcenter/download-${eval_slug}"

    info "Fetching eval center page for $version..."
    local page_html
    page_html=$(curl --disable --silent --location --max-filesize 1M --fail \
        --proto =https --tlsv1.2 --http1.1 -- "$url") || \
        die "Failed to fetch eval center page"

    [[ -n "$page_html" ]] || die "Empty response from eval center"

    # Map language to culture code
    local culture=""
    case "$LANG_NAME" in
        "English (United States)") culture="en-us" ;;
        "Chinese (Simplified)")    culture="zh-cn" ;;
        "French")                  culture="fr-fr" ;;
        "German")                  culture="de-de" ;;
        "Italian")                 culture="it-it" ;;
        "Japanese")                culture="ja-jp" ;;
        "Korean")                  culture="ko-kr" ;;
        "Portuguese (Brazil)")     culture="pt-br" ;;
        "Russian")                 culture="ru-ru" ;;
        "Spanish")                 culture="es-es" ;;
        *)                         culture="en-us"
                                   warn "Language '$LANG_NAME' not available for Server; falling back to English" ;;
    esac

    local download_url
    download_url=$(echo "$page_html" | \
        grep -oP 'https://go\.microsoft\.com/fwlink/p/\?LinkID=[0-9]+&clcid=0x[0-9a-f]+&culture='"$culture"'&country=[A-Z]+' | \
        head -1)

    if [[ -z "$download_url" ]]; then
        # Fallback: try to find any ISO link
        download_url=$(echo "$page_html" | \
            grep -oP 'https://go\.microsoft\.com/fwlink/p/\?LinkID=[0-9]+[^"]*' | \
            head -1)
    fi

    if [[ -z "$download_url" ]]; then
        # Second fallback: direct ISO links
        download_url=$(echo "$page_html" | \
            grep -oP 'https://[^"]+\.iso' | \
            grep -i "$culture" | head -1)
    fi

    if [[ -z "$download_url" ]]; then
        die "Could not find download link for $version ($LANG_NAME). The eval center page may have changed."
    fi

    local filename="${eval_slug}_${culture}_${ARCH}.iso"
    local output_path="$OUTPUT_DIR/$filename"

    info "Downloading: $filename"
    mkdir -p "$OUTPUT_DIR"

    curl --disable --location --fail --progress-bar \
        --output "$output_path" -- "$download_url" || \
        die "Download failed"

    local size
    size=$(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null || echo "0")
    ok "Downloaded: $output_path ($(human_size "$size"))"
    echo "$output_path"
}

# --- Main ---

main() {
    parse_args "$@"

    if [[ "$LIST_VERSIONS" == true ]]; then
        do_list_versions
        exit 0
    fi

    if [[ "$LIST_LANGS" == true ]]; then
        do_list_langs
        exit 0
    fi

    echo ""
    bold "IWT ISO Download"
    info "Version:  $WIN_VERSION"
    info "Language: $LANG_NAME"
    info "Arch:     $ARCH"
    info "Output:   $OUTPUT_DIR"
    echo ""

    if [[ "$WIN_VERSION" == server-* ]]; then
        download_server "$WIN_VERSION"
    elif [[ "$ARCH" == "arm64" ]]; then
        download_consumer_arm64 "$WIN_VERSION"
    else
        download_consumer_x86_64 "$WIN_VERSION"
    fi
}

main "$@"
