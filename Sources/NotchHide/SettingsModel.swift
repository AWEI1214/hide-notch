import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppearanceSettings
    @Published var displays: [DisplayInfo] = []
    @Published var selectedDisplayID = ""
    @Published var sourceName = "尚未读取壁纸"
    @Published var message = "开启“Hide Notch”后，设置自动生效。"
    @Published var isError = false
    @Published private(set) var isEnabled = false
    @Published var isBusy = false
    @Published var isUpdatePending = false
    private var service: WallpaperService?
    private var sources: [String: URL] = [:]
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
    var selectedDisplay: DisplayInfo? { targetDisplays.first(where: { $0.id == selectedDisplayID }) }
    var canEnable: Bool { service != nil && !isBusy && !isUpdatePending && !targetDisplays.isEmpty }
    // 即使壁纸无法读取，已经开启的效果仍可尝试关闭。
    var canToggle: Bool { service != nil && !isBusy && (isEnabled || canEnable) }
    var primaryDescription: String {
        displays.contains(where: \.isBuiltIn) ? "默认处理内置显示器" : "默认处理系统主显示器"
    }

    /// 显示器拔插或切换桌面后更新壁纸信息，离线屏幕的恢复记录交由服务继续保留。
    func refreshDisplays() {
        guard let service else { return }
        displays = service.displays()
        if !targetDisplays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = targetDisplays.first?.id ?? ""
        }
        isEnabled = service.hasBackup
        refreshSource()
    }

    /// 保存设置并合并连续拖动；开启时自动应用，关闭时仅更新壁纸信息。
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

    /// 每块屏幕读取自己的原图或用户为它选择的图片，只读取文件名，不解码图片或生成效果。
    func refreshSource() {
        defer { isUpdatePending = false }
        sourceName = "尚未读取壁纸"
        guard let service, let display = selectedDisplay else {
            message = "未检测到可用显示器，请连接屏幕后重试。"
            isError = true
            return
        }
        do {
            let url = try sources[display.id] ?? service.currentSource(for: display)
            sourceName = url.lastPathComponent
            message = isEnabled
                ? "已开启。调整设置后自动对 \(targetDisplays.count) 个显示器生效。"
                : "已关闭。设置已保存，开启“Hide Notch”后生效。"
            isError = false
        } catch { report(error) }
    }

    /// 选图只影响当前屏幕；开启时立即生效，关闭时只更新壁纸信息。
    func chooseImage() {
        guard let display = selectedDisplay else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "为\(display.name)选择壁纸"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectImage(url, for: display.id)
    }

    /// 接收文件选择结果，刷新壁纸信息后按总开关状态提交，便于验证选图行为。
    func selectImage(_ url: URL, for displayID: String) {
        sources[displayID] = url
        refreshSource()
        if isEnabled { applyEffects() }
    }

    /// 丢弃尚未应用的选图；开启时将当前壁纸重新生成效果，关闭时保存选择。
    func useCurrentImage() {
        sources.removeValue(forKey: selectedDisplayID)
        refreshSource()
        if isEnabled { applyEffects() }
    }

    /// 总开关立即执行开启或关闭；失败时根据剩余记录保留状态，允许用户再次关闭。
    func setEnabled(_ enabled: Bool) {
        guard canToggle, enabled != isEnabled else { return }
        if enabled { applyEffects() }
        else { disableEffects() }
    }

    /// 开启和自动更新共用提交逻辑，成功后清除临时选图并更新界面。
    private func applyEffects() {
        guard let service, canEnable else { return }
        updateTask?.cancel()
        isBusy = true
        defer { isBusy = false; isEnabled = service.hasBackup }
        do {
            let result = try service.apply(sources: sources, settings: settings)
            // 已应用的图片来源由服务保存，界面只保留未提交屏幕的选图。
            for display in targetDisplays { sources.removeValue(forKey: display.id) }
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
            sources.removeAll()
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
