//
//  NoteEditorView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 笔记编辑器：可切换编辑/预览，修改标题、标签、Markdown内容
struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let noteId: UUID
    
    @State private var originalNote: Note?
    @State private var title: String = ""
    @State private var tagsText: String = ""
    @State private var markdownText: String = ""
    @State private var mode: Mode = .edit      // edit / preview / split
    @State private var isSaving = false
    @State private var hasChanges = false
    
    enum Mode {
        case edit, preview, split
    }
    
    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            
            Divider()
            
            // 内容区
            Group {
                switch mode {
                case .edit:
                    editorBody
                case .preview:
                    previewBody
                case .split:
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            editorBody.frame(width: geo.size.width / 2)
                            Divider()
                            previewBody.frame(width: geo.size.width / 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("编辑笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    if hasChanges {
                        // 不保存直接关闭
                    }
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() }
                    else { Text("保存").bold().disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
        }
        .onAppear { load() }
    }
    
    // MARK: - 顶部栏
    
    private var editorHeader: some View {
        VStack(spacing: 8) {
            TextField("标题", text: $title)
                .textStyle(.sectionTitle)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .onChange(of: title) { _ in hasChanges = true }
            
            TextField("标签（用逗号分隔）", text: $tagsText)
                .textStyle(.body)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .onChange(of: tagsText) { _ in hasChanges = true }
            
            // 模式切换
            Picker("", selection: $mode) {
                Label("编辑", systemImage: "pencil").tag(Mode.edit)
                Label("分屏", systemImage: "square.split.2x1").tag(Mode.split)
                Label("预览", systemImage: "eye.fill").tag(Mode.preview)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - 编辑器
    
    private var editorBody: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $markdownText)
                .font(.system(.body, design: .monospaced))
                .padding()
                .onChange(of: markdownText) { _ in hasChanges = true }
                .scrollContentBackground(.hidden)
            
            // 快捷插入按钮
            HStack(spacing: 6) {
                QuickBtn(label: "#") { insert("# ") }
                QuickBtn(label: "##") { insert("## ") }
                QuickBtn(label: "H3") { insert("### ") }
                QuickBtn(label: "**B**") { wrap("**") }
                QuickBtn(label: "*I*") { wrap("*") }
                QuickBtn(label: "`") { wrap("`") }
                QuickBtn(label: "-") { insert("\n- ") }
                QuickBtn(label: "```") { insert("\n```\n\n```\n") }
                QuickBtn(label: ">") { insert("\n> ") }
                QuickBtn(label: "[ ]") { insert("[描述](链接)") }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }
    
    private struct QuickBtn: View {
        let label: String
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(label)
                    .textStyle(.tertiaryText)
                    .frame(width: 34, height: 30)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - 预览
    
    private var previewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(title)
                        .textStyle(.screenTitle)
                        .padding(.bottom, 4)
                }
                let md = markdownText.isEmpty ? "（内容为空）" : markdownText
                MarkdownView(markdown: md)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
    
    // MARK: - 工具方法
    
    private func insert(_ text: String) {
        // 简单实现：追加到末尾
        markdownText += text
        hasChanges = true
    }
    
    private func wrap(_ wrapText: String) {
        markdownText += wrapText + "" + wrapText
        hasChanges = true
    }
    
    private func load() {
        guard let n = appState.storage.getNote(id: noteId) else { return }
        originalNote = n
        title = n.title
        markdownText = n.markdownContent
        tagsText = n.tags.joined(separator: ", ")
        hasChanges = false
    }
    
    private func save() {
        guard var note = originalNote else { return }
        let finalTitle = title.trimmingCharacters(in: .whitespaces)
        guard !finalTitle.isEmpty else { return }
        
        isSaving = true
        let tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        note.title = finalTitle
        note.markdownContent = markdownText
        note.tags = tags
        note.updatedAt = Date()
        
        // 先更新本地
        appState.storage.updateNote(note)
        appState.refreshStats()
        hasChanges = false
        
        // 异步上传到云端（不阻塞 UI）
        let noteId = note.id
        appState.uploadSingleNote(noteId: noteId) { _ in
            // 上传完成后刷新
            DispatchQueue.main.async {
                appState.storage.triggerRefresh()
            }
        }
        
        isSaving = false
        dismiss()
    }
}
