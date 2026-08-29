//
//  StatsView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 统计页面：详细展示学习数据 + 云盘设置 + 字体大小调节
struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats = StatsSummary()

    // 连接测试 UI 状态
    @State private var testResult: (success: Bool, message: String)? = nil
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                streakSection
                totalSection
                weekSection
                distributionSection
                ratingRatioSection
                cloudProviderSection
                textScaleSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("统计 & 设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { stats = appState.scheduler.computeStats() }
        .refreshable { stats = appState.scheduler.computeStats() }
    }

    // MARK: - 打卡

    private var streakSection: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .trim(from: 0, to: CGFloat(min(Double(stats.streakDays), 365) / 365))
                    .stroke(
                        LinearGradient(colors: [.orange, .pink, .purple], startPoint: .top, endPoint: .bottom),
                        lineWidth: 10)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 100, height: 100)
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                    .frame(width: 100, height: 100)
                VStack(spacing: 0) {
                    Text("\(stats.streakDays)")
                        .textStyle(.screenTitle)
                    Text("天")
                        .textStyle(.tertiaryText)
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("连续打卡", systemImage: "flame.fill")
                    .textStyle(.subsectionTitle)
                    .foregroundColor(.orange)
                Text("累计复习 \(stats.totalReviews) 次")
                    .textStyle(.secondaryText)
                    .foregroundColor(.secondary)
                Text("连续打卡越久，记忆越牢固！")
                    .textStyle(.tertiaryText)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - 总数统计

    private var totalSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            BigStat(title: "总笔记数", value: "\(stats.totalNotes)",
                    systemImage: "note.text", color: .blue)
            BigStat(title: "今日到期", value: "\(stats.dueToday)",
                    systemImage: "calendar", color: .red)
            BigStat(title: "今日已学", value: "\(stats.reviewedToday)",
                    systemImage: "checkmark.circle.fill", color: .green)
            BigStat(title: "今日新卡", value: "\(stats.newToday)",
                    systemImage: "sparkles", color: .purple)
        }
    }

    // MARK: - 7 天

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("近 7 天复习", systemImage: "chart.bar.fill")
                    .textStyle(.subsectionTitle)
                Spacer()
                let total = stats.weeklyReviewCounts.reduce(0, +)
                Text("合计 \(total) 次")
                    .textStyle(.secondaryText)
                    .foregroundColor(.secondary)
            }
            WeeklyChartView(counts: stats.weeklyReviewCounts)
                .frame(height: 160)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 卡片分布

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("卡片状态分布", systemImage: "square.stack.3d.up.fill")
                    .textStyle(.subsectionTitle)
                Spacer()
            }
            StatusDistributionView(stats: stats)
                .frame(height: 120)

            HStack(spacing: 12) {
                DistributionCard(title: "新卡片", value: stats.newCount,
                                 total: stats.totalNotes, color: .blue, systemImage: "sparkles")
                DistributionCard(title: "学习中", value: stats.learningCount,
                                 total: stats.totalNotes, color: .orange, systemImage: "book.fill")
                DistributionCard(title: "已掌握", value: stats.masteredCount,
                                 total: stats.totalNotes, color: .green, systemImage: "checkmark.seal.fill")
                let rest = max(0, stats.totalNotes - stats.newCount - stats.learningCount - stats.masteredCount)
                DistributionCard(title: "复习中", value: rest,
                                 total: stats.totalNotes, color: .purple, systemImage: "repeat")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 评级比例

    private var ratingRatioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("历史评级分布", systemImage: "star.fill")
                    .textStyle(.subsectionTitle)
                Spacer()
            }
            RatingDistributionView()
                .frame(height: 160)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - ☁️ 云盘 Provider 选择

    private var cloudProviderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题
            HStack {
                Label("☁️ 云盘 & 存储位置", systemImage: "externaldrive.badge.icloud")
                    .textStyle(.subsectionTitle)
                Spacer()
                Image(systemName: appState.iCloudContainerAvailable ? "icloud.fill" : "icloud.slash")
                    .foregroundStyle(appState.iCloudContainerAvailable ? Color.blue : Color.secondary)
            }

            // Provider Picker
            Picker("存储后端", selection: $appState.selectedProvider) {
                ForEach(CloudProviderType.allCases) { type in
                    Label(type.displayName, systemImage: type.systemIcon).tag(type)
                }
            }
            .pickerStyle(.menu)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            // 当前状态
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
                                    (msg.contains("迁移") || msg.contains("⏳") ? Color.orange : Color.green)
                            )
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            // 动态表单：WebDAV
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

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    field(label: "服务器地址", placeholder: "https://dav.jianguoyun.com/dav/",
                          text: $appState.webDAVConfig.serverURL)
                    field(label: "用户名", placeholder: "your@mail.com",
                          text: $appState.webDAVConfig.username)
                    SecureField("密码（应用专用密码，Keychain 加密保存）", text: $appState.pendingWebDAVPassword)
                        .textStyle(.body)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    field(label: "远端根路径", placeholder: "/AnkiNotes",
                          text: $appState.webDAVConfig.rootPath)
                    Toggle("允许自签名证书（NAS/内网场景）",
                           isOn: $appState.webDAVConfig.trustSelfSigned)
                    .textStyle(.secondaryText)
                    .tint(.purple)
                }
            }

            // 测试 & 保存
            HStack(spacing: 10) {
                Button {
                    Task { await runTestWebDAV() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView() }
                        Image(systemName: "link.circle.fill")
                        Text("🔗 测试连接")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.14)))
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
            }

            // 测试结果
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

            // 使用提示
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text("WebDAV 开通 & 获取应用密码")
                        .textStyle(.tertiaryText)
                        .foregroundStyle(.primary)
                }
                Text("• 推荐：🥜**坚果云**（免费版即可，个人设置 → 安全选项 → 添加应用 → 复制生成的应用专用密码，服务器填 `https://dav.jianguoyun.com/dav/`）").textStyle(.miniText).foregroundStyle(.secondary)
                Text("• 或：群晖 DSM「WebDAV Server」、Nextcloud、AList（可挂载百度/阿里云盘后对外暴露 WebDAV）。").textStyle(.miniText).foregroundStyle(.secondary)
                Text("• 切换到 WebDAV 并保存时，自动把本机 Notes + .metadata 迁移到远端（冲突时备份为 _backup_时间戳），数据双保险。").textStyle(.miniText).foregroundStyle(.secondary)
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

            // 预览
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

            Text("提示：所有界面标题、列表项、按钮、评分文案统一按语义档位（.screenTitle / .sectionTitle / .body / .tertiaryText）渲染，配合环境键 `textScale` 进行 4 档线性缩放。")
                .textStyle(.miniText)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - 评级分布（仅本页使用）

private struct RatingDistributionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let logs = appState.storage.getReviewLogs(since: .distantPast)
        var counts: [ReviewRating: Int] = [.again: 0, .hard: 0, .good: 0, .easy: 0]
        for log in logs { counts[log.rating, default: 0] += 1 }
        let total = max(logs.count, 1)

        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach([ReviewRating.again, .hard, .good, .easy], id: \.self) { r in
                    let w = CGFloat(counts[r, default: 0]) / CGFloat(total)
                    Rectangle()
                        .fill(Color(hex: r.color))
                        .frame(width: w == 0 ? 0 : nil,
                               height: 16)
                }
            }
            .cornerRadius(8)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                ForEach([ReviewRating.again, .hard, .good, .easy], id: \.self) { r in
                    let count = counts[r, default: 0]
                    let pct = Double(count) / Double(total) * 100
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: r.color))
                                .frame(width: 10, height: 10)
                            Text(r.description)
                                .textStyle(.tertiaryText)
                        }
                        Text("\(count) 次")
                            .textStyle(.miniText)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f%%", pct))
                            .textStyle(.miniText)
                            .foregroundColor(Color(hex: r.color))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(hex: r.color).opacity(0.08))
                    .cornerRadius(8)
                }
            }
            Text("记忆状态越好，Good/Easy 的比例越高；Again 太多，说明需要简化卡片内容")
                .textStyle(.miniText)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}
