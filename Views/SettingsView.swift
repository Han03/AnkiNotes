//
//  SettingsView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 独立设置页：云盘 & 存储位置 + 全局文字大小 + 关于
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var testResult: (success: Bool, message: String)? = nil
    @State private var isTesting = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cloudProviderSection
                textScaleSection
                aboutSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - ☁️ 云盘 Provider 选择

    private var cloudProviderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("☁️ 云盘 & 存储位置", systemImage: "externaldrive.badge.icloud")
                    .textStyle(.subsectionTitle)
                Spacer()
                Image(systemName: appState.iCloudContainerAvailable ? "icloud.fill" : "icloud.slash")
                    .foregroundStyle(appState.iCloudContainerAvailable ? Color.blue : Color.secondary)
            }

            Picker("存储后端", selection: $appState.selectedProvider) {
                ForEach(CloudProviderType.allCases) { type in
                    Label(type.displayName, systemImage: type.systemIcon).tag(type)
                }
            }
            .pickerStyle(.menu)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            VStack(alignment: .leading, spacing: 6) {
                statusRow(label: "当前后端", value: appState.selectedProvider.displayName, bold: true)
                statusRow(label: "存储路径", value: appState.activeFS?.displayLocation ?? "—")
                if let msg = appState.providerStatus {
                    HStack(alignment: .top) {
                        Text("状态：").textStyle(.miniText).foregroundStyle(.secondary)
                        Text(msg)
                            .textStyle(.miniText)
                            .foregroundStyle(
                                msg.contains("失败") ? Color.red :
                                    (msg.contains("迁移") || msg.contains("⏳") || msg.contains("⚠️") ? Color.orange : Color.green)
                            )
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            if appState.selectedProvider == .webDAV {
                webDAVConfigForm
            } else if appState.selectedProvider == .iCloud {
                iCloudHint
            } else {
                localHint
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: WebDAV 表单

    private var webDAVConfigForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.purple)
                Text("🥇 WebDAV 连接配置")
                    .textStyle(.subsectionTitle)
                    .foregroundStyle(.primary)
                Spacer()
            }
            // 新 UX：先占位显示表单 → 填完地址/用户/密码 → 点 💾保存并应用 才真的把 activeFS 重写为 WebDAV 后端
            Text("👇 先把下面 5 项填完 → 点底部紫色「💾保存并应用 WebDAV 配置」按钮完成切换（期间可随时点🔗测试连接先确认连通性）。")
                .textStyle(.miniText)
                .foregroundStyle(.secondary)
                .padding(.top, -2)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    field(label: "服务器地址（必填）", placeholder: "https://dav.jianguoyun.com/dav/",
                          text: $appState.webDAVConfig.serverURL)
                    field(label: "用户名（必填）", placeholder: "your@mail.com",
                          text: $appState.webDAVConfig.username)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密码（必填，Keychain 加密保存）").textStyle(.miniText).foregroundStyle(.secondary)
                        SecureField("应用专用密码：如坚果云「安全选项 → 添加应用 → 生成」",
                                    text: $appState.pendingWebDAVPassword)
                            .textStyle(.body)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    }
                    field(label: "远端根路径", placeholder: "/AnkiNotes",
                          text: $appState.webDAVConfig.rootPath)
                    Toggle("允许自签名证书（NAS/内网场景）",
                           isOn: $appState.webDAVConfig.trustSelfSigned)
                    .textStyle(.secondaryText)
                    .tint(.purple)
                }
            }

            // 主操作：保存+应用 WebDAV（真正的后端切换在这里做）
            Button {
                runSaveAndApplyWebDAV()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("💾 保存并应用 WebDAV 配置")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.purple.gradient))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            HStack(spacing: 10) {
                Button {
                    Task { await runTestWebDAV() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView() }
                        Image(systemName: "link.circle.fill")
                        Text("🔗 测试连接（先不点保存也能试）")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.14)))
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
            }

            if let r = testResult {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.success ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(r.success ? Color.green : Color.red)
                    Text(r.message)
                        .textStyle(.miniText)
                        .foregroundStyle(r.success ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(
                    (r.success ? Color.green : Color.red).opacity(0.08)
                ))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text("WebDAV 开通 & 获取应用密码")
                        .textStyle(.tertiaryText)
                        .foregroundStyle(.primary)
                }
                Text("• 推荐：🥜**坚果云**（免费版即可，个人设置 → 安全选项 → 添加应用 → 复制生成的应用专用密码，服务器填 `https://dav.jianguoyun.com/dav/`）").textStyle(.miniText).foregroundStyle(.secondary)
                Text("• 或：群晖 DSM「WebDAV Server」、Nextcloud、AList（可挂载百度/阿里云盘后对外暴露 WebDAV）。").textStyle(.miniText).foregroundStyle(.secondary)
                Text("• 点 💾保存并应用 成功后，自动把本机 Notes + .metadata 迁移到远端（冲突时备份为 _backup_时间戳），数据双保险。").textStyle(.miniText).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).textStyle(.miniText).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textStyle(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        }
    }

    private var iCloudHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle").foregroundStyle(.blue)
                Text("☁️ iCloud 生效条件 & 说明")
                    .textStyle(.tertiaryText)
                    .foregroundStyle(.primary)
            }
            Text("• **需要 ¥688/年的 Apple Developer 账号**，在开发者后台为该 App ID 开启 iCloud Container（名称 `iCloud.com.ankinotes.app`）并关联；免费侧载场景 entitlements 不被苹果承认，容器返回 nil，会自动回退到本机 Documents。").textStyle(.miniText).foregroundStyle(.secondary)
            Text("• 数据根目录位于 iCloud Drive ▸ **AnkiNotes**（在 iOS 「文件」App 可见），内部 Notes 放 Markdown、.metadata 放 JSON 索引；App 更新或更换设备时永不丢失。").textStyle(.miniText).foregroundStyle(.secondary)
            Text("• 切换时自动迁移已有笔记（Notes + .metadata），冲突不会直接覆盖，目标目录会备份为 `_backup_时间戳`。").textStyle(.miniText).foregroundStyle(.secondary)
            if !appState.iCloudContainerAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("当前 iCloud 容器不可用（免费签名无法加载 entitlements），已自动回退本机存储。")
                        .textStyle(.miniText)
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            }
        }
    }

    private var localHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive").foregroundStyle(.gray)
                Text("📁 本机存储说明")
                    .textStyle(.tertiaryText)
                    .foregroundStyle(.primary)
            }
            Text("• 数据保存位置：App 沙盒 Documents 目录，可通过爱思助手 / iTunes 文件共享访问。").textStyle(.miniText).foregroundStyle(.secondary)
            Text("• **覆盖安装 App 更新不会丢失 Documents 数据**；但删除 App 会一并删除 Documents，如需跨设备迁移请使用 WebDAV。").textStyle(.miniText).foregroundStyle(.secondary)
            Text("• 需要导入本地 Markdown 文件夹：在「笔记」页右上角 ➕ → 选择「📥 导入 Markdown 文件夹」。").textStyle(.miniText).foregroundStyle(.secondary)
        }
    }

    private func statusRow(label: String, value: String, bold: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text("\(label)：").textStyle(.miniText).foregroundStyle(.secondary)
            Text(value)
                .textStyle(bold ? .tertiaryText : .miniText)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func runTestWebDAV() async {
        isTesting = true
        defer { isTesting = false }
        let r = await appState.testCurrentWebDAVConnection()
        testResult = r
    }

    /// 主按钮动作：同步调用 AppState.saveAndApplyWebDAV()，
    /// 真正完成 Keychain 密码写 + 校验 + 迁移 + activeFS 重建。
    private func runSaveAndApplyWebDAV() {
        // 先给个临时状态避免重复点
        isTesting = true
        defer { isTesting = false }
        let ok = appState.saveAndApplyWebDAV()
        // 把 providerStatus 直接渲染到 testResult 区域作为强提示
        if let msg = appState.providerStatus {
            testResult = (ok, msg)
        } else if ok {
            testResult = (true, "✅ 已成功切换为 🥇 WebDAV 并完成数据迁移。")
        } else {
            testResult = (false, "❌ 切换失败，请查看状态区提示。")
        }
    }

    // MARK: - 文字大小调节

    private var textScaleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("🔠 全局文字大小", systemImage: "textformat.size")
                    .textStyle(.subsectionTitle)
                Spacer()
                Text("当前：\(appState.textScaleLabel)")
                    .textStyle(.tertiaryText)
                    .foregroundStyle(.secondary)
            }

            Picker("文字大小", selection: $appState.textScale) {
                ForEach(Array(zip(AppState.textScaleLabels, AppState.textScaleOptions)), id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("效果预览 · 标题示例")
                    .textStyle(.sectionTitle)
                Text("正文示例：调整这个分段控件可让整个 App 的标题、卡片、按钮、辅助说明同步放大 1~3 档。记忆卡片内的 Markdown 字号也会跟随环境缩放一起变化。")
                    .textStyle(.body)
                    .foregroundStyle(.primary)
                Text("辅助说明字号示例（原 caption2）")
                    .textStyle(.tertiaryText)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            Text("提示：所有界面标题、列表项、按钮、评级文案统一按语义档位（.screenTitle / .sectionTitle / .body / .tertiaryText）渲染，配合环境键 `textScale` 进行 4 档线性缩放。")
                .textStyle(.miniText)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 关于 & 版本

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ℹ️ 关于 AnkiNotes", systemImage: "info.circle.fill")
                    .textStyle(.subsectionTitle)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .textStyle(.miniText)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                aboutRow(systemImage: "brain.head.profile", title: "复习算法", detail: "SM-2 四档评级（Again / Hard / Good / Easy），支持每日新卡配额 & 到期队列")
                aboutRow(systemImage: "folder.fill", title: "文件夹管理", detail: "真实 Markdown 文件 + 多层嵌套子文件夹，iOS 「文件」App 可直接读写")
                aboutRow(systemImage: "key.fill", title: "WebDAV 密码", detail: "通过系统 Keychain（kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly）加密保存，不写明文 UserDefaults")
                aboutRow(systemImage: "lock.shield.fill", title: "完全离线", detail: "默认不走网络；仅当你主动开启 WebDAV 时，按文件粒度同步你自己的服务器")
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 8) {
                Button {
                    if let url = URL(string: "https://github.com/Han03/AnkiNotes") { openURL(url) }
                } label: {
                    Label("GitHub 仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            Text("提示：若 WebDAV 切回本机，请先在上方表单填好地址+用户名+应用专用密码后，再把「存储后端」Picker 切回 WebDAV；只要 Password 或 Keychain 任一有值即可生效，避免反复跳转。")
                .textStyle(.miniText)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private func aboutRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 22)
                .textStyle(.primaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(.primaryText)
                Text(detail).textStyle(.miniText).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
