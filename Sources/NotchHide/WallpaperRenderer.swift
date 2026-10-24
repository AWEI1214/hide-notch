import AppKit
import ImageIO

enum HideError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

enum WallpaperRenderer {
    /// 只读取单帧 PNG/JPEG，避免把动态壁纸误当作普通图片处理。
    static func readImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HideError.message("请选择一张静态 PNG 或 JPEG 壁纸。暂不支持 HEIC 动态壁纸、视频或图片文件夹。")
        }
        // NSImage 会处理 JPEG 的旋转方向，防止手机照片横竖颠倒。
        guard let oriented = NSImage(contentsOf: url),
              let corrected = oriented.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        return corrected
    }

    /// 按屏幕比例铺满图片，分别控制黑条下方的顶角和屏幕底角；半径为零时保留直角。
    static func render(image: CGImage, width: Int, height: Int, bandHeight: Int,
                       cornerRadius: CGFloat = 0, bottomCornerRadius: CGFloat = 0) throws -> CGImage {
        guard width > 0, height > 0, bandHeight > 0, bandHeight < height,
              cornerRadius.isFinite, cornerRadius >= 0,
              bottomCornerRadius.isFinite, bottomCornerRadius >= 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw HideError.message("无法生成壁纸，请检查屏幕尺寸和黑条高度。")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        let top = CGFloat(height - bandHeight)
        // 上下半径均不超过可见高度的一半，极端尺寸下也不会互相重叠。
        let radius = min(cornerRadius, CGFloat(width) / 2, top / 2)
        let bottomRadius = min(bottomCornerRadius, CGFloat(width) / 2, top / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bottomRadius, y: 0))
        path.addLine(to: CGPoint(x: CGFloat(width) - bottomRadius, y: 0))
        if bottomRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: width, y: 0),
                        tangent2End: CGPoint(x: CGFloat(width), y: bottomRadius), radius: bottomRadius)
        }
        if radius > 0 {
            path.addLine(to: CGPoint(x: CGFloat(width), y: top - radius))
            path.addArc(tangent1End: CGPoint(x: CGFloat(width), y: top),
                        tangent2End: CGPoint(x: CGFloat(width) - radius, y: top), radius: radius)
            path.addLine(to: CGPoint(x: radius, y: top))
            path.addArc(tangent1End: CGPoint(x: 0, y: top),
                        tangent2End: CGPoint(x: 0, y: top - radius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: CGFloat(width), y: top))
            path.addLine(to: CGPoint(x: 0, y: top))
        }
        path.addLine(to: CGPoint(x: 0, y: bottomRadius))
        if bottomRadius > 0 {
            path.addArc(tangent1End: .zero,
                        tangent2End: CGPoint(x: bottomRadius, y: 0), radius: bottomRadius)
        }
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        ))
        context.restoreGState()
        guard let result = context.makeImage() else {
            throw HideError.message("生成壁纸失败。")
        }
        return result
    }

    /// 将新壁纸写到独立文件，不修改用户的原始图片。
    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw HideError.message("无法创建壁纸文件。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HideError.message("保存壁纸失败，请检查磁盘空间。")
        }
    }
}
