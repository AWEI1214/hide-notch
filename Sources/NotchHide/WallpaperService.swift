import AppKit

/// 每块屏幕分别保存原壁纸与历史生成文件，断开显示器也不丢弃恢复记录。
struct WallpaperBackup: Codable {
    let displayID: String
    let originalURL: URL
    let optionsData: Data
    var generatedURL: URL
    var previousGeneratedURLs: [URL]
    var sourceURL: URL? = nil

    /// 判断当前图片是否属于这份记录；用于复用原图及避免恢复时覆盖用户新选的壁纸。
    func accepts(_ url: URL) -> Bool {
        url == originalURL || url == generatedURL || previousGeneratedURLs.contains(url)
    }
}

@MainActor
final class WallpaperService {
    private let desktop: any DesktopBackend
    private let directory: URL
    private let backupURL: URL
    private var backups: [String: WallpaperBackup] = [:]

    /// 兼容 0.1 版的单屏恢复记录，后续写入时升级为按显示器保存的格式。
    init(desktop: (any DesktopBackend)? = nil, directory: URL? = nil) throws {
        self.desktop = desktop ?? SystemDesktopBackend()
        self.directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("NotchHide", isDirectory: true)
        backupURL = self.directory.appendingPathComponent("restore.json")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let data = try Data(contentsOf: backupURL)
            if let multiple = try? JSONDecoder().decode([String: WallpaperBackup].self, from: data) {
                backups = multiple
            } else {
                let legacy = try JSONDecoder().decode(WallpaperBackup.self, from: data)
                backups[legacy.displayID] = legacy
            }
        }
    }

    var hasBackup: Bool { !backups.isEmpty }
    var backupCount: Int { backups.count }

    /// 默认处理内置屏；合盖或台式机环境下使用系统主屏，开启副屏后处理全部独立屏幕。
    static func targets(in displays: [DisplayInfo], includeOtherDisplays: Bool) -> [DisplayInfo] {
        if includeOtherDisplays { return displays }
        guard let primary = displays.first(where: \.isBuiltIn) ?? displays.first else { return [] }
        return [primary]
    }

    /// 返回最新显示器列表，供设置界面更新屏幕选择器。
    func displays() -> [DisplayInfo] { desktop.displays() }

    /// 读取已处理屏幕的图片来源时从原壁纸开始，避免重复叠加黑条或圆角。
    func currentSource(for display: DisplayInfo) throws -> URL {
        let current = try desktop.wallpaperURL(for: display.id)
        if let backup = backups[display.id], backup.accepts(current) { return backup.sourceURL ?? backup.originalURL }
        return current
    }

    /// 为指定屏幕生成实际壁纸，圆角和菜单栏高度都按该屏缩放转换为像素。
    func makeWallpaper(source: URL, display: DisplayInfo, settings: AppearanceSettings) throws -> CGImage {
        try WallpaperRenderer.render(
            image: WallpaperRenderer.readImage(at: source),
            width: display.pixelWidth, height: display.pixelHeight,
            bandHeight: Int(((display.menuBarHeight + settings.extraHeight) * display.scale).rounded(.up)),
            cornerRadius: settings.roundedCorners ? settings.cornerRadius * display.scale : 0,
            bottomCornerRadius: settings.bottomRoundedCorners ? settings.cornerRadius * display.scale : 0
        )
    }

    /// 原子写入整份恢复记录，任何显示器写入失败都仍可单独恢复。
    private func persist(_ records: [String: WallpaperBackup]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: backupURL, options: .atomic)
        backups = records
    }

    /// 还原系统壁纸选项；无法解码时明确报错，不偷偷丢掉原来的缩放设置。
    private func originalOptions(_ backup: WallpaperBackup) throws -> [NSWorkspace.DesktopImageOptionKey: Any] {
        guard let options = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self], from: backup.optionsData
        ) as? [NSWorkspace.DesktopImageOptionKey: Any] else {
            throw HideError.message("无法读取原壁纸显示选项。")
        }
        return options
    }

    /// 恢复前先验证当前桌面和原文件，用户改过壁纸或切到其他桌面时不直接覆盖。
    private func validateRestore(_ backup: WallpaperBackup) throws {
        guard backup.accepts(try desktop.wallpaperURL(for: backup.displayID)) else {
            throw HideError.message("当前壁纸已变化，请切回此前应用效果的桌面再恢复。")
        }
        guard FileManager.default.fileExists(atPath: backup.originalURL.path) else {
            throw HideError.message("原壁纸已被移动或删除：\(backup.originalURL.path)")
        }
    }

    /// 先完成所有屏幕的检查和图片生成，再保存恢复记录并提交系统设置。
    /// 用户已更换壁纸时以当前图片重新建立恢复记录，不要求先换回旧图。
    /// 关闭副屏选项后再次应用，会恢复已连接副屏；离线屏幕的记录继续保留。
    func apply(sources: [String: URL], settings: AppearanceSettings) throws -> String {
        let allDisplays = desktop.displays()
        let selected = Self.targets(in: allDisplays, includeOtherDisplays: settings.includeOtherDisplays)
        guard !selected.isEmpty else { throw HideError.message("没有可用的显示器。") }
        let selectedIDs = Set(selected.map(\.id))
        let toRestore = allDisplays.filter { !selectedIDs.contains($0.id) && backups[$0.id] != nil }
        var records = backups
        var plans: [(DisplayInfo, URL)] = []
        var generatedFiles: [URL] = []
        var journalSaved = false
        // 预检查失败时，新图片还没有交给系统，可以安全清理；提交后保留以供恢复。
        defer {
            if !journalSaved { for url in generatedFiles { try? FileManager.default.removeItem(at: url) } }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for display in selected {
            do {
                let current = try desktop.wallpaperURL(for: display.id)
                // 旧记录只适用于原先那张壁纸。用户主动应用到新图时，重新保存新图与显示选项。
                let saved = backups[display.id]
                let old = saved.flatMap { $0.accepts(current) ? $0 : nil }
                if let old {
                    guard FileManager.default.fileExists(atPath: old.originalURL.path) else {
                        throw HideError.message("原壁纸文件已丢失，请先放回原位置后重试。")
                    }
                } else {
                    // 动态壁纸包含额外系统配置，当前版本不承诺将它完整恢复。
                    do { _ = try WallpaperRenderer.readImage(at: current) }
                    catch { throw HideError.message("请先在系统设置中为此屏幕选择 PNG/JPEG 静态壁纸，以便恢复。") }
                }
                let source = sources[display.id] ?? old?.sourceURL ?? old?.originalURL ?? current
                let image = try makeWallpaper(source: source, display: display, settings: settings)
                let generated = directory.appendingPathComponent("wallpaper-\(UUID().uuidString).png")
                generatedFiles.append(generated)
                try WallpaperRenderer.save(image, to: generated)
                let optionsData = try old?.optionsData ?? NSKeyedArchiver.archivedData(
                    withRootObject: desktop.options(for: display.id), requiringSecureCoding: true
                )
                records[display.id] = WallpaperBackup(
                    displayID: display.id, originalURL: old?.originalURL ?? current,
                    optionsData: optionsData, generatedURL: generated,
                    previousGeneratedURLs: (old?.previousGeneratedURLs ?? []) + (old.map { [$0.generatedURL] } ?? []),
                    sourceURL: source
                )
                plans.append((display, generated))
            } catch {
                throw HideError.message("\(display.name)：\(error.localizedDescription) 尚未修改任何屏幕。")
            }
        }
        for display in toRestore {
            do {
                try validateRestore(backups[display.id]!)
                _ = try originalOptions(backups[display.id]!)
            } catch {
                throw HideError.message("\(display.name)：\(error.localizedDescription) 尚未修改任何屏幕。")
            }
        }
        try persist(records)
        journalSaved = true
        var completed = 0
        for (display, url) in plans {
            do {
                try desktop.setWallpaper(url, for: display.id, options: [
                    .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: false
                ])
                completed += 1
            } catch {
                throw HideError.message("已提交 \(completed) 个屏幕；\(display.name) 应用失败：\(error.localizedDescription)。记录已保留，可关闭“Hide Notch”撤销效果。")
            }
        }
        for display in toRestore {
            do { try restoreOne(display.id) }
            catch { throw HideError.message("主屏效果已提交，但 \(display.name) 恢复失败：\(error.localizedDescription)") }
        }
        let offline = backups.keys.filter { id in !allDisplays.contains(where: { $0.id == id }) }.count
        var message = "已向系统提交 \(completed) 个显示器的壁纸设置。"
        if !toRestore.isEmpty { message += "已恢复 \(toRestore.count) 个副屏。" }
        if offline > 0 { message += "\(offline) 个离线屏幕的恢复记录已保留。" }
        return message
    }

    /// 单屏恢复成功后才移除对应记录，其他屏幕失败不影响它的恢复结果。
    private func restoreOne(_ id: String) throws {
        guard let record = backups[id] else { return }
        try validateRestore(record)
        try desktop.setWallpaper(record.originalURL, for: id, options: originalOptions(record))
        var remaining = backups
        remaining.removeValue(forKey: id)
        try persist(remaining)
    }

    /// 关闭所有已连接屏幕的效果；手动换过的壁纸保持原样，离线或失败记录留待重试。
    func disable() throws -> String {
        guard hasBackup else { return "Hide Notch已关闭。" }
        let connected = desktop.displays()
        var failures: [String] = []
        var restored = 0
        var unchanged = 0
        for display in connected where backups[display.id] != nil {
            do {
                let record = backups[display.id]!
                if !record.accepts(try desktop.wallpaperURL(for: display.id)) {
                    // 新壁纸已经没有本工具的效果，只清理旧记录，绝不把用户选图换回去。
                    var remaining = backups
                    remaining.removeValue(forKey: display.id)
                    try persist(remaining)
                    unchanged += 1
                } else {
                    try restoreOne(display.id)
                    restored += 1
                }
            }
            catch { failures.append("\(display.name)：\(error.localizedDescription)") }
        }
        let offline = backups.keys.filter { id in !connected.contains(where: { $0.id == id }) }.count
        if offline > 0 { failures.append("另有 \(offline) 个显示器未连接，请连接后再次关闭开关。") }
        if !failures.isEmpty {
            throw HideError.message("尚未完全关闭，已撤销 \(restored) 个显示器的效果。" + failures.joined(separator: "\n"))
        }
        return "Hide Notch已关闭。已还原 \(restored) 个显示器的壁纸。" + (unchanged > 0 ? "\(unchanged) 个显示器保留你后来选择的壁纸。" : "")
    }
}
