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
    let noteContent: String
    let config: BailianConfig
    let knowledgeService = KnowledgeService.shared
    
    @State private var displayedText = ""
    @State private var isLoading = true
    @State private var fullText = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                    .cornerRadius(12)
                    
                    // 详解内容
                    if isLoading && displayedText.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在生成详解...")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(displayedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // 打字机光标
                        if isLoading {
                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(width: 2, height: 16)
                                    .opacity(0.6)
                                Text("正在输入...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // 来源提示
                    if !isLoading && !displayedText.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("详解已生成并缓存")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
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
        if let cached = knowledgeService.loadExplanation(for: point.id) {
            displayedText = cached
            fullText = cached
            isLoading = false
            return
        }
        
        isLoading = true
        displayedText = ""
        
        knowledgeService.explainKeyword(
            point: point,
            noteContent: noteContent,
            config: config,
            onChunk: { chunk in
                displayedText += chunk
            },
            completion: { finalText in
                fullText = finalText
                isLoading = false
            }
        )
    }
}
