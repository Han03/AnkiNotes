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
    var currentFolderPath: String?
    
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
    @State private var editingNotePath: String?
    @State private var displayCount = 10  // 分页加载，默认显示10条
    @State private var searchedNotePath: String?  // 搜索选中的笔记ID，用于跳转
    @State private var isLoadingMore = false  // 是否正在加载更多
    
    var body: some View {
        let storage = appState.storage!
        let subFolders = storage.getSubFolders(of: currentFolderPath)
        // 递归获取当前文件夹及所有子文件夹的笔记
        let allNotes = storage.getAllNotesRecursive(in: currentFolderPath ?? "")
        // 搜索时不直接过滤列表，而是通过 searchSuggestions 下拉浮层展示
        let filteredNotes = allNotes
        // 分页显示
        let displayedNotes = Array(filteredNotes.prefix(displayCount))
        
        let currentFolder = currentFolderPath.flatMap { storage.getFolder(path: $0) }
        
        List {
            if !subFolders.isEmpty {
                Section {
                    ForEach(subFolders) { folder in
                        NavigationLink {
                            FolderBrowserView(currentFolderPath: folder.path)
                                .navigationTitle(folder.name)
                        } label: {
                            FolderRow(folder: folder, storage: storage,
                                onRename: { f in renameFolder(f) },
                                onDelete: { f in deleteFolder(f) })
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                storage.deleteFolder(path: folder.path)
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
                            NoteDetailView(notePath: note.notePath)
                        } label: {
                            NoteRow(note: note, folderPath: storage.getNoteFolderPath(for: note), hasQuestions: appState.quizService.notesWithQuestionsCache.contains(note.notePath), hasLecture: storage.hasLecture(for: note))
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editingNotePath = note.notePath
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                storage.deleteNote(notePath: note.notePath)
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
                                .foregroundColor(.brandPrimary)
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
                            searchedNotePath = note.notePath
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
                if let notePath = searchedNotePath {
                    NoteDetailView(notePath: notePath)
                }
            }, isActive: Binding(
                get: { searchedNotePath != nil },
                set: { if !$0 { searchedNotePath = nil } }
            )) {
                EmptyView()
            }
            .hidden()
        )
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
                    storage.createFolder(name: name, parentPath: currentFolderPath)
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
                let noteCount = storage.countNotesRecursive(in: folder.path)
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
                    _ = storage.createNote(title: title, folderPath: currentFolderPath ?? "", tags: tags)
                    appState.refreshStats()
                }
                newNoteTitle = ""
                newNoteTags = ""
            }
        } message: {
            Text("笔记将以 Markdown 文件形式存储在当前文件夹中。")
        }
        // 编辑笔记
        .sheet(item: $editingNotePath) { notePath in
            NavigationStack {
                NoteEditorView(notePath: notePath)
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
        appState.storage!.renameFolder(path: folder.path, newName: renameText.trimmingCharacters(in: .whitespaces))
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
        appState.storage!.deleteFolder(path: folder.path)
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
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "folder.fill")
                .foregroundColor(.brandPrimary.opacity(0.8))  // 柔和橙但保持清晰，避免像禁用态
                .textStyle(.subsectionTitle)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .textStyle(.sectionTitle)
                let subCount = storage.getSubFolders(of: folder.path).count
                let noteCount = storage.countNotesRecursive(in: folder.path)
                Text("\(subCount) 文件夹 · \(noteCount) 笔记")
                    .textStyle(.secondaryText)
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, AppSpacing.xs)
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
    let hasLecture: Bool
    
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            statusIcon
                .frame(width: 32)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(note.title)
                    .textStyle(.sectionTitle)
                    .lineLimit(1)
                // 文件夹路径小字标识
                Text(folderPath)
                    .font(.appCaption)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                let snippet = note.cardBack
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !snippet.isEmpty {
                    Text(snippet)
                        .textStyle(.secondaryText)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: AppSpacing.sm) {
                    stateChip
                    // 已生成题目标识：橙色描边角标（视觉轻于状态胶囊）
                    if hasQuestions {
                        contentBadge("题")
                    }
                    // 有讲稿标识：橙色描边角标
                    if hasLecture {
                        contentBadge("稿")
                    }
                    // 到期时间：状态化分级（已到期/今日到期橙色高亮）
                    Text(dueText)
                        .textStyle(.tertiaryText)
                        .foregroundColor(dueColor)
                }
            }
            Spacer()
        }
        .padding(.vertical, AppSpacing.xs)
    }
    
    private var statusIcon: some View {
        // 状态图标颜色跟随状态语义：新=橙、学习中=半透明橙、复习=灰
        // 与状态胶囊呼应，形成"图标+胶囊"的组合视觉锚点
        let imageName: String
        let iconColor: Color
        switch note.srs.cardState {
        case .new:
            imageName = "sparkles"
            iconColor = .brandPrimary
        case .learning, .relearning:
            imageName = "book.fill"
            iconColor = .brandPrimary.opacity(0.6)
        case .review:
            imageName = "checkmark.seal.fill"
            iconColor = .textSecondary
        }
        return Image(systemName: imageName)
            .foregroundColor(iconColor)
            .textStyle(.subsectionTitle)
    }
    
    private var stateChip: some View {
        // 状态胶囊：橙色语义强度系统表达学习阶段
        // 新=实心橙（最强关注）、学/重=浅橙底橙字（进行中）、复=中性灰（稳定态）
        let text: String
        switch note.srs.cardState {
        case .new: text = "新"
        case .learning: text = "学"
        case .relearning: text = "重"
        case .review: text = "复"
        }
        
        let isNew = note.srs.cardState == .new
        let isActive = note.srs.cardState == .learning || note.srs.cardState == .relearning
        
        return Text(text)
            .textStyle(.subsectionTitle)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                isNew ? Color.brandPrimary :                         // 新：实心橙
                (isActive ? Color.brandPrimaryMedium : Color.gray.opacity(0.1))  // 学/重：浅橙底；复：浅灰底
            )
            .foregroundColor(isNew ? .white : (isActive ? .brandPrimary : .textSecondary))
            .cornerRadius(AppCornerRadius.sm)
    }
    
    private var dueText: String {
        SM2Algorithm.dueDescription(note.srs.dueDate)
    }
    
    /// 到期时间颜色：已到期=橙、今日到期=橙、明日=N级灰、N天后=次级灰
    private var dueColor: Color {
        let seconds = note.srs.dueDate.timeIntervalSinceNow
        if seconds <= 0 { return .brandPrimary }
        let days = seconds / 86400
        if days < 1 { return .brandPrimary }
        if days < 2 { return .textSecondary }
        return .textSecondary
    }
    
    /// 题/稿内容角标（橙色细描边，视觉轻于状态胶囊）
    private func contentBadge(_ text: String) -> some View {
        Text(text)
            .textStyle(.subsectionTitle)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.xs)
                    .stroke(Color.brandPrimary.opacity(0.5), lineWidth: 1)
            )
            .foregroundColor(.brandPrimary)
            .cornerRadius(AppCornerRadius.xs)
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
        result = result + Text(matched).bold().foregroundColor(.brandPrimary)
        remaining = String(remaining[range.upperBound...])
    }
    if !remaining.isEmpty {
        result = result + Text(remaining)
    }
    return result
}

// MARK: - 搜索高亮文本（续）
