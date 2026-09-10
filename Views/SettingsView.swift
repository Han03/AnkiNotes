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
    /// 存储方式草稿：切换 Picker 只改草稿，点击"保存设置"才真正应用（避免误操作立即生效）
    @State private var pendingProvider: CloudProviderType = .local
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                syncStorageSection
                Divider()
                aiSection
                Divider()
                readingPlaybackSection
                Divider()
                aboutSection
            }
            .padding()
        }
        .background(Color.bgPage)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入设置页时，草稿与当前生效值同步
            pendingProvider = appState.selectedProvider
        }
    }

    // MARK: - 同步与存储

    private var syncStorageSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            sectionHeader(title: "同步与存储", systemImage: "externaldrive.badge.icloud")

            // 存储方式选择（分段控件）——只修改草稿，点击"保存设置"才应用
            Picker("存储方式", selection: $pendingProvider) {
                ForEach(CloudProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // 最近云端操作结果（粒度=逻辑操作，如"云端同步/测试连接/保存配置"，非单条接口调用）
            cloudOperationStatusView

            // 未保存提示 + 保存按钮（草稿与生效值不一致时显示）
            if pendingProvider != appState.selectedProvider {
                VStack(spacing: AppSpacing.sm) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text("存储方式有未保存的更改，点击下方保存后生效")
                            .font(.appCaption)
                            .foregroundColor(.textSecondary)
                        Spacer()
                    }
                    Button {
                        runSaveSettings()
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("保存设置")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.brandPrimary.gradient))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            // WebDAV配置（草稿选择WebDAV时展开）
            if pendingProvider == .webDAV {
                webDAVConfigForm
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if pendingProvider == .iCloud {
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

    // MARK: - 最近云端操作结果展示

    private var cloudOperationStatusView: some View {
        Group {
            if let op = appState.lastCloudOperation {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    operationBadge(op.outcome)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: AppSpacing.xs) {
                            Text(op.operation)
                                .font(.appBody)
                                .fontWeight(.semibold)
                            Text(relativeTime(op.timestamp))
                                .font(.appCaption)
                                .foregroundColor(.textTertiary)
                        }
                        Text(op.outcome == .failure ? (op.detail ?? op.summary) : op.summary)
                            .font(.appCaption)
                            .foregroundColor(outcomeTextColor(op.outcome))
                            .textSelection(.enabled)
                        if !op.steps.isEmpty {
                            Text(op.steps.joined(separator: " → "))
                                .font(Font.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundColor(.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.textTertiary)
                    Text("暂无云端操作记录：完成同步、测试连接或保存配置后在此显示结果")
                        .font(.appCaption)
                        .foregroundColor(.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.bgInput))
    }

    @ViewBuilder
    private func operationBadge(_ outcome: CloudOperationResult.Outcome) -> some View {
        switch outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.appBody)
                .foregroundStyle(Color.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.appBody)
                .foregroundStyle(Color.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appBody)
                .foregroundStyle(Color.orange)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func outcomeTextColor(_ outcome: CloudOperationResult.Outcome) -> Color {
        switch outcome {
        case .success: return Color.green
        case .failure: return Color.red
        case .warning: return Color.orange
        case .inProgress: return Color.textSecondary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: WebDAV 配置表单

    private var webDAVConfigForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
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
        appState.recordCloudOperation(operation: "测试连接",
                                      outcome: r.success ? .success : .failure,
                                      summary: r.message)
    }

    private func runSaveAndApplyWebDAV() {
        isTesting = true
        defer { isTesting = false }
        let ok = appState.saveAndApplyWebDAV()
        // 保存成功后草稿与实际生效值同步（失败占位时 selectedProvider 仍为 .webDAV）
        pendingProvider = appState.selectedProvider
        let summary: String
        if let msg = appState.providerStatus {
            testResult = (ok, msg)
            summary = msg
        } else if ok {
            let successMsg = "已成功切换为 WebDAV。请到笔记页下拉同步，从云端拉取笔记。"
            testResult = (true, successMsg)
            summary = successMsg
        } else {
            summary = "切换失败，请查看状态提示。"
            testResult = (false, summary)
        }
        appState.recordCloudOperation(operation: "保存配置",
                                      outcome: ok ? .success : .failure,
                                      summary: summary)
    }

    /// 保存存储方式草稿：Local/iCloud 直接应用；WebDAV 走严格校验（配置齐全才真正切换）
    private func runSaveSettings() {
        let target = pendingProvider
        if target == .webDAV {
            // 与表单"保存并应用"一致的严格流程（内部处理 selectedProvider 设置与 Keychain 密码写入）
            let ok = appState.saveAndApplyWebDAV()
            var statusMsg: String?
            if let msg = appState.providerStatus {
                statusMsg = msg
                testResult = (ok, msg)
            }
            appState.recordCloudOperation(operation: "保存配置",
                                          outcome: ok ? .success : .failure,
                                          summary: statusMsg ?? (ok ? "已成功切换为 WebDAV" : "切换失败"))
        } else {
            // Local/iCloud：赋值触发 didSet → applyFileSystem 立即生效
            appState.selectedProvider = target
            appState.recordCloudOperation(operation: "保存配置", outcome: .success,
                                          summary: "已切换为 \(target.displayName) 存储")
        }
        // 草稿同步为实际生效值（WebDAV 配置不完整时 selectedProvider 停留在 .webDAV 占位）
        pendingProvider = appState.selectedProvider
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
