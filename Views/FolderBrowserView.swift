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
    @State private var showingReviewSession = false
    @State private var reviewFolderId: UUID? = nil
    @State private var lastImportReport: StorageService.ImportReport?
    
    var body: some View {
        let storage = appState.storage!
        let subFolders = storage.getSubFolders(of: currentFolderId)
        let notes = storage.getNotes(in: currentFolderId)
        let filteredNotes = searchText.isEmpty
            ? notes
            : notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.markdownContent.localizedCaseInsensitiveContains(searchText) }
        
        let currentFolder = currentFolderId.flatMap { storage.getFolder(id: $0) }
        let reviewCount = appState.scheduler.getTodayDueCount(in: currentFolderId)
        
        List {
            Section {
                // 复习按钮
                if reviewCount > 0 {
                    Button {
                        reviewFolderId = currentFolderId
                        showingReviewSession = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "play.fill")
                                    .foregroundColor(.blue)
                                    .textStyle(.subsectionTitle)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("开始复习")
                                    .textStyle(.sectionTitle)
                                Text("\(reviewCount) 张卡片待复习")
                                    .textStyle(.secondaryText)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.blue.opacity(0.05))
                }
            }
            
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
                    ForEach(filteredNotes) { note in
                        NavigationLink {
                            NoteDetailView(noteId: note.id)
                        } label: {
                            NoteRow(note: note)
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
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentFolder?.name ?? "全部笔记")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索笔记标题或内容")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        let report = storage.importMarkdownFromDocuments()
                        lastImportReport = report
                        appState.refreshStats()
                    } label: {
                        Label("📥 导入 Markdown 文件夹", systemImage: "square.and.arrow.down")
                    }
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
        // 复习模式
        .sheet(isPresented: $showingReviewSession) {
            NavigationStack {
                ReviewSessionView(folderId: reviewFolderId)
            }
            .interactiveDismissDisabled()
        }
        // 导入结果
        .sheet(item: $lastImportReport) { report in
            NavigationStack {
                ImportReportView(report: report)
                    .navigationTitle("📥 导入结果")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { lastImportReport = nil }
                                .bold()
                        }
                    }
            }
        }
    }
}

// MARK: - 导入结果弹窗

private struct ImportReportView: View {
    let report: StorageService.ImportReport
    
    var body: some View {
        List {
            Section {
                StatRow(icon: "doc.text.magnifyingglass", title: "扫描发现 Markdown",
                        value: "\(report.scannedMarkdownFiles) 个", color: .gray)
                StatRow(icon: "checkmark.circle.fill", title: "✅ 成功导入",
                        value: "\(report.importedCount) 个", color: .green)
                StatRow(icon: "folder.fill.badge.plus", title: "📁 自动新建文件夹",
                        value: "\(report.folderCreatedCount) 个", color: .orange)
                StatRow(icon: "arrow.triangle.2.circlepath", title: "⏭️ 重复跳过",
                        value: "\(report.skippedCount) 个", color: .secondary)
                if report.failedCount > 0 {
                    StatRow(icon: "xmark.circle.fill", title: "❌ 导入失败",
                            value: "\(report.failedCount) 个", color: .red)
                }
            } header: {
                Text("导入汇总")
            } footer: {
                if report.scannedMarkdownFiles == 0 {
                    Text("提示：请通过爱思助手 →「我的设备」→「应用」→ 找到 Anki 笔记 → 浏览文件 → 把整个 Markdown 文件夹拖入 App 共享目录，再回到本页点导入。")
                }
            }
            
            if !report.messages.isEmpty {
                Section {
                    ForEach(report.messages, id: \.self) { line in
                        Label(line, systemImage: "doc.plaintext")
                            .textStyle(.tertiaryText)
                            .lineLimit(2)
                    }
                    if report.importedCount + report.skippedCount > report.messages.count {
                        Text("...其余 \(report.importedCount + report.skippedCount - report.messages.count) 条未显示")
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("明细样例（前 \(report.messages.count) 条）")
                }
            }
            
            if !report.warningMessages.isEmpty {
                Section {
                    ForEach(report.warningMessages, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .textStyle(.tertiaryText)
                            .foregroundColor(.orange)
                    }
                } header: {
                    Text("警告")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct StatRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title).foregroundColor(.primary)
            Spacer()
            Text(value).bold().foregroundStyle(color)
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
                let noteCount = storage.getNotes(in: folder.id).count
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
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .textStyle(.sectionTitle)
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
