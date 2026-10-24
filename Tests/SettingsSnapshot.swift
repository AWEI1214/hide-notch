import AppKit
import SwiftUI

/// 界面快照只使用合成图片和虚拟屏幕，禁止真实壁纸写入。
@MainActor
final class SnapshotDesktop: DesktopBackend {
    let imageURL: URL
    private var simulatedURLs: [String: URL] = [:]
    /// 指定供两个虚拟屏幕读取的演示图片。
    init(imageURL: URL) { self.imageURL = imageURL }
    /// 提供一块凹口屏和一块普通副屏，用于检查设置布局。
    func displays() -> [DisplayInfo] {
        [DisplayInfo(id: "internal", name: "内置视网膜显示器", size: CGSize(width: 1512, height: 982), scale: 2, menuBarHeight: 37, isBuiltIn: true),
         DisplayInfo(id: "external", name: "Studio Display", size: CGSize(width: 2560, height: 1440), scale: 1, menuBarHeight: 24, isBuiltIn: false)]
    }
    /// 只读取合成壁纸或虚拟开关生成的图片。
    func wallpaperURL(for id: String) throws -> URL { simulatedURLs[id] ?? imageURL }
    /// 测试图片使用默认填充选项。
    func options(for id: String) throws -> [NSWorkspace.DesktopImageOptionKey: Any] { [:] }
    /// 仅更新虚拟屏幕的文件地址，不调用系统壁纸接口。
    func setWallpaper(_ url: URL, for id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        simulatedURLs[id] = url
    }
}

@main
@MainActor
struct SettingsSnapshot {
    /// 渲染自己的设置窗口，保存开启、关闭、深浅色与最小窗口截图供布局检查。
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let wallpaper = output.appendingPathComponent("sample-wallpaper.png")
        try makeSample(at: wallpaper)
        let service = try WallpaperService(desktop: SnapshotDesktop(imageURL: wallpaper), directory: output.appendingPathComponent("state"))
        let defaults = UserDefaults(suiteName: "NotchHide.Snapshot.\(UUID().uuidString)")!
        let model = SettingsModel(defaults: defaults, service: service)
        model.settings.includeOtherDisplays = true
        model.settings.bottomRoundedCorners = true
        model.refreshDisplays()
        model.setEnabled(true)
        for (name, appearance, size) in [
            ("settings-light", NSAppearance.Name.aqua, NSSize(width: 480, height: 760)),
            ("settings-dark", NSAppearance.Name.darkAqua, NSSize(width: 480, height: 760)),
            ("settings-compact", NSAppearance.Name.aqua, NSSize(width: 440, height: 560)),
            ("settings-off", NSAppearance.Name.aqua, NSSize(width: 480, height: 760))
        ] {
            if name == "settings-off" { model.setEnabled(false) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Hide Notch · 界面验证"
            window.appearance = NSAppearance(named: appearance)
            let view = NSHostingView(rootView: SettingsView(model: model))
            view.sizingOptions = []
            window.contentView = view
            window.setContentSize(size)
            window.orderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw HideError.message("无法生成界面快照")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard abs(view.bounds.width - size.width) < 1, abs(view.bounds.height - size.height) < 1 else {
                throw HideError.message("设置页超出了预期窗口尺寸")
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
            print("\(name): \(Int(view.bounds.width)) × \(Int(view.bounds.height))")
            window.orderOut(nil)
        }
    }

    /// 生成蓝紫色渐变与山形作为测试壁纸，避免读取用户的私人桌面图片。
    static func makeSample(at url: URL) throws {
        let context = CGContext(data: nil, width: 1512, height: 982, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(red: 0.12, green: 0.24, blue: 0.62, alpha: 1),
                      CGColor(red: 0.48, green: 0.64, blue: 0.84, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 982), end: CGPoint(x: 1512, y: 0), options: [])
        for index in 0..<3 {
            let path = CGMutablePath()
            let base = CGFloat(120 + index * 120)
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: base))
            path.addCurve(to: CGPoint(x: 1512, y: base + 180), control1: CGPoint(x: 500, y: base + 500), control2: CGPoint(x: 900, y: base - 240))
            path.addLine(to: CGPoint(x: 1512, y: 0))
            path.closeSubpath()
            context.setFillColor(CGColor(red: 0.4 + Double(index) * 0.12, green: 0.4, blue: 0.8, alpha: 0.35))
            context.addPath(path)
            context.fillPath()
        }
        try WallpaperRenderer.save(context.makeImage()!, to: url)
    }
}
