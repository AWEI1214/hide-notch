import AppKit
import ImageIO

/// 用原生绘图生成应用图标：黑色菜单栏与蓝紫壁纸，透明边缘适配系统图标布局。
func renderIcon(size: Int, to url: URL) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.2))
    context.setFillColor(CGColor(red: 0.85, green: 0.91, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 180, cornerHeight: 180, transform: nil))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 180, cornerHeight: 180, transform: nil))
    context.clip()
    let colors = [CGColor(red: 0.93, green: 0.97, blue: 1, alpha: 1), CGColor(red: 0.48, green: 0.64, blue: 0.94, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 850, y: 100), options: [])
    context.restoreGState()
    let screen = CGRect(x: 180, y: 236, width: 664, height: 552)
    context.setFillColor(CGColor(gray: 0.035, alpha: 1))
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 58, cornerHeight: 58, transform: nil))
    context.fillPath()
    context.saveGState()
    let wallpaper = CGRect(x: 200, y: 256, width: 624, height: 444)
    context.addPath(CGPath(roundedRect: wallpaper, cornerWidth: 36, cornerHeight: 36, transform: nil))
    context.clip()
    let wallpaperColors = [CGColor(red: 0.25, green: 0.65, blue: 1, alpha: 1), CGColor(red: 0.49, green: 0.24, blue: 0.9, alpha: 1)]
    let wallpaperGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: wallpaperColors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(wallpaperGradient, start: CGPoint(x: 220, y: 700), end: CGPoint(x: 780, y: 260), options: [])
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 180, y: 250))
    wave.addLine(to: CGPoint(x: 180, y: 410))
    wave.addCurve(to: CGPoint(x: 850, y: 520), control1: CGPoint(x: 380, y: 760), control2: CGPoint(x: 610, y: 200))
    wave.addLine(to: CGPoint(x: 850, y: 250))
    wave.closeSubpath()
    context.setFillColor(CGColor(red: 0.75, green: 0.68, blue: 1, alpha: 0.45))
    context.addPath(wave)
    context.fillPath()
    context.restoreGState()
    context.setFillColor(CGColor(gray: 1, alpha: 0.8))
    for x in [226, 252, 278] { context.fillEllipse(in: CGRect(x: x, y: 735, width: 10, height: 10)) }
    context.fill(CGRect(x: 730, y: 735, width: 56, height: 8))
    let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { throw NSError(domain: "Icon", code: 1) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try renderIcon(size: size, to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderIcon(size: size * 2, to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
