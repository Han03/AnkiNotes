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
    
    @State private var isPlaying = false
    @State private var isPaused = false
    @State private var currentSentenceIndex = 0
    @State private var totalSentences = 0
    @State private var currentSentence = ""
    @State private var showSpeedMenu = false
    
    // 分句后的文本
    private var sentences: [String] {
        var result: [String] = []
        let separators = CharacterSet(charactersIn: "。！？!?\n")
        var current = ""
        for char in lectureContent {
            current.append(char)
            if let scalar = char.unicodeScalars.first, separators.contains(scalar) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        return result
    }
    
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
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                                    Text(sentence)
                                        .font(.body)
                                        .foregroundColor(index == currentSentenceIndex && isPlaying ? .orange : .primary)
                                        .background(index == currentSentenceIndex && isPlaying ? Color.orange.opacity(0.1) : Color.clear)
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
                        stopPlaying()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                stopPlaying()
            }
        }
    }
    
    // MARK: - 播放控制栏
    
    private var playerControlBar: some View {
        VStack(spacing: 12) {
            // 进度条
            VStack(spacing: 4) {
                ProgressView(value: totalSentences > 0 ? Double(currentSentenceIndex + 1) / Double(totalSentences) : 0)
                    .tint(.orange)
                HStack {
                    Text("\(currentSentenceIndex + 1) / \(totalSentences) 句")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isPlaying {
                        Text(currentSentence.isEmpty ? "正在加载..." : "正在朗读")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            
            // 控制按钮
            HStack(spacing: 24) {
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
                    .foregroundColor(.secondary)
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
                        .foregroundColor(.primary)
                }
                .frame(width: 44, height: 44)
                .disabled(currentSentenceIndex <= 0)
                
                // 播放/暂停
                Button {
                    togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 56, height: 56)
                        Image(systemName: isPlaying ? (isPaused ? "play.fill" : "pause.fill") : "play.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 56, height: 56)
                
                // 下一句
                Button {
                    nextSentence()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .foregroundColor(.primary)
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
                        .foregroundColor(.secondary)
                }
                .frame(width: 44, height: 44)
                .disabled(!isPlaying && !isPaused)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.1), radius: 8, y: -4)
    }
    
    // MARK: - 播放控制
    
    private func togglePlay() {
        if isPlaying {
            if isPaused {
                TTSService.shared.resume()
                isPaused = false
            } else {
                TTSService.shared.pause()
                isPaused = true
            }
        } else {
            startPlaying()
        }
    }
    
    private func startPlaying() {
        totalSentences = sentences.count
        isPlaying = true
        isPaused = false
        
        TTSService.shared.updateConfig(appState.ttsConfig)
        TTSService.shared.speak(
            text: lectureContent,
            onSentenceComplete: { index in
                DispatchQueue.main.async {
                    currentSentenceIndex = index + 1
                    if currentSentenceIndex < sentences.count {
                        currentSentence = sentences[currentSentenceIndex]
                    }
                }
            },
            onComplete: {
                DispatchQueue.main.async {
                    isPlaying = false
                    isPaused = false
                    currentSentenceIndex = 0
                    currentSentence = ""
                }
            }
        )
        
        if !sentences.isEmpty {
            currentSentence = sentences[0]
        }
    }
    
    private func stopPlaying() {
        TTSService.shared.stop()
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        currentSentence = ""
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
        
        let remainingText = sentences[index...].joined(separator: "")
        TTSService.shared.stop()
        
        if isPlaying || isPaused {
            TTSService.shared.updateConfig(appState.ttsConfig)
            TTSService.shared.speak(
                text: remainingText,
                onSentenceComplete: { idx in
                    DispatchQueue.main.async {
                        currentSentenceIndex = index + idx + 1
                        if currentSentenceIndex < sentences.count {
                            currentSentence = sentences[currentSentenceIndex]
                        }
                    }
                },
                onComplete: {
                    DispatchQueue.main.async {
                        isPlaying = false
                        isPaused = false
                        currentSentenceIndex = 0
                        currentSentence = ""
                    }
                }
            )
            isPlaying = true
            isPaused = false
        }
    }
}
