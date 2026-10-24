#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
./scripts/build-app.sh release
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Configuration/Info.plist)"
app_dir="$project_dir/dist/Hide Notch.app"
stage_dir="$(mktemp -d "$project_dir/.build/installer.XXXXXX")"
# 暂存目录仅用于本次打包，退出时清理，不触碰用户安装的应用或壁纸数据。
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_dir" "$stage_dir/Hide Notch.app"
ln -s /Applications "$stage_dir/Applications"
cat > "$stage_dir/安装说明.txt" <<'INSTRUCTIONS'
Hide Notch 0.4.0

将 Hide Notch.app 拖到 Applications 文件夹，然后从“应用程序”中打开。
应用常驻菜单栏，点击笔记本图标 → 设置…。

默认只处理内置显示器（无内置屏时处理主屏）。
开启“同时应用到副屏”后，每块屏幕保留自己的壁纸。
“顶部圆角”和“底部圆角”可独立开启，共用圆角半径。
“Hide Notch”总开关立即生效：开启应用效果，关闭撤销效果。
总开关位于显示器分组上方。开启后设置自动生效；关闭时仅保存设置。
连续拖动滑块结束后统一更新，无需点击应用按钮。
功能开启时，关闭副屏选项会自动还原已连接副屏。
在系统中更换静态壁纸后可直接重新应用，恢复时回到此次应用前的新壁纸。
退出应用保留效果；关闭总开关即可还原壁纸，后来手动换的新壁纸保持原样。
若有离线或操作失败的屏幕，开关保持开启并提示稍后重试。

当前支持 PNG/JPEG 静态壁纸；每个目标显示器的原壁纸也需为静态图片。
暂不自动同步多个桌面，不支持动态、视频或轮播壁纸。

本包为 Apple Silicon 本地开发签名版本，未配置 Apple 开发者签名与公证。
INSTRUCTIONS
hdiutil create -volname "Hide Notch" -srcfolder "$stage_dir" -format UDZO -ov "$project_dir/dist/Hide-Notch-$version.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$project_dir/dist/Hide-Notch-$version.zip"
codesign --verify --strict "$app_dir"
echo "安装包：$project_dir/dist/Hide-Notch-$version.dmg"
echo "压缩包：$project_dir/dist/Hide-Notch-$version.zip"
