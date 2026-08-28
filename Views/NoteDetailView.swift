//
//  NoteDetailView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 笔记详情页：Markdown 预览 + 信息 + 编辑入口
struct NoteDetailView: View {
    @EnvironmentObject var appState: AppState
    let noteId: UUID
    
    @State private var note: Note?
    @State private var showEditor = false
    @State private var showCardFlip = false
    @State private var showMoveFolder = false
    @State private var selectedFolderId: UUID?
    @State private var selectedRating: ReviewRating?
    @State private var previewStartTime: Date = Date()
    
    var body: some View {
        Group {
            if let note = note {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        // 卡片区域（类似 Anki 正反面）
                        cardPreviewSection(note)
                        
                        // 完整 Markdown 内容
                        sectionHeader("完整内容")
                        MarkdownView(markdown: note.markdownContent)
                            .padding(.horizontal, 4)
                        
                        // SRS 信息
                        sectionHeader("记忆数据")
                        srsInfoView(note)
                        
                        // 复习历史
                        sectionHeader("复习历史")
                        reviewHistoryView(note)
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(note.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showEditor = true
                            } label: {
                                Label("编辑 Markdown", systemImage: "pencil")
                            }
                            Button {
                                showMoveFolder = true
                            } label: {
                                Label("移动到文件夹", systemImage: "folder")
                            }
                            Button(role: .destructive) {
                                deleteNote()
                            } label: {
                                Label("删除笔记", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showEditor) {
                    NavigationStack {
                        NoteEditorView(noteId: noteId)
                    }
                }
                .sheet(isPresented: $showMoveFolder) {
                    NavigationStack {
                        FolderPickerView(selectedFolderId: $selectedFolderId)
                            .navigationTitle("选择目标文件夹")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("取消") { showMoveFolder = false }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("移动") {
                                        moveNoteTo(folderId: selectedFolderId)
                                        showMoveFolder = false
                                    }
                                    .bold()
                                }
                            }
                    }
                    .onAppear { selectedFolderId = note.folderId }
                }
            } else {
                ContentUnavailableView("笔记不存在或已删除", systemImage: "trash")
            }
        }
        .onAppear { loadNote() }
        .onDisappear { appState.refreshStats() }
    }
    
    // MARK: - 分区
    
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }
    
    // MARK: - 卡片预览区
    
    @ViewBuilder
    private func cardPreviewSection(_ note: Note) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                VStack(spacing: 16) {
                    Text("卡片预览")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // 正面
                    VStack {
                        Text("正面（问题）").font(.subheadline.bold()).foregroundColor(.blue)
                        MarkdownView(markdown: "# \(note.cardFront)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.blue.opacity(0.06))
                            .cornerRadius(10)
                    }
                    
                    if showCardFlip {
                        // 背面
                        VStack {
                            Text("背面（答案）").font(.subheadline.bold()).foregroundColor(.green)
                            if note.cardBack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("（背面暂无内容）")
                                    .foregroundColor(.secondary)
                                    .padding()
                            } else {
                                MarkdownView(markdown: note.cardBack)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .background(Color.green.opacity(0.06))
                                    .cornerRadius(10)
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    
                    Button {
                        withAnimation(.spring()) {
                            showCardFlip.toggle()
                        }
                    } label: {
                        Label(showCardFlip ? "隐藏答案" : "显示答案",
                              systemImage: showCardFlip ? "eye.slash.fill" : "eye.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemBlue))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .bold()
                    }
                    
                    if showCardFlip {
                        quickRatingView(note)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { previewStartTime = Date() }
    }
    
    @ViewBuilder
    private func quickRatingView(_ note: Note) -> some View {
        HStack(spacing: 8) {
            ForEach(ReviewRating.allCases) { rating in
                Button {
                    selectedRating = rating
                    applyQuickRating(rating, to: note)
                } label: {
                    VStack(spacing: 4) {
                        Text(rating.shortLabel).bold()
                        Text(appState.scheduler.previewNextInterval(note: note, rating: rating))
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(hex: rating.color).opacity(0.18))
                    .foregroundColor(Color(hex: rating.color))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - SRS 信息
    
    @ViewBuilder
    private func srsInfoView(_ note: Note) -> some View {
        let srs = note.srs
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            InfoChip(label: "状态", value: srs.cardState.rawValue)
            InfoChip(label: "复习次数", value: "\(srs.repetitions)")
            InfoChip(label: "间隔", value: "\(srs.interval) 天")
            InfoChip(label: "容易度 EF", value: String(format: "%.2f", srs.easeFactor))
            InfoChip(label: "最后复习",
                     value: srs.lastReviewDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            InfoChip(label: "下次复习", value: srs.dueDate.formatted(date: .abbreviated, time: .shortened))
        }
    }
    
    // MARK: - 复习历史
    
    @ViewBuilder
    private func reviewHistoryView(_ note: Note) -> some View {
        let logs = appState.storage.getReviewLogs(for: note.id)
        if logs.isEmpty {
            Text("（尚无复习记录）")
                .foregroundColor(.secondary)
                .font(.callout)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(logs.prefix(10).enumerated()), id: \.element.id) { idx, log in
                    HStack {
                        Circle()
                            .fill(Color(hex: log.rating.color))
                            .frame(width: 10, height: 10)
                        Text(log.rating.description)
                            .font(.subheadline.bold())
                        Spacer()
                        Text("\(log.oldInterval)d → \(log.newInterval)d")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(log.reviewDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    if idx < min(logs.count, 10) - 1 { Divider().padding(.leading, 30) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        }
    }
    
    // MARK: - 操作
    
    private func loadNote() {
        note = appState.storage.getNote(id: noteId)
    }
    
    private func applyQuickRating(_ rating: ReviewRating, to note: Note) {
        let spent = Date().timeIntervalSince(previewStartTime)
        _ = appState.scheduler.rate(noteId: note.id, rating: rating, timeSpent: spent)
        loadNote()
        showCardFlip = false
        previewStartTime = Date()
    }
    
    private func moveNoteTo(folderId: UUID?) {
        guard var note = note else { return }
        note.folderId = folderId
        appState.storage.updateNote(note)
        loadNote()
    }
    
    private func deleteNote() {
        appState.storage.deleteNote(id: noteId)
        note = nil
        appState.refreshStats()
    }
}

// MARK: - InfoChip

private struct InfoChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white)
        .cornerRadius(10)
    }
}

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - 文件夹选择器

struct FolderPickerView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedFolderId: UUID?
    @State private var currentParentId: UUID? = nil
    
    private var storage: StorageService { appState.storage! }
    
    var body: some View {
        List {
            Button {
                selectedFolderId = nil
            } label: {
                HStack {
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                        .frame(width: 28)
                    Text("根目录（无文件夹）")
                    Spacer()
                    if selectedFolderId == nil {
                        Image(systemName: "checkmark").foregroundColor(.blue)
                    }
                }
            }
            .tint(.primary)
            
            let subFolders = storage.getSubFolders(of: currentParentId)
            if let parent = currentParentId {
                let parentFolder = storage.getFolder(id: parent)
                Button {
                    currentParentId = parentFolder?.parentId
                } label: {
                    Label("上级文件夹", systemImage: "chevron.up")
                }
            }
            ForEach(subFolders) { folder in
                HStack {
                    Button {
                        currentParentId = folder.id
                    } label: {
                        Label(folder.name, systemImage: "folder.fill")
                            .foregroundColor(.yellow)
                    }
                    Spacer()
                    Button {
                        selectedFolderId = folder.id
                    } label: {
                        if selectedFolderId == folder.id {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        } else {
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
