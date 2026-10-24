import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var model: SettingsModel!

    /// 保持代理存活，应用常驻菜单栏且不占用 Dock。
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// 启动只读取设置和生成壁纸信息，并监听屏幕或桌面的变化。
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = SettingsModel()
        buildMenu()
        buildWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        showWindow()
    }

    /// 用统一的Hide Notch开关替代恢复入口，菜单与设置窗口共用同一状态。
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for (title, action, key) in [
            ("关于 Hide Notch", #selector(showAbout), ""),
            ("设置…", #selector(showWindow), ","),
            ("Hide Notch", #selector(toggleEnabled), "")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Hide Notch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    /// 同时配置菜单栏图标和应用主菜单，窗口内也能使用 ⌘, 与 ⌘Q。
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Hide Notch")
        statusItem.button?.toolTip = "Hide Notch"
        statusItem.menu = makeMenu()
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = makeMenu()
        main.addItem(applicationItem)
        NSApp.mainMenu = main
    }

    /// 展开菜单时更新勾选状态；壁纸信息出错也不阻止关闭已有的效果。
    func menuWillOpen(_ menu: NSMenu) {
        model.refreshDisplays()
        for item in menu.items where item.action == #selector(toggleEnabled) {
            item.state = model.isEnabled ? .on : .off
            item.isEnabled = model.canToggle
        }
    }

    /// 使用系统标题栏和原生分组表单，适配 macOS 27 外观并允许窗口缩放。
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Hide Notch"
        window.subtitle = "设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 560)
        let content = NSHostingView(rootView: SettingsView(model: model))
        // 表单自身可滚动，不让它的理想高度反过来撑大整个窗口。
        content.sizingOptions = []
        window.contentView = content
        window.setFrameAutosaveName("NotchHideCompactSettings")
        window.center()
    }

    /// 设置窗口重新打开时读取当前壁纸并置于前台，让系统换图后的壁纸信息及时更新。
    @objc private func showWindow() {
        model.refreshDisplays()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Finder 再次打开应用时唤起现有窗口，避免看起来没有启动。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// 显示器拔插和桌面切换只刷新界面，不在用户不知情时重新应用壁纸。
    @objc private func screensChanged(_ notification: Notification) { model.refreshDisplays() }

    /// 菜单开关复用设置页逻辑；失败时打开窗口展示原因，保留操作后的提示。
    @objc private func toggleEnabled() {
        model.setEnabled(!model.isEnabled)
        if model.isError {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 使用系统关于面板展示应用名称、图标和构建版本。
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Hide Notch"])
    }

    /// 退出保留已应用的壁纸与恢复记录，下次启动仍能恢复。
    @objc private func quit() { NSApp.terminate(nil) }
}
