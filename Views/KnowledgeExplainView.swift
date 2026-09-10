//
//  KnowledgeExplainView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/5.
//

import SwiftUI

/// 知识点详解界面：流式打字机展示大模型回答
/// - 有缓存：直接展示缓存内容
/// - 无缓存：LLM 流式生成，由 KnowledgeExplanationStore 以固定节拍刷出打字机效果
///   （网络快慢不影响打字机节奏；失败时保留已生成内容并给出错误提示与重试）
struct KnowledgeExplainView: View {
    let point: KnowledgePoint
    let note: Note
    let noteContent: String
    let config: BailianConfig
    let knowledgeService = KnowledgeService.shared
    
    @StateObject private var explanationStore = KnowledgeExplanationStore()
    @State private var generationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    // 知识点标题
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.brandPrimary)
                        Text(point.keyword)
                            .font(.headline)
                        Spacer()
                    }
                    .padding()
                    .background(Color.brandPrimaryLight)
                    .cornerRadius(AppCornerRadius.lg)
                    
                    // 详解内容
                    if explanationStore.isLoading && explanationStore.displayedText.isEmpty {
                        // 等待首字节（TTFT）阶段
                        HStack {
                            ProgressView()
                            Text("正在生成详解，模型思考中…")
                                .foregroundColor(.textSecondary)
                        }
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                    } else if let error = explanationStore.errorMessage, explanationStore.displayedText.isEmpty {
                        // 完全失败（无任何已生成内容）：错误提示 + 重试
                        VStack(spacing: AppSpacing.md) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title2)
                            Text("生成失败：\(error)")
                                .font(.appBody)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)
                            Button {
                                startGeneration()
                            } label: {
                                Text("重试")
                                    .font(.appBody)
                                    .padding(.horizontal, AppSpacing.lg)
                                    .padding(.vertical, AppSpacing.sm)
                                    .background(Color.brandPrimary)
                                    .foregroundColor(.white)
                                    .cornerRadius(AppCornerRadius.standard)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        // 正常显示：打字机内容（部分失败时附带中断提示）
                        Text(explanationStore.displayedText)
                            .font(.appBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = explanationStore.errorMessage {
                            Text("（生成中断：\(error)）")
                                .font(.appCaption)
                                .foregroundColor(.orange)
                                .padding(.top, 4)
                        }
                    }
                    
                    // 来源提示（成功完成时）
                    if !explanationStore.isLoading && !explanationStore.displayedText.isEmpty && explanationStore.errorMessage == nil {
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
                startGeneration()
            }
            // 注意：不取消生成任务——用户中途退出后任务继续在后台完成并写入缓存，
            // 下次进入直接命中缓存（避免重复消耗 LLM 配额）
        }
    }
    
    private func startGeneration() {
        // 缓存优先
        if let cached = knowledgeService.loadExplanation(for: point, note: note) {
            explanationStore.setCached(cached)
            return
        }
        
        explanationStore.reset()
        
        generationTask = knowledgeService.explainKeyword(
            point: point,
            note: note,
            noteContent: noteContent,
            config: config,
            onChunk: { chunk in
                explanationStore.appendChunk(chunk)
            },
            onError: { message in
                explanationStore.fail(message)
            },
            completion: { _ in
                explanationStore.complete()
            }
        )
    }
}
