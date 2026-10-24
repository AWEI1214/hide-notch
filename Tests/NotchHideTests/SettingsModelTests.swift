import AppKit

@MainActor
struct SettingsModelTests {
    /// 覆盖总开关的正常循环、升级、换图、离线及失败重试，全部使用虚拟屏幕。
    static func run() throws {
        try testToggleAndRestart()
        try testChangedWallpaperWhenDisabling()
        try testPartialFailureAndRetry()
        try testOfflineDisplayAndRetry()
        try testDisableWithBrokenPreview()
        try testAutomaticUpdates()
        try testDisableCancelsPendingUpdate()
        try testImageSelectionUpdates()
    }

    /// 为每个场景隔离壁纸文件、恢复记录及偏好，防止测试改动真实应用状态。
    static func fixture(_ body: (URL, FakeDesktop, WallpaperService, SettingsModel, UserDefaults) throws -> Void) throws {
        try WallpaperServiceTests.fixture { directory, desktop, _ in
            let suite = "NotchHide.ToggleTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            let model = SettingsModel(defaults: defaults, service: service)
            try body(directory, desktop, service, model, defaults)
        }
    }

    /// 首次默认关闭，开关即时生效，重启从恢复记录判断状态而不重新修改桌面。
    static func testToggleAndRestart() throws {
        try fixture { directory, desktop, _, model, defaults in
            let originals = desktop.urls
            try WallpaperRendererTests.check(!model.isEnabled && model.canToggle, "初始开关关闭")
            try WallpaperRendererTests.check(desktop.writes.isEmpty, "启动仅壁纸信息，不修改壁纸")
            model.setEnabled(true)
            try WallpaperRendererTests.check(model.isEnabled && !model.isError, "开启立即应用")
            desktop.writes = []
            let service = try WallpaperService(desktop: desktop, directory: directory.appendingPathComponent("data"))
            let restarted = SettingsModel(defaults: defaults, service: service)
            try WallpaperRendererTests.check(restarted.isEnabled && desktop.writes.isEmpty, "重启继承已开启状态")
            restarted.setEnabled(false)
            try WallpaperRendererTests.check(!restarted.isEnabled && !restarted.isError && desktop.urls == originals, "关闭立即还原")
            restarted.setEnabled(true)
            restarted.setEnabled(false)
            try WallpaperRendererTests.check(desktop.urls == originals && !restarted.isEnabled, "重复开关不叠加效果")
        }
    }

    /// 用户在系统中换图后关闭，只清除旧效果记录，不覆盖新壁纸。
    static func testChangedWallpaperWhenDisabling() throws {
        try fixture { _, desktop, service, model, _ in
            model.setEnabled(true)
            let changed = desktop.urls["external"]!
            desktop.urls["internal"] = changed
            desktop.writes = []
            model.setEnabled(false)
            try WallpaperRendererTests.check(!model.isEnabled && !model.isError && !service.hasBackup, "换图后可以关闭")
            try WallpaperRendererTests.check(desktop.writes.isEmpty && desktop.urls["internal"] == changed, "保留后来换的壁纸")
        }
    }

    /// 部分开启和关闭失败时不能误报已关闭，排除故障后同一开关可以继续操作。
    static func testPartialFailureAndRetry() throws {
        try fixture { _, desktop, _, model, _ in
            let originals = desktop.urls
            model.settings.includeOtherDisplays = true
            model.refreshDisplays()
            desktop.failDisplay = "external"
            model.setEnabled(true)
            try WallpaperRendererTests.check(model.isEnabled && model.isError && model.canToggle, "部分开启保留关闭入口")
            model.setEnabled(false)
            try WallpaperRendererTests.check(model.isEnabled && model.isError, "关闭失败不显示已关闭")
            desktop.failDisplay = nil
            model.setEnabled(false)
            try WallpaperRendererTests.check(!model.isEnabled && !model.isError && desktop.urls == originals, "关闭失败后可以重试")
        }
    }

    /// 离线屏幕的效果尚未撤销时保留开启状态，重新连接后关闭全部屏幕。
    static func testOfflineDisplayAndRetry() throws {
        try fixture { _, desktop, _, model, _ in
            let originals = desktop.urls
            model.settings.includeOtherDisplays = true
            model.refreshDisplays()
            model.setEnabled(true)
            let external = desktop.connected.removeLast()
            model.setEnabled(false)
            try WallpaperRendererTests.check(model.isEnabled && model.isError, "离线屏幕不丢失待关闭状态")
            desktop.connected.append(external)
            model.setEnabled(false)
            try WallpaperRendererTests.check(!model.isEnabled && desktop.urls == originals, "重连后可关闭")
        }
    }

    /// 原图丢失时即使壁纸信息不可用也保留关闭入口，补回文件后能够正常关闭。
    static func testDisableWithBrokenPreview() throws {
        try fixture { _, desktop, _, model, _ in
            let original = desktop.urls["internal"]!
            model.setEnabled(true)
            try FileManager.default.removeItem(at: original)
            model.refreshDisplays()
            try WallpaperRendererTests.check(model.canToggle, "无壁纸信息也可尝试关闭")
            model.setEnabled(false)
            try WallpaperRendererTests.check(model.isEnabled && model.isError, "原图丢失时状态不假成功")
            try WallpaperRenderer.save(WallpaperRendererTests.whiteImage(), to: original)
            model.setEnabled(false)
            try WallpaperRendererTests.check(!model.isEnabled && !model.isError, "补回原图后关闭成功")
        }
    }
    /// 关闭时只壁纸信息，开启后连续修改合并为一次提交，副屏关闭也会自动还原。
    static func testAutomaticUpdates() throws {
        try fixture { _, desktop, _, model, _ in
            let originals = desktop.urls
            model.settings.cornerRadius = 28
            model.settingsChanged()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            try WallpaperRendererTests.check(desktop.writes.isEmpty && !model.isUpdatePending, "关闭时调整不写入桌面")
            model.setEnabled(true)
            desktop.writes = []
            for radius in [30.0, 35.0, 40.0] {
                model.settings.cornerRadius = radius
                model.settingsChanged()
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            try WallpaperRendererTests.check(desktop.writes == ["internal"] && !model.isError, "连续拖动只提交一次")
            model.settings.includeOtherDisplays = true
            model.settingsChanged()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            try WallpaperRendererTests.check(desktop.urls["external"] != originals["external"], "副屏开关自动生效")
            model.settings.includeOtherDisplays = false
            model.settingsChanged()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            try WallpaperRendererTests.check(desktop.urls["external"] == originals["external"], "副屏关闭自动还原")
            desktop.writes = []
            model.refreshDisplays()
            model.refreshSource()
            try WallpaperRendererTests.check(desktop.writes.isEmpty, "刷新或切换壁纸信息不自动提交")
        }
    }

    /// 关闭总开关会取消等待中的自动更新，避免效果被延迟任务重新开启。
    static func testDisableCancelsPendingUpdate() throws {
        try fixture { _, desktop, _, model, _ in
            let originals = desktop.urls
            model.setEnabled(true)
            model.settings.extraHeight = 12
            model.settingsChanged()
            model.setEnabled(false)
            desktop.writes = []
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            try WallpaperRendererTests.check(!model.isEnabled && desktop.writes.isEmpty && desktop.urls == originals,
                                             "关闭后延迟任务不能重新应用")
        }
    }

    /// 选图与参数遵循相同规则：关闭时壁纸信息，开启时立即使用新的图片。
    static func testImageSelectionUpdates() throws {
        try fixture { _, desktop, service, model, _ in
            let original = desktop.urls["internal"]!
            let other = desktop.urls["external"]!
            model.selectImage(other, for: "internal")
            try WallpaperRendererTests.check(desktop.writes.isEmpty, "关闭时选图只壁纸信息")
            model.setEnabled(true)
            try WallpaperRendererTests.check(try service.currentSource(for: desktop.connected[0]) == other, "开启采用壁纸信息选图")
            desktop.writes = []
            model.selectImage(original, for: "internal")
            try WallpaperRendererTests.check(desktop.writes == ["internal"], "开启时选图自动提交")
            try WallpaperRendererTests.check(try service.currentSource(for: desktop.connected[0]) == original, "自动提交新图来源")
        }
    }

}
