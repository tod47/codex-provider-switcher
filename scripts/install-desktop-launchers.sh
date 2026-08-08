#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <staging-directory>" >&2
    exit 2
fi

staging_directory="$(CDPATH= cd -- "$1" 2>/dev/null && pwd)" || {
    echo "staging directory does not exist: $1" >&2
    exit 1
}

expected_identifier="local.codex.provider-switcher"
main_source="$staging_directory/Codex Provider Switcher.app"
deepseek_source="$staging_directory/Codex 切到 DeepSeek.app"
gpt_source="$staging_directory/Codex 切回 GPT.app"
current_user_home="$(/usr/bin/id -P "$(/usr/bin/id -un)" | /usr/bin/awk -F: '{print $9}')"
applications_directory="$current_user_home/Applications"
desktop_directory="$current_user_home/Desktop"
main_target="$applications_directory/Codex Provider Switcher.app"
deepseek_target="$desktop_directory/Codex 切到 DeepSeek.app"
gpt_target="$desktop_directory/Codex 切回 GPT.app"

for source_bundle in "$main_source" "$deepseek_source" "$gpt_source"; do
    if [ ! -d "$source_bundle" ] || [ ! -f "$source_bundle/Contents/Info.plist" ]; then
        echo "missing packaged app bundle: $source_bundle" >&2
        exit 1
    fi
done

bundle_identifier() {
    /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

check_target() {
    local target_bundle="$1"
    if [ -L "$target_bundle" ]; then
        echo "refusing to replace symlink: $target_bundle" >&2
        exit 1
    fi
    if [ -e "$target_bundle" ]; then
        local identifier
        identifier="$(bundle_identifier "$target_bundle")"
        if [ "$identifier" != "$expected_identifier" ]; then
            echo "refusing to replace an app with a different bundle identifier: $target_bundle" >&2
            if [ -n "$identifier" ]; then
                echo "found identifier: $identifier" >&2
            else
                echo "found identifier: <missing>" >&2
            fi
            exit 1
        fi
    fi
}

check_target "$main_target"
check_target "$deepseek_target"
check_target "$gpt_target"

mkdir -p "$applications_directory" "$desktop_directory"

install_bundle() {
    local source_bundle="$1"
    local target_bundle="$2"
    if [ -e "$target_bundle" ]; then
        rm -rf "$target_bundle"
    fi
    /usr/bin/ditto "$source_bundle" "$target_bundle"
}

install_bundle "$main_source" "$main_target"
install_bundle "$deepseek_source" "$deepseek_target"
install_bundle "$gpt_source" "$gpt_target"

echo "Installed main app: $main_target"
echo "Installed DeepSeek launcher: $deepseek_target"
echo "Installed GPT launcher: $gpt_target"
echo "Existing desktop .command files were not touched."
