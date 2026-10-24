import AppKit

/// 独立测试入口，不依赖完整 Xcode 才提供的 XCTest。
@main
@MainActor
struct WallpaperRendererTests {
    /// 执行全部图像测试，任一断言失败就返回非零退出码。
    static func main() throws {
        try testBlackBandAndRemainingImage()
        try testRejectsInvalidDimensions()
        try testPNGFileRoundTrip()
        try testWallpaperOptionsRoundTrip()
        try testRoundedCorners()
        try testBottomRoundedCorners()
        try WallpaperServiceTests.run()
        try SettingsModelTests.run()
        print("通过 6 项图像、10 项多屏恢复和 8 项总开关/自动更新验证；未修改系统壁纸。")
    }

    /// 创建纯白测试图，便于准确区分黑条与剩余图片。
    static func whiteImage() -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return context.makeImage()!
    }

    /// 失败时抛出具体原因，使脚本和人工执行都能看懂问题。
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw HideError.message("验证失败：\(message)") }
    }

    /// 检查黑条确实位于顶部且高度准确，没有覆盖其余图片。
    static func testBlackBandAndRemainingImage() throws {
        let result = try WallpaperRenderer.render(image: whiteImage(), width: 200, height: 120, bandHeight: 12)
        try check(result.width == 200 && result.height == 120, "输出尺寸")
        let pixels = NSBitmapImageRep(cgImage: result)
        for x in [0, 100, 199] {
            for y in 0..<120 {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw HideError.message("无法读取测试像素")
                }
                let expected: CGFloat = y < 12 ? 0 : 1
                try check(abs(color.redComponent - expected) < 0.01, "像素 \(x),\(y) 的黑白值")
            }
        }
    }

    /// 无效高度必须抛错，避免产生全黑或零尺寸壁纸。
    static func testRejectsInvalidDimensions() throws {
        for width in [0, 10] {
            var rejected = false
            do { _ = try WallpaperRenderer.render(image: whiteImage(), width: width, height: 10, bandHeight: 10) }
            catch { rejected = true }
            try check(rejected, "拒绝无效尺寸")
        }
    }

    /// 验证实际写给系统的 PNG 文件能够再次正确解码。
    static func testPNGFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hide-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try WallpaperRenderer.save(whiteImage(), to: url)
        let decoded = try WallpaperRenderer.readImage(at: url)
        try check(decoded.width == 100 && decoded.height == 100, "PNG 文件尺寸")
    }

    /// 验证壁纸缩放、裁切和背景色可以跨进程保存并恢复。
    static func testWallpaperOptionsRoundTrip() throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true, .fillColor: NSColor.black
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: options, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self], from: data
        ) as? [NSWorkspace.DesktopImageOptionKey: Any]
        try check(decoded?[.imageScaling] as? UInt == NSImageScaling.scaleProportionallyUpOrDown.rawValue, "恢复缩放方式")
        try check(decoded?[.allowClipping] as? Bool == true, "恢复裁切方式")
        try check(decoded?[.fillColor] as? NSColor == .black, "恢复背景颜色")
    }

    /// 检查原有顶部圆角行为，默认不开底部圆角，保持旧版本效果。
    static func testRoundedCorners() throws {
        for scale in [1, 2] {
            let image = try WallpaperRenderer.render(image: whiteImage(), width: 200 * scale,
                                                     height: 120 * scale, bandHeight: 12 * scale,
                                                     cornerRadius: CGFloat(20 * scale))
            let pixels = NSBitmapImageRep(cgImage: image)
            try check(pixels.colorAt(x: 1, y: 13 * scale)!.redComponent < 0.01, "左上角过渡为黑色")
            try check(pixels.colorAt(x: 200 * scale - 2, y: 13 * scale)!.redComponent < 0.01, "右上角过渡为黑色")
            try check(pixels.colorAt(x: 100 * scale, y: 14 * scale)!.redComponent > 0.99, "中间不额外加高")
            try check(pixels.colorAt(x: 0, y: 119 * scale)!.redComponent > 0.99, "底角不被圆角影响")
            let square = try WallpaperRenderer.render(image: whiteImage(), width: 200 * scale,
                                                      height: 120 * scale, bandHeight: 12 * scale)
            try check(NSBitmapImageRep(cgImage: square).colorAt(x: 0, y: 13 * scale)!.redComponent > 0.99, "关闭后恢复直角")
        }
    }

    /// 覆盖上下开关四种组合与两种缩放，底部中心应保留原图而非多一条黑边。
    static func testBottomRoundedCorners() throws {
        for scale in [1, 2] {
            for topEnabled in [false, true] {
                for bottomEnabled in [false, true] {
                    let image = try WallpaperRenderer.render(
                        image: whiteImage(), width: 200 * scale, height: 120 * scale,
                        bandHeight: 12 * scale, cornerRadius: topEnabled ? CGFloat(20 * scale) : 0,
                        bottomCornerRadius: bottomEnabled ? CGFloat(20 * scale) : 0)
                    let pixels = NSBitmapImageRep(cgImage: image)
                    for x in [0, 200 * scale - 1] {
                        let top = pixels.colorAt(x: x, y: 12 * scale)!.redComponent
                        let bottom = pixels.colorAt(x: x, y: 120 * scale - 1)!.redComponent
                        try check(topEnabled ? top < 0.01 : top > 0.99, "顶部开关独立生效")
                        try check(bottomEnabled ? bottom < 0.01 : bottom > 0.99, "底部开关独立生效")
                    }
                    try check(pixels.colorAt(x: 100 * scale, y: 120 * scale - 1)!.redComponent > 0.99,
                              "底部中心不增加黑边")
                }
            }
        }
        for invalidRadius in [CGFloat(-1), .infinity, .nan] {
            var rejected = false
            do {
                _ = try WallpaperRenderer.render(image: whiteImage(), width: 200, height: 120,
                                                  bandHeight: 12, bottomCornerRadius: invalidRadius)
            } catch { rejected = true }
            try check(rejected, "拒绝无效底部圆角半径")
        }
    }
}
