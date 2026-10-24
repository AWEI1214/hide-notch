import AppKit

/// 只在临时目录模拟显示器和壁纸，不调用系统桌面写入接口。
@MainActor
final class FakeDesktop: DesktopBackend {
    var connected: [DisplayInfo]
    var urls: [String: URL]
    var displayOptions: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    var writes: [String] = []
    var failDisplay: String?

    /// 注入两块不同缩放和尺寸的显示器，覆盖内置与副屏的真实差异。
    init(connected: [DisplayInfo], urls: [String: URL]) { self.connected = connected; self.urls = urls }
    /// 返回测试当前仍然连接的屏幕。
    func displays() -> [DisplayInfo] { connected }
    /// 从模拟状态读取文件地址。
    func wallpaperURL(for id: String) throws -> URL { urls[id]! }
    /// 各屏幕有独立显示选项。
    func options(for id: String) throws -> [NSWorkspace.DesktopImageOptionKey: Any] { displayOptions[id] ?? [:] }
    /// 记录系统写入请求，并可模拟某一块屏幕设置失败。
    func setWallpaper(_ url: URL, for id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        if id == failDisplay { throw HideError.message("模拟系统写入失败") }
        urls[id] = url
        displayOptions[id] = options
        writes.append(id)
    }
}

@MainActor
struct WallpaperServiceTests {
    /// 运行独立场景，覆盖多屏选择、恢复、断线、部分失败和旧版本升级。
    static func run() throws {
        try testTargets()
        try testIndependentWallpapersAndDisable()
        try testPreflightFailure()
        try testPartialFailureAndRestart()
        try testDisconnectedRestore()
        try testLegacyBackup()
        try testCustomSourceSurvivesRestart()
        try testBottomCornersOnAllDisplays()
        try testChangedWallpaperStartsNewBackup()
        try testChangedWallpaperPreflightFailure()
    }

    /// 系统换图后允许重新应用，重启仍使用新图，恢复时回到新图及其显示选项。
    static func testChangedWallpaperStartsNewBackup() throws {
        for chooseAnotherImage in [false, true] {
            try fixture { directory, desktop, originals in
                let data = directory.appendingPathComponent("data")
                let service = try WallpaperService(desktop: desktop, directory: data)
                _ = try service.apply(sources: [:], settings: AppearanceSettings())
                let newWallpaper = directory.appendingPathComponent("new-wallpaper.png")
                try FileManager.default.copyItem(at: originals["external"]!, to: newWallpaper)
                desktop.urls["internal"] = newWallpaper
                desktop.displayOptions["internal"] = [.allowClipping: true,
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue]
                try WallpaperRendererTests.check(try service.currentSource(for: desktop.connected[0]) == newWallpaper,
                                                 "系统换图后读取新壁纸")
                let source = chooseAnotherImage ? originals["internal"]! : newWallpaper
                _ = try service.apply(sources: chooseAnotherImage ? ["internal": source] : [:], settings: AppearanceSettings())
                let restarted = try WallpaperService(desktop: desktop, directory: data)
                try WallpaperRendererTests.check(try restarted.currentSource(for: desktop.connected[0]) == source,
                                                 "新壁纸来源跨重启保留")
                let image = try WallpaperRenderer.readImage(at: desktop.urls["internal"]!)
                let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 200, y: 100)!.usingColorSpace(.sRGB)!
                try WallpaperRendererTests.check(chooseAnotherImage ? pixel.redComponent > 0.99 : pixel.redComponent < 0.1,
                                                 "生成结果使用新图或本次主动选图")
                _ = try restarted.disable()
                try WallpaperRendererTests.check(desktop.urls["internal"] == newWallpaper, "恢复到此次应用前的新壁纸")
                try WallpaperRendererTests.check(desktop.displayOptions["internal"]?[.allowClipping] as? Bool == true,
                                                 "恢复新壁纸的显示选项")
            }
        }
    }

    /// 更换壁纸后多屏预检查失败，仍保留旧记录和当前新壁纸，修正后可以重试。
    static func testChangedWallpaperPreflightFailure() throws {
        try fixture { directory, desktop, originals in
            let data = directory.appendingPathComponent("data")
            let service = try WallpaperService(desktop: desktop, directory: data)
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true))
            let journal = try Data(contentsOf: data.appendingPathComponent("restore.json"))
            desktop.urls["internal"] = originals["external"]!
            desktop.urls["external"] = directory.appendingPathComponent("missing.heic")
            desktop.writes = []
            var failed = false
            do { _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true)) }
            catch { failed = true }
            try WallpaperRendererTests.check(failed && desktop.writes.isEmpty, "失败不修改任何屏幕")
            try WallpaperRendererTests.check(try Data(contentsOf: data.appendingPathComponent("restore.json")) == journal,
                                             "预检查失败不提前替换恢复记录")
            desktop.urls["external"] = originals["external"]!
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true))
            _ = try service.disable()
            try WallpaperRendererTests.check(desktop.urls["internal"] == originals["external"], "重试后恢复新壁纸")
        }
    }

    /// 通过真实应用流程验证每块模拟屏幕的底角，并确认关闭开关后可还原直角。
    static func testBottomCornersOnAllDisplays() throws {
        try fixture { directory, desktop, _ in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            for enabled in [true, false] {
                _ = try service.apply(sources: [:], settings: AppearanceSettings(
                    includeOtherDisplays: true, bottomRoundedCorners: enabled))
                for display in desktop.connected {
                    let image = try WallpaperRenderer.readImage(at: desktop.urls[display.id]!)
                    let pixels = NSBitmapImageRep(cgImage: image)
                    let corner = pixels.colorAt(x: 0, y: image.height - 1)!.usingColorSpace(.sRGB)!
                    let middle = pixels.colorAt(x: image.width / 2, y: image.height - 1)!.usingColorSpace(.sRGB)!
                    try WallpaperRendererTests.check(enabled ? corner.blueComponent < 0.01 : corner.blueComponent > 0.99,
                                                     "底部开关应用到每块屏幕")
                    try WallpaperRendererTests.check(middle.blueComponent > 0.99, "保留各屏底部中央的原图")
                }
            }
        }
    }

    /// 每个用例使用独立目录和原图，结束后清理测试数据。
    static func fixture(_ body: (URL, FakeDesktop, [String: URL]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hide-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("internal.png")
        let second = directory.appendingPathComponent("external.png")
        try WallpaperRenderer.save(WallpaperRendererTests.whiteImage(), to: first)
        let blue = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        blue.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        blue.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        try WallpaperRenderer.save(blue.makeImage()!, to: second)
        let displays = [
            DisplayInfo(id: "internal", name: "内置屏", size: CGSize(width: 200, height: 130), scale: 2, menuBarHeight: 12, isBuiltIn: true),
            DisplayInfo(id: "external", name: "副屏", size: CGSize(width: 300, height: 180), scale: 1, menuBarHeight: 10, isBuiltIn: false)
        ]
        let originals = ["internal": first, "external": second]
        let desktop = FakeDesktop(connected: displays, urls: originals)
        desktop.displayOptions["external"] = [.allowClipping: true, .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue]
        try body(directory, desktop, originals)
    }

    /// 默认优先内置屏，合盖后回退主屏，副屏开关开启时选中所有独立屏幕。
    static func testTargets() throws {
        try fixture { _, desktop, _ in
            let displays = desktop.connected.reversed().map { $0 }
            try WallpaperRendererTests.check(WallpaperService.targets(in: displays, includeOtherDisplays: false).map(\.id) == ["internal"], "优先内置屏")
            try WallpaperRendererTests.check(WallpaperService.targets(in: displays, includeOtherDisplays: true).count == 2, "开启副屏")
            try WallpaperRendererTests.check(WallpaperService.targets(in: [displays[0]], includeOtherDisplays: false).first?.id == "external", "合盖回退主屏")
        }
    }

    /// 两屏生成结果保留各自颜色、尺寸和黑条；关闭副屏后恢复它的原图及显示选项。
    static func testIndependentWallpapersAndDisable() throws {
        try fixture { directory, desktop, originals in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true))
            let first = try WallpaperRenderer.readImage(at: desktop.urls["internal"]!)
            let second = try WallpaperRenderer.readImage(at: desktop.urls["external"]!)
            try WallpaperRendererTests.check(first.width == 400 && first.height == 260 && second.width == 300 && second.height == 180, "独立分辨率")
            try WallpaperRendererTests.check(NSBitmapImageRep(cgImage: first).colorAt(x: 200, y: 100)!.redComponent > 0.99, "内置屏保持白色图")
            try WallpaperRendererTests.check(NSBitmapImageRep(cgImage: second).colorAt(x: 150, y: 100)!.blueComponent > 0.99, "副屏保持蓝色图")
            try WallpaperRendererTests.check(NSBitmapImageRep(cgImage: second).colorAt(x: 150, y: 9)!.blueComponent < 0.01 &&
                                            NSBitmapImageRep(cgImage: second).colorAt(x: 150, y: 11)!.blueComponent > 0.99, "副屏使用自己的菜单栏高度")
            try WallpaperRendererTests.check(try service.currentSource(for: desktop.connected[0]) == originals["internal"], "读取来源从原图开始")
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: false))
            try WallpaperRendererTests.check(desktop.urls["external"] == originals["external"] && service.backupCount == 1, "关闭副屏后恢复")
            try WallpaperRendererTests.check(desktop.displayOptions["external"]?[.allowClipping] as? Bool == true, "恢复副屏选项")
            _ = try service.disable()
            try WallpaperRendererTests.check(desktop.urls == originals && !service.hasBackup, "全部恢复原图")
        }
    }

    /// 副屏无法读取或被用户换过壁纸时，预检查必须阻止所有屏幕的修改。
    static func testPreflightFailure() throws {
        try fixture { directory, desktop, originals in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            desktop.urls["external"] = directory.appendingPathComponent("missing.heic")
            var rejected = false
            do { _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true)) }
            catch { rejected = true }
            try WallpaperRendererTests.check(rejected && desktop.writes.isEmpty && !service.hasBackup, "预检查失败不修改桌面")
            desktop.urls = originals
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true))
            desktop.urls["external"] = directory.appendingPathComponent("user-changed.png")
            desktop.writes = []
            rejected = false
            do { _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: false)) }
            catch { rejected = true }
            try WallpaperRendererTests.check(rejected && desktop.writes.isEmpty, "不覆盖副屏新壁纸")
        }
    }

    /// 第二块屏幕写入失败后重建服务，仍可恢复已改和未改的全部屏幕。
    static func testPartialFailureAndRestart() throws {
        try fixture { directory, desktop, originals in
            let data = directory.appendingPathComponent("data")
            let service = try WallpaperService(desktop: desktop, directory: data)
            desktop.failDisplay = "external"
            var failed = false
            do { _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true)) }
            catch { failed = true }
            try WallpaperRendererTests.check(failed && desktop.writes == ["internal"] && service.backupCount == 2, "部分失败保留所有恢复记录")
            desktop.failDisplay = nil
            let restarted = try WallpaperService(desktop: desktop, directory: data)
            _ = try restarted.disable()
            try WallpaperRendererTests.check(desktop.urls == originals && !restarted.hasBackup, "重启后可以恢复")
        }
    }

    /// 副屏拔出时只恢复在线屏幕，插回后还能继续恢复副屏。
    static func testDisconnectedRestore() throws {
        try fixture { directory, desktop, originals in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true))
            let external = desktop.connected.removeLast()
            do { _ = try service.disable() } catch { /* 离线屏幕会明确提示稍后恢复。 */ }
            try WallpaperRendererTests.check(service.backupCount == 1 && desktop.urls["internal"] == originals["internal"], "离线记录保留")
            desktop.connected.append(external)
            _ = try service.disable()
            try WallpaperRendererTests.check(desktop.urls == originals && !service.hasBackup, "重新连接后恢复")
        }
    }

    /// 读取 0.1 版单条 JSON 记录，并验证恢复后的选项和原图没有丢失。
    static func testLegacyBackup() throws {
        try fixture { directory, desktop, originals in
            let generated = directory.appendingPathComponent("legacy.png")
            try WallpaperRenderer.save(WallpaperRendererTests.whiteImage(), to: generated)
            let record = WallpaperBackup(displayID: "internal", originalURL: originals["internal"]!,
                optionsData: try NSKeyedArchiver.archivedData(withRootObject: [NSWorkspace.DesktopImageOptionKey: Any](), requiringSecureCoding: true),
                generatedURL: generated, previousGeneratedURLs: [])
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("restore.json"))
            desktop.urls["internal"] = generated
            let service = try WallpaperService(desktop: desktop, directory: directory)
            try WallpaperRendererTests.check(service.backupCount == 1, "识别旧版恢复记录")
            _ = try service.disable()
            try WallpaperRendererTests.check(desktop.urls == originals, "旧版原壁纸恢复")
        }
    }

    /// 手动选图与恢复原图分别保存，重启后调整圆角不应偷偷换回旧图。
    static func testCustomSourceSurvivesRestart() throws {
        try fixture { directory, desktop, originals in
            let data = directory.appendingPathComponent("data")
            let service = try WallpaperService(desktop: desktop, directory: data)
            _ = try service.apply(sources: ["internal": originals["external"]!], settings: AppearanceSettings())
            let firstImage = try WallpaperRenderer.readImage(at: desktop.urls["internal"]!)
            let expected = NSBitmapImageRep(cgImage: firstImage).colorAt(x: 200, y: 100)!.usingColorSpace(.sRGB)!
            let restarted = try WallpaperService(desktop: desktop, directory: data)
            try WallpaperRendererTests.check(try restarted.currentSource(for: desktop.connected[0]) == originals["external"], "重启保留用户选图")
            _ = try restarted.apply(sources: [:], settings: AppearanceSettings(cornerRadius: 32))
            let image = try WallpaperRenderer.readImage(at: desktop.urls["internal"]!)
            let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 200, y: 100)!.usingColorSpace(.sRGB)!
            // 比较同一色彩空间下的前后结果，避免显示器色彩配置带来的数值偏差。
            try WallpaperRendererTests.check(pixel.blueComponent > pixel.redComponent + 0.5 &&
                abs(pixel.redComponent - expected.redComponent) < 0.01 &&
                abs(pixel.greenComponent - expected.greenComponent) < 0.01 &&
                abs(pixel.blueComponent - expected.blueComponent) < 0.01, "改圆角不更换已选壁纸")
            _ = try restarted.disable()
            try WallpaperRendererTests.check(desktop.urls == originals, "恢复仍回到最初壁纸")
        }
    }
}
