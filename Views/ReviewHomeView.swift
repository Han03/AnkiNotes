//
//  ReviewHomeView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 复习主页：显示今日概览，可进入复习会话
struct ReviewHomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingReview = false
    @State private var stats = StatsSummary()
    
    var body: some View {
        let storage = appState.storage!
        let scheduler = appState.scheduler!
        let queue = scheduler.getTodayReviewQueue()
        let newCount = queue.filter { $0.srs.cardState == .new }.count
        let learningCount = queue.filter { $0.srs.cardState == .learning || $0.srs.cardState == .relearning }.count
        
        ScrollView {
            VStack(spacing: 18) {
                // 顶部统计卡片
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今日概览")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("\(stats.streakDays) 天连续打卡")
                                .font(.title2.bold())
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Image(systemName: "flame.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                    }
                    
                    HStack(spacing: 12) {
                        StatCard(title: "待复习", value: "\(queue.count)",
                                 systemImage: "doc.richtext.fill",
                                 color: .blue, highlight: queue.count > 0)
                        StatCard(title: "新卡片", value: "\(newCount)",
                                 systemImage: "sparkles",
                                 color: .purple)
                        StatCard(title: "学习中", value: "\(learningCount)",
                                 systemImage: "book.fill",
                                 color: .orange)
                        StatCard(title: "已复习", value: "\(stats.reviewedToday)",
                                 systemImage: "checkmark.seal.fill",
                                 color: .green)
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                
                // 开始复习按钮
                Button {
                    showingReview = true
                } label: {
                    HStack(spacing: 14) {
                        if queue.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("今日已完成")
                                    .font(.title3.bold())
                                    .foregroundColor(.green)
                                Text("明天再来巩固记忆吧！")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue, Color.blue.opacity(0.6)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .frame(width: 52, height: 52)
                                Image(systemName: "play.fill")
                                    .font(.title.bold())
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("开始复习")
                                    .font(.title3.bold())
                                Text("共 \(queue.count) 张卡片待复习 · 预计用时 \(estimatedTime(for: queue.count)) 分钟")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(queue.isEmpty ? Color.green.opacity(0.08) : Color.blue.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(queue.isEmpty)
                
                // 7 天复习趋势
                VStack(spacing: 12) {
                    HStack {
                        Text("近 7 天复习量")
                            .font(.headline)
                        Spacer()
                    }
                    WeeklyChartView(counts: stats.weeklyReviewCounts)
                        .frame(height: 140)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                
                // 卡片状态分布
                VStack(spacing: 12) {
                    HStack {
                        Text("卡片状态分布")
                            .font(.headline)
                        Spacer()
                        Text("共 \(stats.totalNotes) 张")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    StatusDistributionView(stats: stats)
                        .frame(height: 100)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                
                // 按文件夹复习
                VStack(alignment: .leading, spacing: 10) {
                    Text("按文件夹复习")
                        .font(.headline)
                    let folders = storage.getAllFolders()
                    if folders.isEmpty {
                        Text("尚未创建文件夹")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                    ForEach(folders) { folder in
                        let count = scheduler.getTodayDueCount(in: folder.id)
                        NavigationLink {
                            ReviewSessionView(folderId: folder.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 24)
                                Text(folder.name)
                                    .font(.subheadline)
                                Spacer()
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.red)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("复习")
        .onAppear { stats = scheduler.computeStats() }
        .fullScreenCover(isPresented: $showingReview) {
            NavigationStack {
                ReviewSessionView(folderId: nil)
            }
        }
    }
    
    private func estimatedTime(for count: Int) -> String {
        let minutes = max(1, count / 10)
        return "\(minutes)"
    }
}
