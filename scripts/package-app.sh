#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <staging-directory>" >&2
    exit 2
fi

staging_directory="$1"
project_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -z "$staging_directory" ] || [ "$staging_directory" = "/" ] || [ "$staging_directory" = "$project_root" ]; then
    echo "refusing to use an unsafe staging directory: $staging_directory" >&2
    exit 2
fi

mkdir -p "$staging_directory"
staging_directory="$(CDPATH= cd -- "$staging_directory" && pwd)"

swift build -c release --product CodexProviderSwitcher
binary_path="$project_root/.build/release/CodexProviderSwitcher"
if [ ! -x "$binary_path" ]; then
    echo "release executable was not produced: $binary_path" >&2
    exit 1
fi

main_bundle="$staging_directory/Codex Provider Switcher.app"
deepseek_bundle="$staging_directory/Codex 切到 DeepSeek.app"
gpt_bundle="$staging_directory/Codex 切回 GPT.app"

for bundle_path in "$main_bundle" "$deepseek_bundle" "$gpt_bundle"; do
    if [ -e "$bundle_path" ] || [ -L "$bundle_path" ]; then
        rm -rf "$bundle_path"
    fi
done

write_info_plist() {
    local bundle_path="$1"
    local display_name="$2"
    local executable_name="$3"

    cat > "$bundle_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$display_name</string>
    <key>CFBundleExecutable</key>
    <string>$executable_name</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.provider-switcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$display_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
}

mkdir -p "$main_bundle/Contents/MacOS"
cp "$binary_path" "$main_bundle/Contents/MacOS/CodexProviderSwitcher"
chmod 755 "$main_bundle/Contents/MacOS/CodexProviderSwitcher"
write_info_plist "$main_bundle" "Codex Provider Switcher" "CodexProviderSwitcher"

make_wrapper_bundle() {
    local bundle_path="$1"
    local display_name="$2"
    local mode="$3"
    local launcher_path="$bundle_path/Contents/MacOS/CodexProviderSwitcherLauncher"

    mkdir -p "$bundle_path/Contents/MacOS"
    write_info_plist "$bundle_path" "$display_name" "CodexProviderSwitcherLauncher"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'set -eu'
        printf '%s\n' 'wrapper_bundle="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"'
        printf '%s\n' 'staged_main="$(dirname -- "$wrapper_bundle")/Codex Provider Switcher.app/Contents/MacOS/CodexProviderSwitcher"'
        printf '%s\n' 'current_user_home="$(/usr/bin/id -P "$(/usr/bin/id -un)" | /usr/bin/awk -F: "{print \$9}")"'
        printf '%s\n' 'installed_main="$current_user_home/Applications/Codex Provider Switcher.app/Contents/MacOS/CodexProviderSwitcher"'
        printf '%s\n' 'if [ -x "$staged_main" ]; then'
        printf '%s\n' '    main_executable="$staged_main"'
        printf '%s\n' 'else'
        printf '%s\n' '    main_executable="$installed_main"'
        printf '%s\n' 'fi'
        printf '%s\n' 'if [ ! -x "$main_executable" ]; then'
        printf '%s\n' '    echo "Codex Provider Switcher.app was not found in ~/Applications" >&2'
        printf '%s\n' '    exit 1'
        printf '%s\n' 'fi'
        printf 'exec "$main_executable" --mode=%s\n' "$mode"
    } > "$launcher_path"
    chmod 755 "$launcher_path"
}

make_wrapper_bundle "$deepseek_bundle" "Codex 切到 DeepSeek" "deepseek"
make_wrapper_bundle "$gpt_bundle" "Codex 切回 GPT" "gpt"

for bundle_path in "$main_bundle" "$deepseek_bundle" "$gpt_bundle"; do
    /usr/bin/plutil -lint "$bundle_path/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "$bundle_path"
done

echo "Packaged:"
printf '  %s\n' "$main_bundle" "$deepseek_bundle" "$gpt_bundle"

