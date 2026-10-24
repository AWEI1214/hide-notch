import AppKit
import Combine

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppearanceSettings
    @Published var displays: [DisplayInfo] = []
    @Published var message = "开启“Hide Notch”后，设置自动生效。"
    @Published var isError = false
    @Published private(set) var isEnabled = false
    @Published var isBusy = false
    @Published var isUpdatePending = false
    private var service: WallpaperService?
    private var updateTask: Task<Void, Never>?
    private let defaults: UserDefaults

    /// 读取用户偏好和恢复记录；启动只读取设置，不修改任何屏幕。
    init(defaults: UserDefaults = .standard, service: WallpaperService? = nil) {
        self.defaults = defaults
        defaults.register(defaults: ["roundedCorners": true, "cornerRadius": 18.0])
        settings = AppearanceSettings(
            includeOtherDisplays: defaults.bool(forKey: "includeOtherDisplays"),
            roundedCorners: defaults.bool(forKey: "roundedCorners"),
            cornerRadius: min(48, max(4, defaults.double(forKey: "cornerRadius"))),
            extraHeight: min(24, max(0, defaults.double(forKey: "extraHeight"))),
            bottomRoundedCorners: defaults.bool(forKey: "bottomRoundedCorners")
        )
        do { self.service = try service ?? WallpaperService(); refreshDisplays() }
        catch { report(error) }
    }

    var targetDisplays: [DisplayInfo] {
        WallpaperService.targets(in: displays, includeOtherDisplays: settings.includeOtherDisplays)
    }
    var canEnable: Bool { service != nil && !isBusy && !isUpdatePending && !targetDisplays.isEmpty }
    // 即使壁纸无法读取，已经开启的效果仍可尝试关闭。
    var canToggle: Bool { service != nil && !isBusy && (isEnabled || canEnable) }

    /// 只刷新显示器和运行状态；启动、拔插或切换桌面时不主动修改壁纸。
    func refreshDisplays() {
        guard let service else { return }
        displays = service.displays()
        isEnabled = service.hasBackup
        isUpdatePending = false
        if targetDisplays.isEmpty {
            message = "未检测到可用显示器，请连接屏幕后重试。"
            isError = true
        } else {
            message = isEnabled ? "已开启，调整设置自动生效。" : "已关闭，开启后可调整设置。"
            isError = false
        }
    }

    /// 保存设置并合并连续拖动；开启时自动应用，关闭时只保存参数。
    func settingsChanged() {
        defaults.set(settings.includeOtherDisplays, forKey: "includeOtherDisplays")
        defaults.set(settings.roundedCorners, forKey: "roundedCorners")
        defaults.set(settings.bottomRoundedCorners, forKey: "bottomRoundedCorners")
        defaults.set(settings.cornerRadius, forKey: "cornerRadius")
        defaults.set(settings.extraHeight, forKey: "extraHeight")
        updateTask?.cancel()
        // 停止调整 300 毫秒后才生成图片，关闭状态只保存参数。
        isUpdatePending = true
        updateTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self else { return }
            self.refreshDisplays()
            if self.isEnabled { self.applyEffects() }
        }
    }

    /// 总开关立即执行开启或关闭；失败时根据剩余记录保留状态，允许用户再次关闭。
    func setEnabled(_ enabled: Bool) {
        guard canToggle, enabled != isEnabled else { return }
        if enabled { applyEffects() }
        else { disableEffects() }
    }

    /// 自动读取各屏幕当前壁纸并应用设置，已处理的壁纸由服务还原来源，避免叠加效果。
    private func applyEffects() {
        guard let service, canEnable else { return }
        updateTask?.cancel()
        isBusy = true
        defer { isBusy = false; isEnabled = service.hasBackup }
        do {
            let result = try service.apply(sources: [:], settings: settings)
            refreshDisplays()
            message = result
            isError = false
        } catch { report(error) }
    }

    /// 关闭时撤销已连接屏幕的效果；离线或失败记录保留，避免界面误报已全部关闭。
    private func disableEffects() {
        guard let service else { return }
        updateTask?.cancel()
        isBusy = true
        defer { isBusy = false; isUpdatePending = false; isEnabled = service.hasBackup }
        do {
            let result = try service.disable()
            refreshDisplays()
            message = result
            isError = false
        } catch { report(error) }
    }

    /// 将系统错误显示在设置页，避免把未成功的操作显示成已完成。
    private func report(_ error: Error) {
        message = error.localizedDescription
        isError = true
    }
}
