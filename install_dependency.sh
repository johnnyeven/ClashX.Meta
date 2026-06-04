#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RESOURCES_DIR="./ClashX/Resources"
CORE_GZ="${RESOURCES_DIR}/com.metacubex.ClashX.ProxyConfigHelper.meta.gz"
GEO_BASE_URL="https://github.com/MetaCubeX/meta-rules-dat/raw/release"

FORCE_ALL=0
FORCE_CORE=0
FORCE_GEO=0
FORCE_DASHBOARD=0

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "  (default)           Install missing deps; sync existing dashboards to gh-pages"
    echo "  --force             Force update all (core + geo + dashboards)"
    echo "  --force-core        Force re-download and package mihomo core"
    echo "  --force-geo         Force re-download geo rule databases"
    echo "  --force-dashboard   Force re-clone dashboards (instead of git pull)"
    echo ""
    echo "Options can be combined, e.g. $0 --force-core --force-geo"
}

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE_ALL=1
            ;;
        --force-core)
            FORCE_CORE=1
            ;;
        --force-geo)
            FORCE_GEO=1
            ;;
        --force-dashboard)
            FORCE_DASHBOARD=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ "$FORCE_ALL" -eq 1 ]; then
    FORCE_CORE=1
    FORCE_GEO=1
    FORCE_DASHBOARD=1
fi

# Match standard darwin builds only (e.g. mihomo-darwin-amd64-v1.19.26.gz), not go120/go122 variants.
MIHOMO_ARM64_PATTERN='mihomo-darwin-arm64-v[0-9]+\.[0-9]+\.[0-9]+\.gz'
MIHOMO_AMD64_PATTERN='mihomo-darwin-amd64-v[0-9]+\.[0-9]+\.[0-9]+\.gz'

dir_is_nonempty() {
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

need_core_download() {
    if [ "$FORCE_CORE" -eq 1 ]; then
        return 0
    fi
    if [ ! -d "clash.meta" ]; then
        return 0
    fi
    if ls clash.meta/mihomo-darwin-arm64*.gz clash.meta/mihomo-darwin-amd64*.gz >/dev/null 2>&1; then
        return 1
    fi
    if ls clash.meta/mihomo-darwin-arm64* clash.meta/mihomo-darwin-amd64* >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

need_core_package() {
    if [ "$FORCE_CORE" -eq 1 ]; then
        return 0
    fi
    if [ ! -f "$CORE_GZ" ]; then
        return 0
    fi
    if [ ! -f "clash.meta/com.metacubex.ClashX.ProxyConfigHelper.meta" ]; then
        return 0
    fi
    if [ "clash.meta/com.metacubex.ClashX.ProxyConfigHelper.meta" -nt "$CORE_GZ" ]; then
        return 0
    fi
    return 1
}

need_geo() {
    if [ "$FORCE_GEO" -eq 1 ]; then
        return 0
    fi
    for f in country.mmdb.gz geosite.dat.gz geoip.dat.gz; do
        if [ ! -f "${RESOURCES_DIR}/${f}" ]; then
            return 0
        fi
    done
    return 1
}

download_mihomo_asset() {
    local pattern="$1"
    local output_path="$2"
    local url
    url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep -E "browser_download_url.*${pattern}" \
        | head -1 \
        | cut -d '"' -f 4)
    if [ -z "$url" ]; then
        echo "Error: no release asset matching ${pattern}" >&2
        exit 1
    fi
    echo "Downloading $(basename "$url") ..."
    curl -fsSL -o "$output_path" "$url"
}

download_mihomo() {
    echo "Downloading latest mihomo..."
    mkdir -p clash.meta
    download_mihomo_asset "$MIHOMO_ARM64_PATTERN" "clash.meta/mihomo-darwin-arm64.gz"
    download_mihomo_asset "$MIHOMO_AMD64_PATTERN" "clash.meta/mihomo-darwin-amd64.gz"
    echo "Mihomo download complete."
}

package_mihomo_core() {
    echo "Packaging universal mihomo core..."
    cd clash.meta

    for gz in mihomo-darwin-arm64*.gz mihomo-darwin-amd64*.gz; do
        if [ -f "$gz" ]; then
            gzip -df "$gz"
        fi
    done

    lipo -create -output com.metacubex.ClashX.ProxyConfigHelper.meta mihomo-darwin-amd64* mihomo-darwin-arm64*
    chmod +x com.metacubex.ClashX.ProxyConfigHelper.meta

    echo "Update meta core md5 in AppDelegate.swift"
    local md5sum
    md5sum=$(md5 -q com.metacubex.ClashX.ProxyConfigHelper.meta)
    sed -i '' "s/^private let MetaCoreMd5 = \".*\"/private let MetaCoreMd5 = \"${md5sum}\"/" ../ClashX/AppDelegate.swift
    sed -n '19p' ../ClashX/AppDelegate.swift

    rm -f com.metacubex.ClashX.ProxyConfigHelper.meta.gz
    gzip -fk com.metacubex.ClashX.ProxyConfigHelper.meta
    cp com.metacubex.ClashX.ProxyConfigHelper.meta.gz "../${CORE_GZ#./}"
    cd ..
    echo "Core packaged to ${CORE_GZ}"
}

install_geo_file() {
    local filename="$1"
    local stem="${filename%.gz}"
    local url="${GEO_BASE_URL}/${stem}"
    local dest="${RESOURCES_DIR}/${filename}"

    echo "Installing ${filename} ..."
    rm -f "$dest" "./${stem}" "./${filename}"
    curl -fsSL -o "./${stem}" "$url"
    gzip -f "./${stem}"
    mv "./${filename}" "$dest"
}

install_geo() {
    mkdir -p "$RESOURCES_DIR"
    install_geo_file "country.mmdb.gz"
    install_geo_file "geosite.dat.gz"
    install_geo_file "geoip.dat.gz"
    echo "Geo databases installed."
}

cleanup_dashboard_content() {
    local name="$1"
    local dest="$2"
    (
        cd "$dest"
        rm -rf *.webmanifest CNAME
        if [ "$name" = "yacd" ]; then
            rm -rf *.js
        fi
    )
}

clone_dashboard() {
    local name="$1"
    local repo_url="$2"
    local dest="$3"

    mkdir -p "${RESOURCES_DIR}/dashboard"
    git clone --depth 1 -b gh-pages "$repo_url" "$dest"
    cleanup_dashboard_content "$name" "$dest"
}

sync_dashboard() {
    local name="$1"
    local repo_url="$2"
    local dest="${RESOURCES_DIR}/dashboard/${name}"

    if [ "$FORCE_DASHBOARD" -eq 1 ]; then
        echo "Force mode: re-cloning dashboard/${name} ..."
        rm -rf "$dest"
        clone_dashboard "$name" "$repo_url" "$dest"
        echo "dashboard/${name} installed."
        return
    fi

    if [ -d "$dest/.git" ]; then
        echo "Updating dashboard/${name} (sync to origin/gh-pages) ..."
        # Shallow clones often diverge from remote; reset matches published static assets.
        git -C "$dest" fetch --depth 1 origin gh-pages
        git -C "$dest" reset --hard FETCH_HEAD
        cleanup_dashboard_content "$name" "$dest"
        echo "dashboard/${name} updated."
        return
    fi

    if dir_is_nonempty "$dest"; then
        echo "dashboard/${name} exists without git metadata, re-cloning ..."
        rm -rf "$dest"
    else
        echo "Installing dashboard/${name} ..."
    fi

    clone_dashboard "$name" "$repo_url" "$dest"
    echo "dashboard/${name} installed."
}

# --- Core ---
if need_core_download; then
    if [ "$FORCE_CORE" -eq 1 ]; then
        echo "Force mode: removing existing clash.meta ..."
        rm -rf clash.meta
    fi
    download_mihomo
else
    echo "Skipping mihomo download (already present, use --force-core)"
fi

if need_core_package; then
    if [ ! -d "clash.meta" ]; then
        echo "Error: clash.meta/ is missing; cannot package core." >&2
        exit 1
    fi
    package_mihomo_core
else
    echo "Skipping core packaging (${CORE_GZ} is up to date, use --force-core)"
fi

# --- Geo ---
if need_geo; then
    if [ "$FORCE_GEO" -eq 1 ]; then
        echo "Force mode: removing existing geo files ..."
        rm -f "${RESOURCES_DIR}/country.mmdb.gz" \
            "${RESOURCES_DIR}/geosite.dat.gz" \
            "${RESOURCES_DIR}/geoip.dat.gz"
    fi
    install_geo
else
    echo "Skipping geo databases (already present, use --force-geo)"
fi

# --- Dashboards ---
DASHBOARDS=(
    "yacd|https://github.com/MetaCubeX/Yacd-meta.git"
    "xd|https://github.com/metacubex/metacubexd.git"
    "zashboard|https://github.com/Zephyruso/zashboard.git"
)

for entry in "${DASHBOARDS[@]}"; do
    name="${entry%%|*}"
    repo="${entry#*|}"
    sync_dashboard "$name" "$repo"
done

echo "Done."
