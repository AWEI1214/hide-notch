import AppKit

@MainActor
struct WallpaperCacheTests {
    /// 覆盖反复开关、缓存失效、失败清理和临时文件清理，不修改系统壁纸。
    static func run() throws {
        try testReuseAcrossRestartAndToggle()
        try testSourceContentChanges()
        try testPixelParameters()
        try testMissingCacheRegenerates()
        try testPreflightCleanup()
        try testTemporaryCleanup()
    }

    /// 相同设置不重复写图或提交系统，来回切换参数和重启也能复用同一文件。
    static func testReuseAcrossRestartAndToggle() throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let data = directory.appendingPathComponent("data")
            let service = try WallpaperService(desktop: desktop, directory: data)
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            let first = desktop.urls["internal"]!
            let modified = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
            desktop.writes = []
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            try WallpaperRendererTests.check(desktop.urls["internal"] == first && desktop.writes.isEmpty, "相同效果不重复提交")
            try WallpaperRendererTests.check(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date == modified,
                                             "复用时不重写图片")
            for _ in 0..<3 {
                _ = try service.apply(sources: [:], settings: AppearanceSettings(cornerRadius: 32))
                _ = try service.apply(sources: [:], settings: AppearanceSettings())
            }
            let records = try JSONDecoder().decode([String: WallpaperBackup].self, from: Data(contentsOf: data.appendingPathComponent("restore.json")))
            try WallpaperRendererTests.check(records["internal"]!.previousGeneratedURLs.count == 1, "历史记录去重")
            _ = try service.disable()
            let restarted = try WallpaperService(desktop: desktop, directory: data)
            _ = try restarted.apply(sources: [:], settings: AppearanceSettings())
            try WallpaperRendererTests.check(desktop.urls["internal"] == first, "重启并重新开启仍复用图片")
            let images = try FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
            try WallpaperRendererTests.check(images.count == 2, "两种设置只保存两张效果图")
        }
    }

    /// 同路径图片内容被替换，即使时间戳恢复原值，也必须生成新的效果。
    static func testSourceContentChanges() throws {
        try WallpaperServiceTests.fixture { directory, desktop, originals in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            let first = desktop.urls["internal"]!
            let source = originals["internal"]!
            let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as! Date
            try Data(contentsOf: originals["external"]!).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            try WallpaperRendererTests.check(desktop.urls["internal"] != first, "按内容识别原图变化")
            let pixels = NSBitmapImageRep(cgImage: try WallpaperRenderer.readImage(at: desktop.urls["internal"]!))
            try WallpaperRendererTests.check(pixels.colorAt(x: 200, y: 100)!.usingColorSpace(.sRGB)!.redComponent < 0.1,
                                             "生成结果使用替换后的蓝图")
        }
    }

    /// 实际像素尺寸、黑条和上下圆角参与缓存；被关闭的圆角半径变化不会产生新图。
    static func testPixelParameters() throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            var settings = AppearanceSettings(roundedCorners: false)
            _ = try service.apply(sources: [:], settings: settings)
            let square = desktop.urls["internal"]!
            settings.cornerRadius = 48
            _ = try service.apply(sources: [:], settings: settings)
            try WallpaperRendererTests.check(desktop.urls["internal"] == square, "关闭圆角时忽略无效半径变化")
            settings.bottomRoundedCorners = true
            _ = try service.apply(sources: [:], settings: settings)
            let bottom = desktop.urls["internal"]!
            try WallpaperRendererTests.check(bottom != square, "底部圆角参与缓存")
            settings.extraHeight = 4
            _ = try service.apply(sources: [:], settings: settings)
            let taller = desktop.urls["internal"]!
            try WallpaperRendererTests.check(taller != bottom, "黑条高度参与缓存")
            desktop.connected[0] = DisplayInfo(id: "internal", name: "内置屏", size: CGSize(width: 220, height: 140),
                                                scale: 2, menuBarHeight: 12, isBuiltIn: true)
            _ = try service.apply(sources: [:], settings: settings)
            let image = try WallpaperRenderer.readImage(at: desktop.urls["internal"]!)
            try WallpaperRendererTests.check(desktop.urls["internal"] != taller && image.width == 440 && image.height == 280,
                                             "屏幕尺寸变化后重新生成")
        }
    }

    /// 缓存被删除或为空时重新生成，并重新通知系统使用已修复的文件。
    static func testMissingCacheRegenerates() throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            let output = desktop.urls["internal"]!
            for missing in [true, false] {
                if missing { try FileManager.default.removeItem(at: output) }
                else { try Data().write(to: output) }
                desktop.writes = []
                _ = try service.apply(sources: [:], settings: AppearanceSettings())
                try WallpaperRendererTests.check(try WallpaperRenderer.readImage(at: output).width == 400, "恢复缺失或空缓存")
                try WallpaperRendererTests.check(desktop.writes == ["internal"], "修复缓存后重新提交系统")
            }
        }
    }

    /// 多屏预检查失败只清理本次新建的缓存，已有缓存和恢复记录均保留。
    static func testPreflightCleanup() throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let data = directory.appendingPathComponent("data")
            let service = try WallpaperService(desktop: desktop, directory: data)
            _ = try service.apply(sources: [:], settings: AppearanceSettings())
            let first = desktop.urls["internal"]!
            let journal = try Data(contentsOf: data.appendingPathComponent("restore.json"))
            desktop.urls["external"] = directory.appendingPathComponent("missing.png")
            for radius in [18.0, 32.0] {
                desktop.writes = []
                var rejected = false
                do { _ = try service.apply(sources: [:], settings: AppearanceSettings(includeOtherDisplays: true, cornerRadius: radius)) }
                catch { rejected = true }
                try WallpaperRendererTests.check(rejected && desktop.writes.isEmpty, "缓存命中或新建后失败均不修改屏幕")
                let images = try FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
                try WallpaperRendererTests.check(images.count == 1 && images.first?.standardizedFileURL == first.standardizedFileURL,
                                                 "只清理本次失败产生的图片（剩余 \(images.count) 张）")
                try WallpaperRendererTests.check(try Data(contentsOf: data.appendingPathComponent("restore.json")) == journal,
                                                 "缓存操作不破坏恢复记录")
            }
        }
    }

    /// 启动只删除过期临时文件，保留新临时文件、正式旧壁纸及符号链接指向的外部文件。
    static func testTemporaryCleanup() throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let data = directory.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let old = data.appendingPathComponent(".pending-wallpaper-old.png")
            let fresh = data.appendingPathComponent(".pending-wallpaper-fresh.png")
            let legacy = data.appendingPathComponent("wallpaper-legacy.png")
            let external = directory.appendingPathComponent("external-file.png")
            for file in [old, fresh, legacy, external] { try Data([1]).write(to: file) }
            let expired = Date().addingTimeInterval(-172_800)
            for file in [old, legacy, external] { try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: file.path) }
            let link = data.appendingPathComponent(".pending-wallpaper-link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            _ = try WallpaperService(desktop: desktop, directory: data)
            try WallpaperRendererTests.check(!FileManager.default.fileExists(atPath: old.path), "清理过期临时图片")
            for file in [fresh, legacy, external, link] {
                try WallpaperRendererTests.check(FileManager.default.fileExists(atPath: file.path), "保留未确认可删除的文件")
            }
        }
    }
}
