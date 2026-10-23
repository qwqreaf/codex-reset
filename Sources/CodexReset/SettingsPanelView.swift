import SwiftUI

/// 独立设置窗口内容（右上角齿轮打开，避免在面板内做遮罩）
struct SettingsPanelView: View {
    @EnvironmentObject var model: AppModel
    /// 是否在概览中显示「全部对话」模块
    @AppStorage("showAllThreads") private var showAllThreads = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.72, green: 0.33, blue: 0.10))
                Text(L("设置", "Settings"))
                    .font(.headline)
            }
            settingsCard
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(red: 0.95, green: 0.945, blue: 0.93))
        .preferredColorScheme(.light)
    }

    /// 语言选择绑定到 AppModel.language（切换后经 objectWillChange 刷新全界面）
    private var languageBinding: Binding<String> {
        Binding(
            get: { self.model.language },
            set: { self.model.language = $0 }
        )
    }

    /// 白色圆角卡片，装设置项
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 显示全部对话
            HStack(spacing: 10) {
                Text(L("显示全部对话", "Show all chats"))
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: $showAllThreads)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .help(L("在概览中显示全部对话，可勾选任意对话参与自动继续",
                    "Show all chats in Overview so any chat can be selected for auto-continue."))

            Divider()
                .overlay(Color.black.opacity(0.05))

            // 语言
            HStack(spacing: 10) {
                Text(L("语言", "Language"))
                    .font(.subheadline)
                Spacer()
                Picker("", selection: languageBinding) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                .frame(width: 205)
            }

            Divider()
                .overlay(Color.black.opacity(0.05))

            Toggle(L("先恢复目标，再发送指令", "Resume Goal before sending"), isOn: $model.resumeGoalBeforeSending)
                .font(.subheadline)
            Text(L("点击暂停目标的恢复按钮，确认 active 后再发送。没有目标时仅发送指令。", "Click a paused Goal's resume button, confirm active, then send the command. Chats without a Goal only receive the command."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            // remote_control
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(
                    get: { model.remoteControlEnabled },
                    set: { model.setRemoteControl($0) }
                )) {
                    Text("remote_control")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(L("通过 Codex 本地协议继续对话：重启 Codex 后生效，无需辅助功能授权",
                       "Connects to the desktop server for usage queries after Codex restarts. Continuing chats uses GUI automation and requires Accessibility permission."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
    }
}
