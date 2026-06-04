#!/bin/bash
set -e

FORCE_CORE=0

usage() {
    echo "Usage: $0 [--force]"
    echo ""
    echo "  (default)  Download mihomo only when clash.meta/ does not exist"
    echo "  --force    Remove clash.meta/ and download latest mihomo release"
}

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE_CORE=1
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

# Match standard darwin builds only (e.g. mihomo-darwin-amd64-v1.19.26.gz), not go120/go122 variants.
MIHOMO_ARM64_PATTERN='mihomo-darwin-arm64-v[0-9]+\.[0-9]+\.[0-9]+\.gz'
MIHOMO_AMD64_PATTERN='mihomo-darwin-amd64-v[0-9]+\.[0-9]+\.[0-9]+\.gz'

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
    echo "Download complete."
}

if [ "$FORCE_CORE" -eq 1 ]; then
    echo "Force mode: removing existing clash.meta..."
    rm -rf clash.meta
fi

if [ ! -d "clash.meta" ]; then
    download_mihomo
else
    echo "Using existing clash.meta (pass --force to re-download latest mihomo)"
fi

echo "Unzip core files"
cd clash.meta
ls
gzip -d *.gz
echo "Create Universal core"
lipo -create -output com.metacubex.ClashX.ProxyConfigHelper.meta mihomo-darwin-amd64* mihomo-darwin-arm64*
chmod +x com.metacubex.ClashX.ProxyConfigHelper.meta

echo "Update meta core md5 to code"
sed -i '' "s/WOSHIZIDONGSHENGCHENGDEA/$(md5 -q com.metacubex.ClashX.ProxyConfigHelper.meta)/g" ../ClashX/AppDelegate.swift
sed -n '20p' ../ClashX/AppDelegate.swift

echo "Gzip Universal core"
gzip com.metacubex.ClashX.ProxyConfigHelper.meta
cp com.metacubex.ClashX.ProxyConfigHelper.meta.gz ../ClashX/Resources/
cd ..

echo "delete old files"
rm -f ./ClashX/Resources/country.mmdb
rm -f ./ClashX/Resources/geosite.dat
rm -f ./ClashX/Resources/geoip.dat
rm -rf ./ClashX/Resources/dashboard
rm -f GeoLite2-Country.*
echo "install mmdb"
curl -LO https://github.com/MetaCubeX/meta-rules-dat/raw/release/country.mmdb
gzip country.mmdb
mv country.mmdb.gz ./ClashX/Resources/country.mmdb.gz
echo "install geosite"
curl -LO https://github.com/MetaCubeX/meta-rules-dat/raw/release/geosite.dat
gzip geosite.dat
mv geosite.dat.gz ./ClashX/Resources/geosite.dat.gz
echo "install geoip"
curl -LO https://github.com/MetaCubeX/meta-rules-dat/raw/release/geoip.dat
gzip geoip.dat
mv geoip.dat.gz ./ClashX/Resources/geoip.dat.gz


echo "install yacd dashboard"
cd ClashX/Resources
git clone -b gh-pages https://github.com/MetaCubeX/Yacd-meta.git dashboard/yacd
cd dashboard/yacd
rm -rf *.webmanifest *.js CNAME .git
cd ../../

echo "install XD dashboard"
git clone -b gh-pages https://github.com/metacubex/metacubexd.git dashboard/xd
cd dashboard/xd
rm -rf *.webmanifest CNAME .git
cd ../../

echo "install zashboard"
git clone -b gh-pages https://github.com/Zephyruso/zashboard.git dashboard/zashboard
cd dashboard/zashboard
rm -rf *.webmanifest CNAME .git