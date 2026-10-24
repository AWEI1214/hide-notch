import AppKit

/// 保存每块显示器的独立尺寸和缩放，外接屏不沿用内置凹口屏的高度。
struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let size: CGSize
    let scale: CGFloat
    let menuBarHeight: CGFloat
    let isBuiltIn: Bool

    var pixelWidth: Int { Int((size.width * scale).rounded()) }
    var pixelHeight: Int { Int((size.height * scale).rounded()) }
}

/// 将系统读写集中在这里，测试可以用虚拟显示器验证多屏恢复而不修改真实桌面。
@MainActor
protocol DesktopBackend {
    func displays() -> [DisplayInfo]
    func wallpaperURL(for id: String) throws -> URL
    func options(for id: String) throws -> [NSWorkspace.DesktopImageOptionKey: Any]
    func setWallpaper(_ url: URL, for id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws
}

@MainActor
final class SystemDesktopBackend: DesktopBackend {
    /// 使用稳定 UUID 识别显示器，重启或改变主屏后仍能匹配恢复记录。
    private func identifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 枚举可独立设置的屏幕，镜像副本不重复处理。
    func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayMirrorsDisplay(number.uint32Value) == kCGNullDirectDisplay,
                  let id = identifier(screen) else { return nil }
            let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            return DisplayInfo(id: id, name: screen.localizedName, size: screen.frame.size,
                               scale: screen.backingScaleFactor,
                               menuBarHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, topInset),
                               isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0)
        }
    }

    /// 每次操作前重新查找屏幕，拔插显示器后不使用过期对象。
    private func screen(for id: String) throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: { identifier($0) == id }) else {
            throw HideError.message("显示器已断开，请重新连接后重试。")
        }
        return screen
    }

    /// 读取该显示器当前桌面的壁纸文件。
    func wallpaperURL(for id: String) throws -> URL {
        guard let url = NSWorkspace.shared.desktopImageURL(for: try screen(for: id)) else {
            throw HideError.message("系统没有提供当前壁纸文件。")
        }
        return url
    }

    /// 保存壁纸原有的缩放、裁切和背景颜色。
    func options(for id: String) throws -> [NSWorkspace.DesktopImageOptionKey: Any] {
        NSWorkspace.shared.desktopImageOptions(for: try screen(for: id)) ?? [:]
    }

    /// 仅向指定显示器提交设置，其他显示器保持各自的壁纸。
    func setWallpaper(_ url: URL, for id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen(for: id), options: options)
    }
}

struct AppearanceSettings: Equatable {
    var includeOtherDisplays = false
    var roundedCorners = true
    var cornerRadius: Double = 18
    var extraHeight: Double = 0
    var bottomRoundedCorners = false
}
