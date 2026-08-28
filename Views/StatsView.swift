//
//  StatsView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 统计页面：详细展示学习数据
struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats = StatsSummary()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 打卡总览
                streakSection
                // 总数
                totalSection
                // 7日
                weekSection
                // 卡片分布
                distributionSection
                // 评级比例
                ratingRatioSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { stats = appState.scheduler.computeStats() }
        .refreshable {
            stats = appState.scheduler.computeStats()
        }
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
                        .font(.title.bold())
                    Text("天")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("连续打卡", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundColor(.orange)
                Text("累计复习 \(stats.totalReviews) 次")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("连续打卡越久，记忆越牢固！")
                    .font(.caption)
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
                    .font(.headline)
                Spacer()
                let total = stats.weeklyReviewCounts.reduce(0, +)
                Text("合计 \(total) 次")
                    .font(.subheadline)
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
                    .font(.headline)
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
                    .font(.headline)
                Spacer()
            }
            RatingDistributionView()
                .frame(height: 160)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - 辅助组件

private struct BigStat: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                Spacer()
                Text(value)
                    .font(.title.bold())
            }
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

private struct DistributionCard: View {
    let title: String
    let value: Int
    let total: Int
    let color: Color
    let systemImage: String
    
    var body: some View {
        let ratio = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(value)")
                    .font(.headline.bold())
            }
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            ProgressView(value: ratio)
                .tint(color)
                .scaleEffect(x: 1, y: 1.5)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.08))
        )
    }
}

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
                                .font(.caption)
                                .bold()
                        }
                        Text("\(count) 次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f%%", pct))
                            .font(.caption2.bold())
                            .foregroundColor(Color(hex: r.color))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(hex: r.color).opacity(0.08))
                    .cornerRadius(8)
                }
            }
            Text("记忆状态越好，Good/Easy 的比例越高；If Again 太多，说明需要简化卡片内容")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}
