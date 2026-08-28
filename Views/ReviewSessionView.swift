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
    @State private var showAnswer = false
    @State private var cardStartTime = Date()
    @State private var reviewedCount = 0
    @State private var sessionComplete = false
    
    // 动画
    @State private var cardDegrees: Double = 0
    @State private var offsetX: CGFloat = 0
    
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
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(reviewedCount) / \(queue.count)")
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("已学 \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            ProgressView(value: progress)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            
            // 卡片区
            ZStack {
                // 卡片本体
                ZStack {
                    // 正面
                    cardFace(front: true, note: note)
                        .opacity(showAnswer ? 0 : 1)
                        .rotation3DEffect(.degrees(showAnswer ? 90 : 0), axis: (x: 0, y: 1, z: 0))
                    // 背面
                    cardFace(front: false, note: note)
                        .opacity(showAnswer ? 1 : 0)
                        .rotation3DEffect(.degrees(showAnswer ? 0 : -90), axis: (x: 0, y: 1, z: 0))
                }
                .rotation3DEffect(.degrees(cardDegrees), axis: (x: 0, y: 1, z: 0))
                .offset(x: offsetX)
                .gesture(
                    TapGesture()
                        .onEnded {
                            if !showAnswer { flipCard() }
                        }
                )
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offsetX = v.translation.width
                            cardDegrees = Double(v.translation.width / 20)
                        }
                        .onEnded { v in
                            if abs(v.translation.width) > 150 {
                                // 滑走，跳过或显示答案
                                withAnimation(.easeOut) {
                                    offsetX = v.translation.width > 0 ? 500 : -500
                                    cardDegrees = v.translation.width > 0 ? 20 : -20
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    offsetX = 0
                                    cardDegrees = 0
                                    if !showAnswer { flipCard() }
                                    else { applyRating(.good) }
                                }
                            } else {
                                withAnimation { offsetX = 0; cardDegrees = 0 }
                            }
                        }
                )
                
                if !showAnswer {
                    VStack {
                        Spacer()
                        Text("点击卡片显示答案")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 20)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            
            // 评级按钮
            if showAnswer {
                ratingButtons(note: note, scheduler: scheduler)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button {
                    flipCard()
                } label: {
                    Text("显示答案")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - 卡片面
    
    @ViewBuilder
    private func cardFace(front: Bool, note: Note) -> some View {
        let content = front ? note.cardFront : (note.cardBack.isEmpty ? "（暂无答案内容）" : note.cardBack)
        let color = front ? Color.blue : Color.green
        VStack(alignment: .leading, spacing: 14) {
            // 顶部标签
            HStack(spacing: 8) {
                Text(front ? "正面" : "背面")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color.opacity(0.18))
                    .foregroundColor(color)
                    .cornerRadius(6)
                stateLabel(note.srs.cardState)
                Spacer()
                let sched = SM2Algorithm.dueDescription(note.srs.dueDate)
                Text(sched)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            ScrollView {
                if front {
                    MarkdownView(markdown: "# " + content, bodyFont: .title2, textColor: .primary)
                } else {
                    MarkdownView(markdown: content)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(color.opacity(0.25), lineWidth: 1.5)
        )
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
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(result.2.opacity(0.15))
            .foregroundColor(result.2)
            .cornerRadius(6)
    }
    
    // MARK: - 评级按钮
    
    private var shortcutButtons: [(key: String, rating: ReviewRating)] {
        [("1 重来", .again), ("2 困难", .hard), ("3 良好", .good), ("4 简单", .easy)]
    }
    
    @ViewBuilder
    private func ratingButtons(note: Note, scheduler: SchedulerService) -> some View {
        VStack(spacing: 10) {
            Text("你还记得这张卡片吗？")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 10) {
                ForEach(ReviewRating.allCases) { rating in
                    Button {
                        applyRating(rating)
                    } label: {
                        VStack(spacing: 4) {
                            Text(rating.description)
                                .font(.headline.bold())
                            Text(scheduler.previewNextInterval(note: note, rating: rating))
                                .font(.caption2)
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
            }
            
            HStack(spacing: 10) {
                ForEach(shortcutButtons, id: \.key) { info in
                    Button {
                        applyRating(info.rating)
                    } label: {
                        Text(info.key)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.secondary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 操作
    
    private func flipCard() {
        withAnimation(.easeInOut(duration: 0.35)) {
            showAnswer.toggle()
        }
    }
    
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
                showAnswer = false
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
                .font(.system(size: 72))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .top, endPoint: .bottom)
                )
                .padding()
            
            Text("本次复习完成！")
                .font(.title.bold())
            
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
                .font(.headline.bold())
        }
    }
}
