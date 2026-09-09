//
//  SettingsView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 独立设置页：同步与存储 + AI功能 + 阅读与播放 + 关于
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var testResult: (success: Bool, message: String)? = nil
    @State private var isTesting = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                syncStorageSection
                aiSection
                readingPlaybackSection
                aboutSection
            }
            .padding()
        }
        .background(Color.bgPage)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 同步与存储

    private var syncStorageSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            sectionHeader(title: "同步与存储", systemImage: "externaldrive.badge.icloud")

            // 存储方式选择（分段控件）
            Picker("存储方式", selection: $appState.selectedProvider) {
                ForEach(CloudProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // 当前状态简洁展示
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(statusText)
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
                Spacer()
            }
            .padding(AppSpacing.md)
            .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))

            // WebDAV配置（选择WebDAV时展开）
            if appState.selectedProvider == .webDAV {
                webDAVConfigForm
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if appState.selectedProvider == .iCloud {
                iCloudHint
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                localHint
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AppSpacing.xl)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var statusIcon: String {
        if let msg = appState.providerStatus {
            if msg.contains("失败") { return "xmark.circle.fill" }
            if msg.contains("迁移") || msg.contains("⚠️") { return "exclamationmark.triangle.fill" }
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if let msg = appState.providerStatus {
            if msg.contains("失败") { return .red }
            if msg.contains("迁移") || msg.contains("⚠️") { return .orange }
        }
        return .green
    }

    private var statusText: String {
        let location = appState.activeFS?.displayLocation ?? "—"
        return "\(appState.selectedProvider.displayName) · \(location)"
    }

    // MARK: WebDAV 配置表单

    private var webDAVConfigForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Divider()

            field(label: "服务器地址", placeholder: "https://dav.jianguoyun.com/dav/",
                  text: $appState.webDAVConfig.serverURL)
            field(label: "用户名", placeholder: "your@mail.com",
                  text: $appState.webDAVConfig.username)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("密码").font(.appCaption).foregroundColor(.textSecondary)
                SecureField("应用专用密码", text: $appState.pendingWebDAVPassword)
                    .font(.appBody)
                    .padding(AppSpacing.md)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            field(label: "远端根路径", placeholder: "/AnkiNotes",
                  text: $appState.webDAVConfig.rootPath)

            Toggle("允许自签名证书", isOn: $appState.webDAVConfig.trustSelfSigned)
                .font(.appBody)
                .tint(.brandPrimary)

            // 主操作按钮
            Button {
                runSaveAndApplyWebDAV()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("保存并应用")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.brandPrimary.gradient))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 次操作按钮
            Button {
                Task { await runTestWebDAV() }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    if isTesting { ProgressView() }
                    Image(systemName: "link.circle.fill")
                    Text("测试连接")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm)
                .background(RoundedRectangle(cornerRadius: AppCornerRadius.md).fill(Color.brandPrimaryMedium))
                .foregroundStyle(Color.brandPrimary)
            }
            .buttonStyle(.plain)
            .disabled(isTesting)

            // 测试结果
            if let r = testResult {
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Image(systemName: r.success ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(r.success ? Color.green : Color.red)
                    Text(r.message)
                        .font(.appCaption)
                        .foregroundStyle(r.success ? Color.green : Color.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(AppSpacing.md)
                .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(
                    (r.success ? Color.green : Color.red).opacity(0.08)
                ))
            }

            // 关键提示（只保留一条）
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.textSecondary)
                Text("坚果云：个人设置 → 安全选项 → 添加应用 → 复制应用专用密码")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
                Spacer()
            }
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label).font(.appCaption).foregroundColor(.textSecondary)
            if isSecure {
                SecureField(placeholder, text: text)
                    .font(.appBody)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(AppSpacing.md)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))
            } else {
                TextField(placeholder, text: text)
                    .font(.appBody)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(AppSpacing.md)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))
            }
        }
    }

    // MARK: - 方法

    private func runTestWebDAV() async {
        isTesting = true
        defer { isTesting = false }
        let r = await appState.testCurrentWebDAVConnection()
        testResult = r
    }

    private func runSaveAndApplyWebDAV() {
        isTesting = true
        defer { isTesting = false }
        let ok = appState.saveAndApplyWebDAV()
        if let msg = appState.providerStatus {
            testResult = (ok, msg)
        } else if ok {
            testResult = (true, "已成功切换为 WebDAV 并完成数据迁移。")
        } else {
            testResult = (false, "切换失败，请查看状态提示。")
        }
    }

    private var iCloudHint: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("iCloud Drive 同步")
                    .font(.appCaption)
                    .fontWeight(.medium)
                Text("数据位于 iCloud Drive ▸ AnkiNotes，跨设备自动同步")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
                if !appState.iCloudContainerAvailable {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("当前 iCloud 容器不可用，已回退本机存储")
                    }
                    .font(.appCaption)
                    .foregroundStyle(.orange)
                    .padding(AppSpacing.xs)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.xs).fill(Color.orange.opacity(0.08)))
                }
            }
            Spacer()
        }
        .padding(.top, AppSpacing.xs)
    }

    private var localHint: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(systemName: "internaldrive")
                .foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("本机存储")
                    .font(.appCaption)
                    .fontWeight(.medium)
                Text("数据保存在 App 沙盒 Documents，覆盖安装不丢失，删除 App 会清除")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(.top, AppSpacing.xs)
    }

    // MARK: - AI 功能

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            sectionHeader(title: "AI 功能", systemImage: "brain.head.profile")

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                field(label: "API Key", placeholder: "sk-xxxxxxxxxxxxxxxx",
                      text: $appState.bailianConfig.apiKey, isSecure: true)
                field(label: "模型编码", placeholder: "qwen-plus",
                      text: $appState.bailianConfig.modelCode)
                Text("常用：qwen-plus、qwen-turbo、qwen-max、qwen-long")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
            }

            if appState.bailianConfig.isConfigured {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已配置，可在刷题页生成题目")
                        .font(.appCaption)
                        .foregroundColor(.green)
                    Spacer()
                }
            }
        }
        .padding(AppSpacing.xl)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 阅读与播放

    private var readingPlaybackSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            sectionHeader(title: "阅读与播放", systemImage: "speaker.wave.2.fill")

            // 语音朗读方案
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("语音朗读方案")
                    .font(.appBody)
                    .foregroundColor(.textPrimary)
                Picker("朗读方案", selection: $appState.ttsConfig.provider) {
                    ForEach(TTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if appState.ttsConfig.provider == .edgeTTSService {
                    HStack {
                        Text("音色")
                            .font(.appBody)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Picker("音色", selection: $appState.ttsConfig.edgeVoice) {
                            ForEach(EdgeTTSVoice.allCases) { voice in
                                Text(voice.displayName).tag(voice.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            Divider()

            // 全局文字大小
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack {
                    Text("全局文字大小")
                        .font(.appBody)
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Text(appState.textScaleLabel)
                        .font(.appCaption)
                        .foregroundColor(.textSecondary)
                }
                Picker("文字大小", selection: $appState.textScale) {
                    ForEach(Array(zip(AppState.textScaleLabels, AppState.textScaleOptions)), id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                // 精简预览（一行示例）
                Text("预览：调整后全 App 文字同步缩放")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))
            }
        }
        .padding(AppSpacing.xl)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 关于

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text("关于")
                    .font(.appSubheading)
                    .fontWeight(.semibold)
                Spacer()
                Text("v\(appVersion)")
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
            }

            Button {
                if let url = URL(string: "https://github.com/Han03/AnkiNotes") { openURL(url) }
            } label: {
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(.textSecondary)
                    Text("GitHub 仓库")
                        .font(.appBody)
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.textSecondary)
                }
                .padding(.vertical, AppSpacing.sm)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.xl)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 通用组件

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(.brandPrimary)
            Text(title)
                .font(.appSubheading)
                .fontWeight(.semibold)
                .foregroundColor(.textPrimary)
            Spacer()
        }
    }
}
