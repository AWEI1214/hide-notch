# Hide Notch

轻量的 macOS 菜单栏工具，通过黑色菜单栏背景让屏幕凹口融入桌面。使用 Swift / SwiftUI 开发，无第三方依赖。

## 功能

- 一键开启或关闭，设置自动生效。
- 可选同时处理副屏，各屏使用自己的当前壁纸。
- 顶部、底部圆角独立开关，半径与黑条高度可调。
- 相同壁纸和设置复用缓存，反复开关不重复生成图片。

## 使用

打开应用后，从菜单栏图标进入“设置”，开启 **Hide Notch**。关闭总开关会撤销效果，其余控件随之禁用；退出应用会保留效果。

当前安装包适用于 **Apple Silicon、macOS 13+**，采用本地开发签名，尚未公证。

仅支持 **PNG/JPEG 静态壁纸**，处理各屏当前桌面，暂不自动同步所有 Spaces。效果通过生成壁纸实现，请保留原图；系统菜单栏材质可能影响实际颜色。

## 开发与打包

在 Mac 上安装 Swift 6+ 和 Xcode Command Line Tools，克隆仓库后运行：

```bash
./scripts/run.sh       # 构建并运行
./scripts/test.sh      # 测试，不修改系统壁纸
./scripts/package.sh   # 生成应用、DMG 和 ZIP，输出到 dist/
```

数据保存在 `~/Library/Application Support/NotchHide/`。正式壁纸缓存可能被其他桌面引用，因此保留；卸载前请连接相关屏幕并关闭功能。

## 许可

[MIT License](LICENSE)
