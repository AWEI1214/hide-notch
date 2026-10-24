#!/usr/bin/env bash
set -euo pipefail

# 根据脚本位置定位工程，支持带中文和空格的路径。
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "用法：$0 [debug|release]" >&2
    exit 1
fi
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
build_options=(--configuration "$configuration" --cache-path "$project_dir/.build/cache" --config-path "$project_dir/.build/config" --security-path "$project_dir/.build/security")
# 只在受限开发环境显式启用；正常用户构建保留 SwiftPM 默认沙盒。
if [[ "${NOTCH_HIDE_DISABLE_SPM_SANDBOX:-0}" == "1" ]]; then
    build_options+=(--disable-sandbox)
fi
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Hide Notch.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$binary_dir/NotchHide" "$app_dir/Contents/MacOS/NotchHide"
cp "$project_dir/Configuration/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Configuration/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

# 临时签名供本机开发使用；正式分发需另行配置开发者签名和公证。
codesign --force --sign - "$app_dir"
echo "应用已生成：$app_dir"
