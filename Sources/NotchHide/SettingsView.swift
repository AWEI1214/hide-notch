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
    }

    /// 总开关保持可操作，其余设置在关闭状态统一禁用，沿用系统的灰显样式。
    private var settingsPanel: some View {
        Form {
            Section {
                Toggle("Hide Notch", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .disabled(!model.canToggle)
                    .accessibilityIdentifier("hideNotchToggle")
                Text(model.isEnabled ? "已开启，调整设置自动生效。" : "已关闭，开启后可调整下方设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Section {
                    Toggle("同时应用到副屏", isOn: $model.settings.includeOtherDisplays)
                        .toggleStyle(.switch)
                    Text("默认只处理内置显示器，开启后应用到全部屏幕")
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
            }
            .disabled(!model.isEnabled)
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }
}

