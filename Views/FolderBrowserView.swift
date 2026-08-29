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
    @State private var showRenameAlert = false
    @State private var folderToRename: Folder?
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var folderToDelete: Folder?
    @State private var showNewNoteAlert = false
    @State private var newFolderName = ""
    @State private var newNoteTitle = ""
    @State private var newNoteTags = ""
    @State private var searchText = ""
    @State private var editingNoteId: UUID?
    @State private var displayCount = 10  // 分页加载，默认显示10条
    @State private var searchedNoteId: UUID?  // 搜索选中的笔记ID，用于跳转
    @State private var isLoadingMore = false  // 是否正在加载更多
    
    var body: some View {
        let storage = appState.storage!
        let subFolders = storage.getSubFolders(of: currentFolderId)
        // 递归获取当前文件夹及所有子文件夹的笔记
        let allNotes = storage.getAllNotesRecursive(in: currentFolderId)
        // 搜索时不直接过滤列表，而是通过 searchSuggestions 下拉浮层展示
        let filteredNotes = allNotes
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
                            FolderRow(folder: folder, storage: storage,
                                onRename: { f in renameFolder(f) },
                                onDelete: { f in deleteFolder(f) })
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
                if filteredNotes.isEmpty {
                    EmptyStateView("暂无笔记",
                                   systemImage: "note.text",
                                   description: Text("点击右上角 + 新建笔记"))
                } else {
                    ForEach(displayedNotes) { note in
                        NavigationLink {
                            NoteDetailView(noteId: note.id)
                        } label: {
                            NoteRow(note: note, folderPath: storage.getNoteFolderPath(for: note), hasQuestions: appState.quizService.generatedNoteIds.contains(note.id))
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
            
            // 滚动到底部自动加载更多
            if displayedNotes.count < filteredNotes.count {
                Section {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView()
                                .padding(.vertical, 12)
                            Text("加载中...")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            Text("加载更多")
                                .foregroundColor(.blue)
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear {
                        // 当这个视图出现时，自动加载更多
                        guard !isLoadingMore else { return }
                        isLoadingMore = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            displayCount += 10
                            isLoadingMore = false
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentFolder?.name ?? "全部笔记")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索笔记标题或内容")
        // 搜索建议下拉浮层：最多5条，高亮匹配字符，选中跳转详情
        .searchSuggestions {
            if !searchText.isEmpty {
                let searchResults = allNotes.filter {
                    $0.title.localizedCaseInsensitiveContains(searchText) ||
                    $0.markdownContent.localizedCaseInsensitiveContains(searchText)
                }.prefix(5)
                if searchResults.isEmpty {
                    Text("无匹配结果")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(searchResults)) { note in
                        Button {
                            searchedNoteId = note.id
                            searchText = ""
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    highlightedText(note.title, searchText: searchText)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    // 显示文件夹路径
                                    let path = storage.getNoteFolderPath(for: note)
                                    Text(path)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // 搜索选中后跳转到详情
        .background(
            NavigationLink(destination: Group {
                if let noteId = searchedNoteId {
                    NoteDetailView(noteId: noteId)
                }
            }, isActive: Binding(
                get: { searchedNoteId != nil },
                set: { if !$0 { searchedNoteId = nil } }
            )) {
                EmptyView()
            }
            .hidden()
        )
        // 下拉刷新：从云端同步笔记到本地（全局唯一同步入口）
        .refreshable {
            // 如果后台正在静默同步，只显示加载状态，不重复执行
            if appState.isSilentSyncing {
                // 等待静默同步完成
                await withCheckedContinuation { continuation in
                    // 轮询等待静默同步完成（最多等 30 秒）
                    var waited = 0
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                        waited += 1
                        if !appState.isSilentSyncing || waited > 60 {
                            timer.invalidate()
                            continuation.resume()
                        }
                    }
                }
            } else {
                // 正常执行同步
                await withCheckedContinuation { continuation in
                    appState.syncFromCloud { _ in
                        continuation.resume()
                    }
                }
            }
        }
        // ✅ 正在同步中遮罩提示（包括静默同步）
        .overlay {
            if appState.isSyncing || appState.isSilentSyncing {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text(appState.isSilentSyncing ? "后台同步中..." : "正在同步笔记...")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(appState.isSilentSyncing ? "正在后台同步，请稍候" : "请稍候，正在从云端扫描并导入笔记")
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
        // 重命名文件夹 Alert
        .alert("重命名文件夹", isPresented: $showRenameAlert) {
            TextField("文件夹名称", text: $renameText)
            Button("取消", role: .cancel) {
                showRenameAlert = false
                folderToRename = nil
            }
            Button("保存") {
                confirmRename()
            }
        } message: {
            Text("输入新的文件夹名称")
        }
        // 删除文件夹确认 Alert
        .alert("删除文件夹", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {
                showDeleteConfirm = false
                folderToDelete = nil
            }
            Button("删除", role: .destructive) {
                confirmDelete()
            }
        } message: {
            if let folder = folderToDelete {
                let noteCount = storage.countNotesRecursive(in: folder.id)
                Text("确定要删除文件夹「\(folder.name)」吗？该文件夹下的 \(noteCount) 篇笔记也会被删除，此操作不可恢复。")
            }
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
    
    // MARK: - 文件夹操作
    
    private func renameFolder(_ folder: Folder) {
        folderToRename = folder
        renameText = folder.name
        showRenameAlert = true
    }
    
    private func confirmRename() {
        guard let folder = folderToRename,
              !renameText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        appState.storage!.renameFolder(id: folder.id, newName: renameText.trimmingCharacters(in: .whitespaces))
        showRenameAlert = false
        folderToRename = nil
        renameText = ""
    }
    
    private func deleteFolder(_ folder: Folder) {
        folderToDelete = folder
        showDeleteConfirm = true
    }
    
    private func confirmDelete() {
        guard let folder = folderToDelete else { return }
        appState.storage!.deleteFolder(id: folder.id)
        showDeleteConfirm = false
        folderToDelete = nil
    }
}

// MARK: - FolderRow

private struct FolderRow: View {
    let folder: Folder
    let storage: StorageService
    var onRename: (Folder) -> Void
    var onDelete: (Folder) -> Void
    
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
        .contextMenu {
            Button {
                onRename(folder)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete(folder)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - NoteRow

private struct NoteRow: View {
    let note: Note
    let folderPath: String
    let hasQuestions: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(note.title)
                        .textStyle(.sectionTitle)
                        .lineLimit(1)
                    if hasQuestions {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.purple)
                            .font(.caption)
                    }
                }
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

// MARK: - 搜索高亮文本

private func highlightedText(_ text: String, searchText: String) -> Text {
    guard !searchText.isEmpty else { return Text(text) }
    var result = Text("")
    var remaining = text
    while let range = remaining.range(of: searchText, options: .caseInsensitive) {
        let before = String(remaining[..<range.lowerBound])
        let matched = String(remaining[range])
        if !before.isEmpty {
            result = result + Text(before)
        }
        result = result + Text(matched).bold().foregroundColor(.blue)
        remaining = String(remaining[range.upperBound...])
    }
    if !remaining.isEmpty {
        result = result + Text(remaining)
    }
    return result
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
