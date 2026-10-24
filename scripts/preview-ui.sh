#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/ModuleCache
# 只编译设置界面快照入口，不启动正式应用，也不修改系统壁纸。
swiftc -swift-version 6 -module-cache-path "$project_dir/.build/ModuleCache" \
    Sources/NotchHide/DesktopBackend.swift Sources/NotchHide/WallpaperRenderer.swift \
    Sources/NotchHide/WallpaperService.swift \
    Sources/NotchHide/SettingsModel.swift Sources/NotchHide/SettingsView.swift \
    Tests/SettingsSnapshot.swift -o .build/preview-settings
if [[ "${1:-}" != "--compile-only" ]]; then
    .build/preview-settings "$project_dir/.build/ui-preview"
fi
