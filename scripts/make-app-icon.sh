#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <source-png> <output-icns>" >&2
    exit 2
fi

source_image="$1"
output_icns="$2"

if [ ! -f "$source_image" ]; then
    echo "source image does not exist: $source_image" >&2
    exit 1
fi

output_directory="$(dirname -- "$output_icns")"
iconset_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-provider-switcher-iconset.XXXXXX")"
iconset_directory="$iconset_root/CodexProviderSwitcher.iconset"
cleanup() {
    rm -rf "$iconset_root"
}
trap cleanup EXIT

mkdir -p "$output_directory"
mkdir -p "$iconset_directory"
rm -rf "$output_icns"

for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset_directory/icon_${size}x${size}.png" >/dev/null
done

/usr/bin/sips -z 32 32 "$source_image" --out "$iconset_directory/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 64 64 "$source_image" --out "$iconset_directory/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$source_image" --out "$iconset_directory/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$source_image" --out "$iconset_directory/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$source_image" --out "$iconset_directory/icon_512x512@2x.png" >/dev/null

/usr/bin/iconutil --convert icns --output "$output_icns" "$iconset_directory"
echo "Created $output_icns"
