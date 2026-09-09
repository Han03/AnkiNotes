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
    
    // 评级弹窗
    @State private var showRatingDialog = false  // 是否显示评级选择弹窗
    
    // 播放状态
    @State private var isPlayingLecture = false  // 是否正在播放讲稿
    @State private var isPausedLecture = false  // 讲稿是否暂停
    @State private var lecturePlayProgress: Double = 0  // 讲稿播放进度 (0.0 - 1.0)
    @State private var lectureText: String? = nil  // 当前讲稿文本（用于播放）
    
    // 知识点
    @StateObject private var knowledgeStore = KnowledgePointsStore()  // 知识点状态（使用 ObservableObject 解决异步更新问题）
    @State private var selectedKnowledgePoint: KnowledgePoint? = nil  // 选中的知识点
    @State private var lectureItem: LectureItem? = nil  // 讲稿阅读页面数据（使用 item 方式确保数据正确传递）
    
    var body: some View {
        Group {
            if queue.isEmpty {
                EmptyStateView(
                    "没有需要复习的笔记",
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
        .navigationBarHidden(true)  // 隐藏系统导航栏，使用自定义顶部栏
        .onAppear { bootstrap() }
        .onDisappear {
            // 离开复习界面时停止讲稿播放
            TTSService.shared.stop()
            lectureText = nil
            lecturePlayProgress = 0
            appState.refreshStats()
        }
    }
    
    // MARK: - 初始化
    
    private func bootstrap() {
        let scheduler = appState.scheduler!
        queue = scheduler.getTodayReviewQueue(in: folderId)
        cardStartTime = Date()
        // 提取第一篇笔记的知识点
        extractKnowledgeForCurrentNote()
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 顶部锚点，用于重置滚动位置
                        Color.clear
                            .frame(height: 1)
                            .id("top")
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
                    
                    // 完整笔记内容（带知识点标记）
                    MarkdownView(
                        markdown: note.markdownContent,
                        knowledgePoints: knowledgeStore.points,
                        onKnowledgeTap: { point in
                            selectedKnowledgePoint = point
                        }
                    )
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 切换笔记时重置滚动位置到顶部
                .onChange(of: currentIndex) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
            // 底部操作栏（主按钮+图标按钮组合，背景延伸至屏幕底部）
            bottomOperationBar(note: note, scheduler: scheduler)
        }
        .background(Color(.systemGroupedBackground))
        // 监听 TTSService 播放状态
        .onReceive(TTSService.shared.$isSpeaking) { speaking in
            isPlayingLecture = speaking
            if !speaking {
                isPausedLecture = false
                lecturePlayProgress = 0
            }
        }
        .onReceive(TTSService.shared.$isPaused) { paused in
            isPausedLecture = paused
        }
        // 评级选择弹窗
        .confirmationDialog("请选择掌握程度评级", isPresented: $showRatingDialog) {
            ForEach(ReviewRating.allCases) { rating in
                Button("\(rating.description)（\(scheduler.previewNextInterval(note: queue[currentIndex], rating: rating))）") {
                    applyRating(rating)
                }
            }
            Button("取消", role: .cancel) {}
        }
        // 测评界面
        .sheet(isPresented: $showReviewQuiz) {
            if let note = currentIndex < queue.count ? queue[currentIndex] : nil {
                ReviewQuizView(
                    note: note,
                    folderPath: appState.storage?.getNoteFolderPath(for: note) ?? "",
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
        // 知识点详解界面
        .sheet(item: $selectedKnowledgePoint) { point in
            if currentIndex < queue.count {
                KnowledgeExplainView(
                    point: point,
                    note: queue[currentIndex],
                    noteContent: queue[currentIndex].markdownContent,
                    config: appState.bailianConfig
                )
            }
        }
        // 讲稿阅读页面（使用 fullScreenCover item 方式，确保数据正确传递）
        // 复习页面打开的讲稿：点完成不暂停播放，关闭复习页面时才暂停
        .fullScreenCover(item: $lectureItem) { item in
            LectureReaderView(
                note: item.note,
                folderPath: item.folderPath,
                lectureContent: item.content,
                stopOnDismiss: false
            )
        }
    }
    
    private func stateLabel(_ state: SRSData.CardState) -> some View {
        // 统一使用中性灰色，状态是辅助信息，不应抢夺视觉重心
        // 避免四色（蓝橙红绿）带来的视觉混乱
        let mapping: [(SRSData.CardState, String)] = [
            (.new, "新"),
            (.learning, "学"),
            (.relearning, "重学"),
            (.review, "复习")
        ]
        let result = mapping.first(where: { $0.0 == state }) ?? (.new, "新")
        return Text(result.1)
            .textStyle(.tertiaryText)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.gray.opacity(0.1))  // 统一极浅灰背景
            .foregroundColor(.secondary)  // 统一次级文字颜色
            .cornerRadius(6)
    }
    
    // MARK: - 底部操作栏（专业UI设计，橙色主色调）
    
    @ViewBuilder
    private func bottomOperationBar(note: Note, scheduler: SchedulerService) -> some View {
        let hasQuiz = appState.quizService.generatedNoteIds.contains(note.id)
        let hasLecture = appState.storage?.hasLecture(for: note) ?? false
        let isPlaying = isPlayingLecture && !isPausedLecture
        let secondaryButtonCount = (hasQuiz ? 1 : 0) + (hasLecture ? 1 : 0) + (hasLecture ? 1 : 0)  // 测评+讲稿+播放
        
        VStack(spacing: 0) {
            // 播放进度条（仅播放/暂停时显示，2pt细条）
            if isPlayingLecture {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Color.gray.opacity(0.1)
                        Color.brandPrimary
                            .frame(width: geometry.size.width * CGFloat(lecturePlayProgress))
                    }
                }
                .frame(height: 2)
            }
            
            // 顶部分割线
            Divider()
                .opacity(0.2)
            
            HStack(spacing: AppSpacing.sm) {
                // 评级主按钮（始终显示，占主要空间）
                ratingButton(note: note, scheduler: scheduler)
                    .frame(maxWidth: .infinity)
                
                // 测评按钮（有题目时显示）
                if hasQuiz {
                    quizButton()
                        .frame(width: 52)
                }
                
                // 讲稿按钮（有讲稿时显示）
                if hasLecture {
                    lectureButton(note: note)
                        .frame(width: 52)
                }
                
                // 播放/暂停按钮（有讲稿时显示）
                if hasLecture {
                    playPauseButton(note: note, isPlaying: isPlaying)
                        .frame(width: 52)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 10)
            .padding(.bottom, 14)  // 进入 Safe Area 约 20pt
        }
        .background(
            Color.bgCard
                .ignoresSafeArea(edges: .bottom)  // 背景延伸到屏幕底部
        )
    }
    
    // MARK: - 评级主按钮（橙色主色调）
    
    private func ratingButton(note: Note, scheduler: SchedulerService) -> some View {
        let recommendedRating = ReviewRating.good
        let previewText = scheduler.previewNextInterval(note: note, rating: recommendedRating)
        
        return Button {
            showRatingDialog = true
        } label: {
            VStack(spacing: 3) {
                Text("评级")
                    .font(.appSubheading)
                Text("\(recommendedRating.description) · \(previewText)")
                    .font(.appTag)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppButtonHeight.standard)  // 统一44pt高度（HIG标准）
            .background(Color.brandPrimaryLight)  // 极浅橙背景
            .foregroundColor(.brandPrimary)  // 橙色主色调
            .cornerRadius(AppCornerRadius.standard)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 测评图标按钮（中性色）
    
    private func quizButton() -> some View {
        Button {
            showReviewQuiz = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 16))
                Text("测评")
                    .font(.appMicro)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppButtonHeight.standard)  // 统一44pt高度
            .background(Color.gray.opacity(0.08))  // 统一极浅灰背景
            .foregroundColor(.textPrimary)  // 中性色
            .cornerRadius(AppCornerRadius.standard)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 讲稿图标按钮（中性色）
    
    private func lectureButton(note: Note) -> some View {
        Button {
            openLecture(note: note)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 16))
                Text("讲稿")
                    .font(.appMicro)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppButtonHeight.standard)  // 统一44pt高度
            .background(Color.gray.opacity(0.08))  // 统一极浅灰背景
            .foregroundColor(.textPrimary)  // 中性色
            .cornerRadius(AppCornerRadius.standard)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 播放/暂停按钮（状态感知，橙色强调）
    
    private func playPauseButton(note: Note, isPlaying: Bool) -> some View {
        Button {
            toggleLecturePlayback(note: note)
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20))
                .frame(maxWidth: .infinity)
                .frame(height: AppButtonHeight.standard)  // 统一44pt高度
                .background(isPlaying ? Color.brandPrimaryLight : Color.gray.opacity(0.08))
                .foregroundColor(isPlaying ? .brandPrimary : .textPrimary)
                .cornerRadius(AppCornerRadius.standard)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 讲稿播放控制
    
    private func toggleLecturePlayback(note: Note) {
        if isPlayingLecture {
            // 正在播放，暂停或恢复
            if isPausedLecture {
                TTSService.shared.resume()
            } else {
                TTSService.shared.pause()
            }
        } else {
            // 未播放，加载讲稿并开始播放
            loadAndPlayLecture(note: note)
        }
    }
    
    private func loadAndPlayLecture(note: Note) {
        guard let storage = appState.storage else { return }
        
        // 如果已有缓存的讲稿文本，直接播放
        if let text = lectureText {
            startLecturePlayback(text: text)
            return
        }
        
        // 异步加载讲稿内容
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try storage.readLecture(for: note)
                DispatchQueue.main.async {
                    lectureText = text
                    startLecturePlayback(text: text)
                }
            } catch {
                SyncLogger.shared.warning("📖 加载讲稿失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func startLecturePlayback(text: String) {
        TTSService.shared.updateConfig(appState.ttsConfig)
        TTSService.shared.speak(
            text: text,
            onSentenceComplete: { index in
                DispatchQueue.main.async {
                    // 更新播放进度
                    let total = TTSService.shared.totalSentences
                    if total > 0 {
                        lecturePlayProgress = Double(index + 1) / Double(total)
                    }
                }
            },
            onComplete: {
                DispatchQueue.main.async {
                    lecturePlayProgress = 1.0
                }
            }
        )
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
                // 切换笔记时重置讲稿播放状态
                TTSService.shared.stop()
                lectureText = nil
                lecturePlayProgress = 0
                // 切换笔记时提取新笔记的知识点
                extractKnowledgeForCurrentNote()
            }
        }
    }
    
    // MARK: - 知识点提取
    
    private func extractKnowledgeForCurrentNote() {
        guard currentIndex < queue.count else { return }
        let note = queue[currentIndex]
        
        knowledgeStore.reset()
        
        // 先检查缓存（即使大模型未配置，也能加载已有的缓存）
        if let cached = KnowledgeService.shared.loadExtraction(for: note) {
            knowledgeStore.setPoints(cached)
            return
        }
        
        // 大模型未配置时，不提取知识点
        guard appState.bailianConfig.isConfigured else {
            return
        }
        
        knowledgeStore.isExtracting = true
        
        KnowledgeService.shared.extractKeywords(
            note: note,
            config: appState.bailianConfig,
            onPoint: { point in
                // 实时标记：使用 ObservableObject 确保异步闭包中修改能触发 UI 更新
                DispatchQueue.main.async {
                    knowledgeStore.addPoint(point)
                }
            },
            completion: { points in
                DispatchQueue.main.async {
                    knowledgeStore.isExtracting = false
                    knowledgeStore.setPoints(points)
                }
            }
        )
    }
    
    // MARK: - 讲稿阅读
    
    private func openLecture(note: Note) {
        guard let storage = appState.storage else {
            SyncLogger.shared.error("📖 ReviewSessionView openLecture: storage 为 nil")
            return
        }
        SyncLogger.shared.info("📖 ReviewSessionView openLecture: note.title=\(note.title), folderId=\(note.folderId?.uuidString ?? "nil")")
        do {
            let content = try storage.readLecture(for: note)
            let folderPath = storage.getNoteFolderPath(for: note) ?? ""
            SyncLogger.shared.info("📖 ReviewSessionView openLecture: 读取成功，内容长度=\(content.count), folderPath=\(folderPath)")
            lectureItem = LectureItem(note: note, folderPath: folderPath, content: content)
        } catch {
            SyncLogger.shared.error("📖 ReviewSessionView openLecture: 读取失败 - \(error.localizedDescription)")
            let folderPath = storage.getNoteFolderPath(for: note) ?? ""
            lectureItem = LectureItem(note: note, folderPath: folderPath, content: "读取讲稿失败：\(error.localizedDescription)")
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
                        colors: [.orange, .orange.opacity(0.7)],  // 统一橙色系
                        startPoint: .top, endPoint: .bottom)
                )
                .padding()
            
            Text("本次复习完成！")
                .textStyle(.screenTitle)
            
            VStack(spacing: 16) {
                // 统一使用橙色主色，避免四色（蓝绿橙紫）带来的视觉混乱
                SummaryRow(label: "复习笔记", value: "\(reviewedCount) 篇", systemImage: "doc.richtext.fill", color: .orange)
                SummaryRow(label: "今日累计", value: "\(stats.reviewedToday) 张", systemImage: "checkmark.seal.fill", color: .orange)
                SummaryRow(label: "连续打卡", value: "\(stats.streakDays) 天", systemImage: "flame.fill", color: .orange)
                SummaryRow(label: "剩余待复习", value: "\(appState.scheduler.getTodayDueCount()) 张", systemImage: "clock.fill", color: .orange)
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
                        LinearGradient(colors: [.orange, .orange.opacity(0.85)],  // 统一橙色系
                                       startPoint: .leading, endPoint: .trailing)
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
