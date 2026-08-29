//
//  StatsView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 统计页面：详细展示学习数据（streak / 概览 / 7天 / 分布 / 评级）+ 「前往设置」快捷入口
struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats = StatsSummary()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                streakSection
                totalSection
                weekSection
                distributionSection
                ratingRatioSection
                settingsShortcutSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("统计")
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

    // MARK: - 设置快捷入口

    private var settingsShortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("⚙️ 设置 & 存储", systemImage: "gearshape.fill")
                    .textStyle(.subsectionTitle)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .textStyle(.miniText)
            }

            HStack(spacing: 12) {
                // 存储概览
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.selectedProvider.systemIcon)
                            .foregroundStyle(.blue)
                        Text(appState.selectedProvider.displayName)
                            .textStyle(.primaryText)
                    }
                    Text(appState.activeFS?.displayLocation ?? "—")
                        .textStyle(.miniText)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // 字号概览
                VStack(alignment: .trailing, spacing: 4) {
                    Text("字号：\(appState.textScaleLabel)")
                        .textStyle(.secondaryText)
                        .foregroundStyle(.primary)
                    Text("切换「设置」Tab 可修改")
                        .textStyle(.miniText)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                appState.mainTabIndex = 3  // Tab 3 = 设置
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2.fill")
                    Text("前往「设置」Tab")
                        .textStyle(.subsectionTitle)
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.person.crop")
                        .opacity(0)   // 占位对齐
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.1)))
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            if let msg = appState.providerStatus {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(
                        msg.contains("失败") ? Color.red :
                            (msg.contains("迁移") || msg.contains("⏳") || msg.contains("⚠️") ? Color.orange : Color.green)
                    )
                    Text(msg)
                        .textStyle(.miniText)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
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
