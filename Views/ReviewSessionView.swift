//
//  ReviewSessionView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// Anki 风格的复习会话：一张张卡片翻转、评级
struct ReviewSessionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var folderId: UUID?
    
    @State private var queue: [Note] = []
    @State private var currentIndex = 0
    @State private var cardStartTime = Date()
    @State private var reviewedCount = 0
    @State private var sessionComplete = false
    
    // 动画
    @State private var cardDegrees: Double = 0
    @State private var offsetX: CGFloat = 0
    
    // 测评
    @State private var showReviewQuiz = false  // 是否显示测评界面
    
    var body: some View {
        Group {
            if queue.isEmpty {
                EmptyStateView(
                    "没有需要复习的卡片",
                    systemImage: "checkmark.circle.fill",
                    description: Text("所有内容已到期复习完毕！")
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            } else if sessionComplete {
                sessionSummaryView
            } else {
                reviewFlowView
            }
        }
        .navigationTitle(folderId == nil ? "复习" : "文件夹复习")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bootstrap() }
        .onDisappear { appState.refreshStats() }
    }
    
    // MARK: - 初始化
    
    private func bootstrap() {
        let scheduler = appState.scheduler!
        queue = scheduler.getTodayReviewQueue(in: folderId)
        cardStartTime = Date()
    }
    
    // MARK: - 复习流程
    
    private var reviewFlowView: some View {
        let scheduler = appState.scheduler!
        let note = queue[currentIndex]
        let progress = Double(reviewedCount) / Double(queue.count)
        
        return VStack(spacing: 0) {
            // 顶部进度条 + 关闭
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .textStyle(.screenTitle)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(reviewedCount) / \(queue.count)")
                    .textStyle(.primaryText)
                    .foregroundColor(.secondary)
                Spacer()
                Text("已学 \(Int(progress * 100))%")
                    .textStyle(.tertiaryText)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            ProgressView(value: progress)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            
            // 笔记内容区（直接展示完整内容，取消翻卡机制）
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 笔记标题和状态
                    HStack(spacing: 8) {
                        stateLabel(note.srs.cardState)
                        Text(note.title)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        let sched = SM2Algorithm.dueDescription(note.srs.dueDate)
                        Text(sched)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // 完整笔记内容
                    MarkdownView(markdown: note.markdownContent)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
            // 评级按钮（直接显示，不需要先翻卡）
            ratingButtons(note: note, scheduler: scheduler)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        // 测评界面
        .sheet(isPresented: $showReviewQuiz) {
            if let note = currentIndex < queue.count ? queue[currentIndex] : nil {
                ReviewQuizView(
                    note: note,
                    quizService: appState.quizService,
                    onComplete: { rating in
                        showReviewQuiz = false
                        // 延迟应用评级，等 sheet 关闭动画完成
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            applyRating(rating)
                        }
                    }
                )
            }
        }
    }
    
    private func stateLabel(_ state: SRSData.CardState) -> some View {
        let mapping: [(SRSData.CardState, String, Color)] = [
            (.new, "新", .blue),
            (.learning, "学", .orange),
            (.relearning, "重学", .red),
            (.review, "复习", .green)
        ]
        let result = mapping.first(where: { $0.0 == state }) ?? (.new, "新", .blue)
        return Text(result.1)
            .textStyle(.tertiaryText)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(result.2.opacity(0.15))
            .foregroundColor(result.2)
            .cornerRadius(6)
    }
    
    // MARK: - 评级按钮
    
    @ViewBuilder
    private func ratingButtons(note: Note, scheduler: SchedulerService) -> some View {
        VStack(spacing: 10) {
            Text("请根据对笔记内容的掌握程度选择评级")
                .textStyle(.secondaryText)
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                ForEach(ReviewRating.allCases) { rating in
                    Button {
                        applyRating(rating)
                    } label: {
                        VStack(spacing: 4) {
                            Text(rating.description)
                                .textStyle(.subsectionTitle)
                            Text(scheduler.previewNextInterval(note: note, rating: rating))
                                .textStyle(.miniText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: rating.color).opacity(0.14))
                        .foregroundColor(Color(hex: rating.color))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: rating.color).opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                
                // 测评按钮：仅当该笔记已生成题目时显示，放在右侧
                if appState.quizService.generatedNoteIds.contains(note.id) {
                    Button {
                        showReviewQuiz = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "doc.questionmark")
                                .font(.subheadline)
                            Text("测评")
                                .textStyle(.subsectionTitle)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.purple.opacity(0.14))
                        .foregroundColor(.purple)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 操作
    
    private func applyRating(_ rating: ReviewRating) {
        guard currentIndex < queue.count else { return }
        let note = queue[currentIndex]
        let spent = Date().timeIntervalSince(cardStartTime)
        _ = appState.scheduler.rate(noteId: note.id, rating: rating, timeSpent: spent)
        reviewedCount += 1
        
        // 过渡动画
        withAnimation(.easeOut(duration: 0.2)) {
            offsetX = 400
            cardDegrees = 20
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if currentIndex + 1 >= queue.count {
                sessionComplete = true
            } else {
                currentIndex += 1
                offsetX = 0
                cardDegrees = 0
                cardStartTime = Date()
            }
        }
    }
    
    // MARK: - 复习总结
    
    private var sessionSummaryView: some View {
        let stats = appState.scheduler.computeStats()
        return VStack(spacing: 24) {
            Spacer()
            Image(systemName: "trophy.fill")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .top, endPoint: .bottom)
                )
                .padding()
            
            Text("本次复习完成！")
                .textStyle(.screenTitle)
            
            VStack(spacing: 16) {
                SummaryRow(label: "复习卡片", value: "\(reviewedCount) 张", systemImage: "doc.richtext.fill", color: .blue)
                SummaryRow(label: "今日累计", value: "\(stats.reviewedToday) 张", systemImage: "checkmark.seal.fill", color: .green)
                SummaryRow(label: "连续打卡", value: "\(stats.streakDays) 天", systemImage: "flame.fill", color: .orange)
                SummaryRow(label: "剩余待复习", value: "\(appState.scheduler.getTodayDueCount()) 张", systemImage: "clock.fill", color: .purple)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            .padding(.horizontal, 20)
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String
    let systemImage: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: systemImage)
                    .foregroundColor(color)
            }
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .textStyle(.subsectionTitle)
        }
    }
}
