//
//  FolderBrowserView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 文件夹浏览视图：展示子文件夹 + 当前文件夹内的笔记列表
struct FolderBrowserView: View {
    @EnvironmentObject var appState: AppState
    var currentFolderId: UUID?
    
    @State private var showNewFolderAlert = false
    @State private var showNewNoteAlert = false
    @State private var newFolderName = ""
    @State private var newNoteTitle = ""
    @State private var newNoteTags = ""
    @State private var searchText = ""
    @State private var editingNoteId: UUID?
    @State private var displayCount = 10  // 分页加载，默认显示10条
    
    var body: some View {
        let storage = appState.storage!
        let subFolders = storage.getSubFolders(of: currentFolderId)
        // 递归获取当前文件夹及所有子文件夹的笔记
        let allNotes = storage.getAllNotesRecursive(in: currentFolderId)
        let filteredNotes = searchText.isEmpty
            ? allNotes
            : allNotes.filter { $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.markdownContent.localizedCaseInsensitiveContains(searchText) }
        // 分页显示
        let displayedNotes = Array(filteredNotes.prefix(displayCount))
        
        let currentFolder = currentFolderId.flatMap { storage.getFolder(id: $0) }
        
        List {
            if !subFolders.isEmpty {
                Section {
                    ForEach(subFolders) { folder in
                        NavigationLink {
                            FolderBrowserView(currentFolderId: folder.id)
                                .navigationTitle(folder.name)
                        } label: {
                            FolderRow(folder: folder, storage: storage)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                storage.deleteFolder(id: folder.id)
                                appState.refreshStats()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("文件夹")
                }
            }
            
            Section {
                if filteredNotes.isEmpty && searchText.isEmpty {
                    EmptyStateView("暂无笔记",
                                   systemImage: "note.text",
                                   description: Text("点击右上角 + 新建笔记"))
                } else if filteredNotes.isEmpty {
                    EmptyStateView("无搜索结果", systemImage: "magnifyingglass")
                } else {
                    ForEach(displayedNotes) { note in
                        NavigationLink {
                            NoteDetailView(noteId: note.id)
                        } label: {
                            NoteRow(note: note, folderPath: storage.getNoteFolderPath(for: note))
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editingNoteId = note.id
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                storage.deleteNote(id: note.id)
                                appState.refreshStats()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("笔记 · \(filteredNotes.count)")
            }
            
            // 加载更多
            if displayedNotes.count < filteredNotes.count {
                Section {
                    Button {
                        displayCount += 10
                    } label: {
                        HStack {
                            Spacer()
                            Text("加载更多（\(filteredNotes.count - displayedNotes.count) 条）")
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentFolder?.name ?? "全部笔记")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索笔记标题或内容")
        // 下拉刷新：从云端同步笔记到本地（全局唯一同步入口）
        .refreshable {
            await withCheckedContinuation { continuation in
                appState.syncFromCloud { _ in
                    continuation.resume()
                }
            }
        }
        // ✅ 正在同步中遮罩提示
        .overlay {
            if appState.isSyncing {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("正在同步笔记...")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("请稍候，正在从云端扫描并导入笔记")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray6).opacity(0.9)))
                }
                .transition(.opacity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showNewFolderAlert = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showNewNoteAlert = true
                    } label: {
                        Label("新建笔记", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        // 新建文件夹 Alert
        .alert("新建文件夹", isPresented: $showNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    storage.createFolder(name: name, parentId: currentFolderId)
                    appState.refreshStats()
                }
                newFolderName = ""
            }
        } message: {
            Text("输入文件夹名称以创建新的分类。")
        }
        // 新建笔记 Alert
        .alert("新建笔记", isPresented: $showNewNoteAlert) {
            TextField("笔记标题", text: $newNoteTitle)
            TextField("标签（用逗号分隔，可选）", text: $newNoteTags)
            Button("取消", role: .cancel) { newNoteTitle = ""; newNoteTags = "" }
            Button("创建") {
                let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    let tags = newNoteTags.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
                    _ = storage.createNote(title: title, folderId: currentFolderId, tags: tags)
                    appState.refreshStats()
                }
                newNoteTitle = ""
                newNoteTags = ""
            }
        } message: {
            Text("笔记将以 Markdown 文件形式存储在当前文件夹中。")
        }
        // 编辑笔记
        .sheet(item: $editingNoteId) { noteId in
            NavigationStack {
                NoteEditorView(noteId: noteId)
            }
        }
    }
}

// MARK: - FolderRow

private struct FolderRow: View {
    let folder: Folder
    let storage: StorageService
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundColor(.yellow)
                .textStyle(.subsectionTitle)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .textStyle(.sectionTitle)
                let subCount = storage.getSubFolders(of: folder.id).count
                let noteCount = storage.countNotesRecursive(in: folder.id)
                Text("\(subCount) 文件夹 · \(noteCount) 笔记")
                    .textStyle(.secondaryText)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - NoteRow

private struct NoteRow: View {
    let note: Note
    let folderPath: String
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .textStyle(.sectionTitle)
                    .lineLimit(1)
                // 文件夹路径小字标识
                Text(folderPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                let snippet = note.cardBack
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !snippet.isEmpty {
                    Text(snippet)
                        .textStyle(.secondaryText)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    stateChip
                    Text(dueText)
                        .textStyle(.tertiaryText)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private var statusIcon: some View {
        let imageName: String
        let color: Color
        switch note.srs.cardState {
        case .new:
            imageName = "sparkles"; color = .blue
        case .learning, .relearning:
            imageName = "book.fill"; color = .orange
        case .review:
            imageName = "checkmark.seal.fill"; color = .green
        }
        return Image(systemName: imageName)
            .foregroundColor(color)
            .textStyle(.subsectionTitle)
    }
    
    private var stateChip: some View {
        let text: String
        let color: Color
        switch note.srs.cardState {
        case .new: text = "新"; color = .blue
        case .learning: text = "学"; color = .orange
        case .relearning: text = "重"; color = .red
        case .review: text = "复"; color = .green
        }
        return Text(text)
            .textStyle(.subsectionTitle)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
    
    private var dueText: String {
        SM2Algorithm.dueDescription(note.srs.dueDate)
    }
}

// MARK: - UUID Binding helper

extension Binding where Value == UUID? {
    func mappedToUUID() -> Binding<UUID?> {
        return Binding<UUID?>(
            get: { self.wrappedValue },
            set: { self.wrappedValue = $0 }
        )
    }
}
