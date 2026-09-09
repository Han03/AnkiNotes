//
//  KnowledgeExplainView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/5.
//

import SwiftUI

/// 知识点详解界面：流式打字机展示大模型回答
struct KnowledgeExplainView: View {
    let point: KnowledgePoint
    let note: Note
    let noteContent: String
    let config: BailianConfig
    let knowledgeService = KnowledgeService.shared
    
    @StateObject private var explanationStore = KnowledgeExplanationStore()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    // 知识点标题
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text(point.keyword)
                            .font(.headline)
                        Spacer()
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(AppCornerRadius.lg)
                    
                    // 详解内容
                    if explanationStore.isLoading && explanationStore.displayedText.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在生成详解...")
                                .foregroundColor(.textSecondary)
                        }
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(explanationStore.displayedText)
                            .font(.appBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // 来源提示
                    if !explanationStore.isLoading && !explanationStore.displayedText.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("详解已生成并缓存")
                                .font(.appCaption)
                                .foregroundColor(.textSecondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .background(Color.bgPage)
            .navigationTitle("知识点详解")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                loadExplanation()
            }
        }
    }
    
    private func loadExplanation() {
        // 检查是否有缓存
        if let cached = knowledgeService.loadExplanation(for: point, note: note) {
            explanationStore.setCached(cached)
            return
        }
        
        explanationStore.reset()
        
        knowledgeService.explainKeyword(
            point: point,
            note: note,
            noteContent: noteContent,
            config: config,
            onChunk: { chunk in
                // 流式打字机效果：使用 ObservableObject 确保异步闭包中修改能触发 UI 更新
                DispatchQueue.main.async {
                    explanationStore.appendChunk(chunk)
                }
            },
            completion: { finalText in
                DispatchQueue.main.async {
                    explanationStore.complete(with: finalText)
                }
            }
        )
    }
}
