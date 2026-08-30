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
    @State private var folderDisplayCount = 10  // 文件夹列表分页
    @State private var isLoadingFolders = false  // 是否正在加载更多文件夹
    @State private var cachedFolders: [Folder]? = nil  // 缓存文件夹列表，避免重复计算
    
    var body: some View {
        let storage = appState.storage!
        let scheduler = appState.scheduler!
        let queue = scheduler.getTodayReviewQueue()
        // 使用全局统计，而不是从今日队列中计算（学习中的笔记通常 dueDate 在几小时后，不在今日队列中）
        let newCount = stats.newCount
        let learningCount = stats.learningCount
        
        ScrollView {
            VStack(spacing: 18) {
                // 顶部统计卡片
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今日概览")
                                .textStyle(.sectionTitle)
                                .foregroundColor(.secondary)
                            Text("\(stats.streakDays) 天连续打卡")
                                .textStyle(.screenTitle)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Image(systemName: "flame.fill")
                            .textStyle(.screenTitle)
                            .foregroundColor(.orange)
                    }
                    
                    HStack(spacing: 12) {
                        StatCard(title: "待复习", value: "\(queue.count)",
                                 systemImage: "doc.richtext.fill",
                                 color: .blue, highlight: queue.count > 0)
                        StatCard(title: "新笔记", value: "\(newCount)",
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
                                .textStyle(.screenTitle)
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("今日已完成")
                                    .textStyle(.subsectionTitle)
                                    .foregroundColor(.green)
                                Text("明天再来巩固记忆吧！")
                                    .textStyle(.secondaryText)
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
                                    .textStyle(.screenTitle)
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("开始复习")
                                    .textStyle(.subsectionTitle)
                                Text("共 \(queue.count) 篇笔记待复习 · 预计用时 \(estimatedTime(for: queue))")
                                    .textStyle(.secondaryText)
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
                            .textStyle(.sectionTitle)
                        Spacer()
                    }
                    WeeklyChartView(counts: stats.weeklyReviewCounts)
                        .frame(height: 140)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                
                // 按文件夹复习
                VStack(alignment: .leading, spacing: 10) {
                    Text("按文件夹复习")
                        .textStyle(.sectionTitle)
                    // 使用缓存的文件夹列表，避免每次 body 刷新都重新计算
                    let allFolders = cachedFolders ?? []
                    let displayedFolders = Array(allFolders.prefix(folderDisplayCount))
                    if cachedFolders == nil {
                        // 初次加载中
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("加载文件夹...")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if allFolders.isEmpty {
                        Text("暂无需要复习的文件夹")
                            .foregroundColor(.secondary)
                            .textStyle(.secondaryText)
                    }
                    ForEach(displayedFolders) { folder in
                        let count = scheduler.getTodayDueCount(in: folder.id)
                        let folderPath = storage.getFolderPath(for: folder.id)
                        NavigationLink {
                            ReviewSessionView(folderId: folder.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                        .textStyle(.secondaryText)
                                        .lineLimit(1)
                                    // 显示完整文件夹路径
                                    Text(folderPath)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if count > 0 {
                                    Text("\(count)")
                                        .textStyle(.subsectionTitle)
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
                    // 滚动到底部自动加载更多文件夹
                    if displayedFolders.count < allFolders.count {
                        HStack {
                            Spacer()
                            if isLoadingFolders {
                                ProgressView()
                                    .padding(.vertical, 8)
                                Text("加载中...")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            } else {
                                Text("加载更多")
                                    .foregroundColor(.blue)
                                    .font(.subheadline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .onAppear {
                            guard !isLoadingFolders else { return }
                            isLoadingFolders = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                folderDisplayCount += 10
                                isLoadingFolders = false
                            }
                        }
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
        .onAppear {
            stats = scheduler.computeStats()
            // 异步计算文件夹列表，避免阻塞主线程影响初次加载性能
            DispatchQueue.global(qos: .userInitiated).async {
                let folders = storage.getAllFolders().filter { folder in
                    let dueCount = scheduler.getTodayDueCount(in: folder.id)
                    let noteCount = storage.countNotesRecursive(in: folder.id)
                    return dueCount > 0 || noteCount > 0
                }
                DispatchQueue.main.async {
                    cachedFolders = folders
                }
            }
        }
        .fullScreenCover(isPresented: $showingReview) {
            NavigationStack {
                ReviewSessionView(folderId: nil)
            }
        }
    }
    
    /// 按笔记字数计算预计复习用时（考虑性能：只采样前10篇计算平均字数）
    private func estimatedTime(for notes: [Note]) -> String {
        guard !notes.isEmpty else { return "0 分钟" }
        
        // 为了性能，只采样前10篇笔记计算平均字数
        let sampleCount = min(10, notes.count)
        var totalChars = 0
        for i in 0..<sampleCount {
            // 只统计正文字数，去掉 markdown 标记符号的粗略估算
            let content = notes[i].markdownContent
            totalChars += content.count
        }
        let avgCharsPerNote = totalChars / sampleCount
        let estimatedTotalChars = avgCharsPerNote * notes.count
        
        // 阅读速度：复习时约 200 字/分钟（需要思考，比正常阅读慢）
        let readingMinutes = Double(estimatedTotalChars) / 200.0
        // 评级操作：每篇约 6 秒（0.1 分钟）
        let ratingMinutes = Double(notes.count) * 0.1
        // 总时间
        let totalMinutes = Int(ceil(readingMinutes + ratingMinutes))
        
        if totalMinutes < 60 {
            return "\(max(1, totalMinutes)) 分钟"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            if mins == 0 {
                return "\(hours) 小时"
            } else {
                return "\(hours) 小时 \(mins) 分"
            }
        }
    }
}
