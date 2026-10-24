import SwiftUI

/// 使用系统分组表单、开关与按钮，跟随 macOS 的原生外观和辅助功能设置。
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            settingsPanel
            Divider()
            HStack(spacing: 18) {
                Label(model.message, systemImage: model.isError ? "exclamationmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("operationStatus")
            }
            .padding(20)
            .background(.bar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.settings) { _ in model.settingsChanged() }
        .onChange(of: model.selectedDisplayID) { _ in model.refreshSource() }
    }

    private var settingsPanel: some View {
        Form {
            Section {
                Toggle("Hide Notch", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .disabled(!model.canToggle)
                    .accessibilityIdentifier("hideNotchToggle")
                Text(model.isEnabled ? "已开启，调整设置自动生效。" : "已关闭，设置将在下次开启时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("同时应用到副屏", isOn: $model.settings.includeOtherDisplays)
                    .toggleStyle(.switch)
                Text("\(model.primaryDescription)。开启后，各屏幕保留自己的壁纸。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("已连接", value: "\(model.displays.count) 个显示器")
                if !model.targetDisplays.isEmpty {
                    Picker("壁纸所属显示器", selection: $model.selectedDisplayID) {
                        ForEach(model.targetDisplays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                }
                LabeledContent("壁纸") {
                    Text(model.sourceName).lineLimit(1).truncationMode(.middle).help(model.sourceName)
                }
                HStack {
                    Button("选择壁纸…", action: model.chooseImage)
                    Button("使用当前壁纸", action: model.useCurrentImage)
                }
                .disabled(model.selectedDisplay == nil || model.isBusy)
                Text("仅支持 PNG / JPEG 静态壁纸。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("功能开启时，关闭此项会自动还原已连接副屏。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("显示器", systemImage: "display.2")
            }
            Section {
                Toggle("顶部圆角", isOn: $model.settings.roundedCorners)
                    .toggleStyle(.switch)
                Toggle("底部圆角", isOn: $model.settings.bottomRoundedCorners)
                    .toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("圆角半径", value: "\(Int(model.settings.cornerRadius)) pt")
                        .monospacedDigit()
                    Slider(value: $model.settings.cornerRadius, in: 4...48, step: 1)
                        .accessibilityLabel("圆角半径")
                }
                .disabled(!model.settings.roundedCorners && !model.settings.bottomRoundedCorners)
                Text("顶部与底部独立开关，共用圆角半径。同时开启时，壁纸四角均呈圆角。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("边缘", systemImage: "rectangle.roundedtop")
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("额外加高", value: "\(Int(model.settings.extraHeight)) pt")
                        .monospacedDigit()
                    Slider(value: $model.settings.extraHeight, in: 0...24, step: 1)
                        .accessibilityLabel("菜单栏额外加高")
                }
                Text("自动适配每块屏幕的菜单栏高度，可额外增加黑色区域。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("菜单栏", systemImage: "menubar.rectangle")
            }
            Section {
                Text("开启后设置自动生效，滑块停止拖动后更新。退出软件会保留效果。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("仅处理各屏幕的当前桌面，暂不自动同步多个桌面。菜单栏的实际材质由系统决定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }
}

