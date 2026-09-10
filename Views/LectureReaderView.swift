//
//  LectureReaderView.swift
//  AnkiNotes
//
//  课堂讲稿阅读页面 - 听书风格
//

import SwiftUI

/// 课堂讲稿阅读视图（听书风格）
struct LectureReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    
    let note: Note
    let folderPath: String
    let lectureContent: String
    let stopOnDismiss: Bool  // 关闭页面时是否停止播放（笔记页面true，复习页面false）
    
    @State private var isPlaying = false
    @State private var isPaused = false
    @State private var isLoading = false  // TTS是否正在加载音频
    @State private var currentSentenceIndex = 0
    @State private var totalSentences = 0
    @State private var currentSentence = ""
    @State private var showSpeedMenu = false
    @State private var sentences: [String] = []  // 分句列表（优先使用 TTSService 的分句结果，确保索引体系一致）
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 讲稿内容滚动区
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // 笔记信息
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title)
                                    .font(.headline)
                                if !folderPath.isEmpty {
                                    Text(folderPath)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)                            
                            Divider()
                            
                            // 讲稿内容（按句子显示，当前朗读句子高亮）
                            if sentences.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                    Text("讲稿内容为空")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    if lectureContent.isEmpty {
                                        Text("讲稿文件可能未同步到本地，请先在笔记菜单下拉同步")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                                        Text(sentence)
                                            .font(.appBody)
                                            .foregroundColor(index == currentSentenceIndex ? .brandPrimary : .textPrimary)
                                            .background(index == currentSentenceIndex ? Color.brandPrimaryLight : Color.clear)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(index)
                                            .onTapGesture {
                                                jumpToSentence(index)
                                            }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 20)
                            }
                        }
                    }
                    .onChange(of: currentSentenceIndex) { _ in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(currentSentenceIndex, anchor: .center)
                        }
                    }
                }
                
                // 底部播放控制栏（听书风格）
                playerControlBar
            }
            .navigationTitle("课堂讲稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        // 复习页面打开的讲稿：点完成不暂停播放，关闭复习页面时才暂停
                        // 笔记页面打开的讲稿：点完成时停止播放但【保留进度】（重新打开可恢复）
                        if stopOnDismiss {
                            saveProgress()
                            TTSService.shared.stop()
                            isPlaying = false
                            isPaused = false
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                // 【修复】优先使用 TTSService 的分句结果，确保视图与 TTS 引擎使用同一套索引体系
                // 避免两处独立分句因 Unicode 处理差异导致句子数量/索引不一致
                if TTSService.shared.isSpeaking && !TTSService.shared.sentences.isEmpty {
                    sentences = TTSService.shared.sentences
                } else {
                    sentences = TTSService.splitIntoSentences(lectureContent)
                }
                totalSentences = sentences.count
                if !sentences.isEmpty {
                    currentSentence = sentences[0]
                }
                
                // 从 TTSService 同步当前播放状态（解决熄屏后回到页面状态不同步的问题）
                let ttsIsSpeaking = TTSService.shared.isSpeaking
                let ttsIsPaused = TTSService.shared.isPaused
                let ttsCurrentIndex = TTSService.shared.currentSentenceIndex
                let ttsCurrentText = TTSService.shared.currentText
                
                // 判断 TTSService 是否正在播放当前讲稿（通过当前句子文本是否属于本讲稿内容来判断）
                let textMatchesCurrentLecture = !ttsCurrentText.isEmpty
                    && lectureContent.contains(String(ttsCurrentText.prefix(20)))
                
                // 如果 TTSService 正在播放/暂停当前讲稿，同步实时状态（保留进度）
                // 【修复】TTSService 现在始终使用全文分句，索引与本页 1:1 对应
                if ttsIsSpeaking && textMatchesCurrentLecture && ttsCurrentIndex < sentences.count {
                    let actualIndex = ttsCurrentIndex
                    if actualIndex >= 0 && actualIndex < sentences.count {
                        isPlaying = true
                        isPaused = ttsIsPaused
                        currentSentenceIndex = actualIndex
                        currentSentence = sentences[actualIndex]
                    }
                } else {
                    // TTSService 未在播放当前讲稿（已停止/切到其他讲稿），从持久化进度恢复
                    let saved = loadSavedProgress()
                    if saved > 0 {
                        currentSentenceIndex = saved
                        currentSentence = sentences[saved]
                    }
                }
            }
            .onReceive(TTSService.shared.$isLoading) { loading in
                isLoading = loading
            }
            // 【修复】监听 TTSService 播放状态变化，实时同步本地状态
            .onReceive(TTSService.shared.$isSpeaking) { speaking in
                if speaking {
                    isPlaying = true
                }
                // 不在这里设置 isPlaying = false，因为 stop 时会通过 onComplete 回调处理
            }
            .onReceive(TTSService.shared.$isPaused) { paused in
                isPaused = paused
            }
            // 【修复】监听 TTSService 分句结果变化，同步更新本地句子列表（保持索引体系一致）
            .onReceive(TTSService.shared.$sentences) { ttsSentences in
                if !ttsSentences.isEmpty {
                    sentences = ttsSentences
                    totalSentences = ttsSentences.count
                }
            }
            .onReceive(TTSService.shared.$currentSentenceIndex) { newIndex in
                // 只在 TTSService 正在播放时同步索引，避免 stop 后重置为 0 时影响显示
                guard TTSService.shared.isSpeaking else { return }
                // 【修复】TTSService 始终使用全文分句，索引与本页 1:1 对应，无需偏移转换
                let actualIndex = newIndex
                guard actualIndex >= 0 && actualIndex < sentences.count else { return }
                if actualIndex != currentSentenceIndex {
                    currentSentenceIndex = actualIndex
                    currentSentence = sentences[actualIndex]
                }
            }
            .onDisappear {
                // 保存播放进度（暂停/关闭时保留进度，重新打开时恢复）
                // 注意：不在 onDisappear 中停止播放，允许后台继续播放
                if isPlaying || isPaused {
                    saveProgress()
                }
            }
        }
    }
    
    // MARK: - 播放控制栏
    
    private var playerControlBar: some View {
        VStack(spacing: AppSpacing.md) {
            // 进度条（可拖动）
            VStack(spacing: AppSpacing.xs) {
                if totalSentences > 1 {
                    Slider(
                        value: Binding(
                            get: {
                                // 防御：totalSentences<=1 时走 ProgressView 分支，这里避免 0 分母
                                guard totalSentences > 1 else { return 0 }
                                return Double(currentSentenceIndex) / Double(totalSentences - 1)
                            },
                            set: { newValue in
                                let newIndex = Int(newValue * Double(totalSentences - 1))
                                if newIndex != currentSentenceIndex {
                                    jumpToSentence(newIndex)
                                }
                            }
                        ),
                        in: 0...1
                    )
                    .tint(.brandPrimary)
                } else {
                    ProgressView(value: totalSentences > 0 ? 1.0 : 0)
                        .tint(.brandPrimary)
                }
                HStack {
                    Text("\(currentSentenceIndex + 1) / \(totalSentences) 句")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    if isPlaying {
                        Text(currentSentence.isEmpty ? "正在加载..." : "正在朗读")
                            .font(.caption2)
                            .foregroundColor(.brandPrimary)
                    }
                }
            }
            
            // 控制按钮
            HStack(spacing: AppSpacing.xxl) {
                // 语速按钮
                Button {
                    showSpeedMenu = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "gauge")
                            .font(.title3)
                        Text("\(String(format: "%.1f", appState.ttsConfig.rate))x")
                            .font(.caption2)
                    }
                    .foregroundColor(.textSecondary)
                    .frame(width: 44, height: 44)
                }
                .confirmationDialog("选择语速", isPresented: $showSpeedMenu) {
                    Button("0.5x 慢速") { appState.ttsConfig.rate = 0.5 }
                    Button("0.75x 较慢") { appState.ttsConfig.rate = 0.75 }
                    Button("1.0x 正常") { appState.ttsConfig.rate = 1.0 }
                    Button("1.25x 较快") { appState.ttsConfig.rate = 1.25 }
                    Button("1.5x 快速") { appState.ttsConfig.rate = 1.5 }
                    Button("2.0x 极快") { appState.ttsConfig.rate = 2.0 }
                    Button("取消", role: .cancel) {}
                }
                
                Spacer()
                
                // 上一句
                Button {
                    previousSentence()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .foregroundColor(.textPrimary)
                }
                .frame(width: 44, height: 44)
                .disabled(currentSentenceIndex <= 0)
                
                // 播放/暂停
                Button {
                    togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.brandPrimary)
                            .frame(width: 56, height: 56)
                        if isLoading {
                            // 加载状态：旋转动画
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: isPlaying ? (isPaused ? "play.fill" : "pause.fill") : "play.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .disabled(isLoading)
                
                // 下一句
                Button {
                    nextSentence()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .foregroundColor(.textPrimary)
                }
                .frame(width: 44, height: 44)
                .disabled(currentSentenceIndex >= totalSentences - 1)
                
                Spacer()
                
                // 停止
                Button {
                    stopPlaying()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .foregroundColor(.textSecondary)
                }
                .frame(width: 44, height: 44)
                .disabled(!isPlaying && !isPaused)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.md)
        .background(Color.bgCard)
        .shadow(color: .black.opacity(0.1), radius: 8, y: -4)
    }
    
    // MARK: - 播放控制
    
    private func togglePlay() {
        // 【修复】先同步 TTSService 实际状态，避免熄屏后状态不同步
        let ttsSpeaking = TTSService.shared.isSpeaking
        let ttsPaused = TTSService.shared.isPaused
        
        // 如果 TTSService 正在播放但本地状态未同步，先同步
        if ttsSpeaking && !isPlaying {
            isPlaying = true
            isPaused = ttsPaused
        }
        
        if isPlaying {
            if isPaused {
                TTSService.shared.resume()
                isPaused = false
            } else {
                TTSService.shared.pause()
                isPaused = true
                // 暂停时保存进度（关闭后重新打开可恢复）
                saveProgress()
            }
        } else {
            startPlaying()
        }
    }
    
    private func startPlaying() {
        totalSentences = sentences.count
        isPlaying = true
        isPaused = false
        // 【修复】从当前选中的句子开始播放（未播放时点击句子选中某句后，播放不应重置为第一句）
        let startIndex = min(max(currentSentenceIndex, 0), max(sentences.count - 1, 0))
        
        // 构造讲稿相对路径（用于TTS缓存按讲稿目录分层存储）
        // 路径格式：{folderPath}/{noteTitle}
        let lecturePath: String
        if folderPath.isEmpty {
            lecturePath = note.title
        } else {
            lecturePath = "\(folderPath)/\(note.title)"
        }
        
        // 【修复】始终传递完整讲稿文本 + startSentenceIndex，避免对子文本重新分句导致索引不一致
        TTSService.shared.updateConfig(appState.ttsConfig)
        TTSService.shared.speak(
            text: lectureContent,
            lecturePath: lecturePath,
            startSentenceIndex: startIndex,
            onSentenceComplete: { index in
                // TTSService 使用全文分句，index 即为本页的绝对索引
                DispatchQueue.main.async {
                    let nextIndex = index + 1
                    if nextIndex < sentences.count {
                        currentSentenceIndex = nextIndex
                        currentSentence = sentences[nextIndex]
                    }
                }
            },
            onComplete: {
                DispatchQueue.main.async {
                    isPlaying = false
                    isPaused = false
                    currentSentenceIndex = 0
                    currentSentence = ""
                    // 播放完毕，清除持久化进度（下次从头开始）
                    clearProgress()
                    clearJumpStart()
                }
            }
        )
        
        if !sentences.isEmpty {
            currentSentence = sentences[startIndex]
        }
    }
    
    private func stopPlaying() {
        TTSService.shared.stop()
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        currentSentence = ""
        // 用户主动停止，清除持久化进度（下次从头开始）
        clearProgress()
        clearJumpStart()
    }
    
    private func previousSentence() {
        guard currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        jumpToSentence(currentSentenceIndex)
    }
    
    private func nextSentence() {
        guard currentSentenceIndex < totalSentences - 1 else { return }
        currentSentenceIndex += 1
        jumpToSentence(currentSentenceIndex)
    }
    
    private func jumpToSentence(_ index: Int) {
        guard index >= 0 && index < sentences.count else { return }
        currentSentenceIndex = index
        currentSentence = sentences[index]
        
        if isPlaying || isPaused {
            // 【修复】使用 TTSService.skipToSentence 跳转，不再重新 speak 子文本
            // TTSService 使用全文分句，索引与本页 1:1 对应
            TTSService.shared.skipToSentence(at: index)
            isPlaying = true
            isPaused = false
        }
    }
    
    // MARK: - 播放进度持久化
    
    /// 讲稿进度存储键（以讲稿路径为唯一标识）
    private var progressKey: String {
        let path = folderPath.isEmpty ? note.title : "\(folderPath)/\(note.title)"
        return "lecture_progress_\(path)"
    }
    
    /// 跳转起始偏移存储键（已废弃，保留仅用于清除旧版持久化数据）
    private var jumpStartKey: String {
        "\(progressKey)_jumpstart"
    }
    
    /// 保存当前播放进度（暂停/关闭页面时调用）
    private func saveProgress() {
        UserDefaults.standard.set(currentSentenceIndex, forKey: progressKey)
    }
    
    /// 读取已保存的播放进度（越界时返回 0）
    private func loadSavedProgress() -> Int {
        let saved = UserDefaults.standard.integer(forKey: progressKey)
        guard saved >= 0 && saved < sentences.count else { return 0 }
        return saved
    }
    
    /// 清除播放进度（播放完毕或主动停止时调用）
    private func clearProgress() {
        UserDefaults.standard.removeObject(forKey: progressKey)
    }
    
    /// 清除旧的跳转起始偏移（播放完毕或主动停止时调用，清理旧版持久化数据）
    private func clearJumpStart() {
        UserDefaults.standard.removeObject(forKey: jumpStartKey)
    }
}
