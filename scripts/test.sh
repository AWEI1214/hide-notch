#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/ModuleCache
# 直接编译图像测试，只有 Command Line Tools 也能执行，不修改桌面。
swiftc -swift-version 6 -module-cache-path "$project_dir/.build/ModuleCache" \
    Sources/NotchHide/WallpaperRenderer.swift \
    Sources/NotchHide/DesktopBackend.swift \
    Sources/NotchHide/WallpaperService.swift \
    Sources/NotchHide/SettingsModel.swift \
    Tests/NotchHideTests/SettingsModelTests.swift \
    Tests/NotchHideTests/WallpaperServiceTests.swift \
    Tests/NotchHideTests/WallpaperRendererTests.swift \
    -o .build/verify-renderer
.build/verify-renderer
