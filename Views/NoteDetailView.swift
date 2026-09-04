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
    @State private var showMoveFolder = false
    @State private var isSyncingNote = false  // 正在同步单个笔记
    @State private var selectedFolderId: UUID?
    @State private var knowledgePoints: [KnowledgePoint] = []  // 已提取的知识点
    @State private var selectedKnowledgePoint: KnowledgePoint? = nil  // 选中的知识点（用于弹出详解）
    @State private var isExtractingKnowledge = false  // 正在提取知识点
    
    var body: some View {
        Group {
            if let note = note {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        // 完整 Markdown 内容（带知识点标记）
                        sectionHeader("完整内容")
                        MarkdownView(
                            markdown: note.markdownContent,
                            knowledgePoints: knowledgePoints,
                            onKnowledgeTap: { point in
                                selectedKnowledgePoint = point
                            }
                        )
                        .padding(.horizontal, 4)
                        
                        // 知识点提取区域
                        knowledgeSection(note)
                        
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
                .overlay {
                    if isSyncingNote {
                        ProgressView("同步笔记中...")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
                // 知识点详解界面
                .sheet(item: $selectedKnowledgePoint) { point in
                    KnowledgeExplainView(
                        point: point,
                        noteContent: note.markdownContent,
                        config: appState.bailianConfig
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                // 打开编辑前先单独同步该笔记，减少冲突
                                isSyncingNote = true
                                appState.syncSingleNote(noteId: noteId) { _ in
                                    DispatchQueue.main.async {
                                        loadNote()
                                        isSyncingNote = false
                                        showEditor = true
                                    }
                                }
                            } label: {
                                Label("编辑 Markdown", systemImage: "pencil")
                            }
                            .disabled(isSyncingNote)
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
                .sheet(isPresented: $showEditor, onDismiss: {
                    // 编辑关闭后重新加载笔记，确保详情更新
                    loadNote()
                    appState.refreshStats()
                }) {
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
                EmptyStateView("笔记不存在或已删除", systemImage: "trash")
            }
        }
        .onAppear {
            loadNote()
            // 加载已缓存的知识点（不自动提取）
            loadCachedKnowledgePoints()
        }
        .onDisappear { appState.refreshStats() }
    }
    
    // MARK: - 知识点提取区域
    
    @ViewBuilder
    private func knowledgeSection(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("知识点精讲")
                    .textStyle(.sectionTitle)
                Spacer()
                if !knowledgePoints.isEmpty {
                    Text("\(knowledgePoints.count) 个知识点")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if isExtractingKnowledge {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在提取知识点...")
                            .font(.subheadline)
                            .foregroundColor(.purple)
                        if !knowledgePoints.isEmpty {
                            Text("已提取 \(knowledgePoints.count) 个")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(Color.purple.opacity(0.08))
                .cornerRadius(10)
            } else if knowledgePoints.isEmpty {
                Button {
                    extractKnowledgePoints()
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("提取知识点")
                            .font(.subheadline.bold())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.purple.opacity(0.1))
                    .foregroundColor(.purple)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(!appState.bailianConfig.isConfigured)
                
                if !appState.bailianConfig.isConfigured {
                    Text("请先在设置中配置百炼大模型")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    FlexibleView(data: knowledgePoints, spacing: 8) { point in
                        Button {
                            selectedKnowledgePoint = point
                        } label: {
                            Text(point.keyword)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.purple.opacity(0.12))
                                .foregroundColor(.purple)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button {
                        extractKnowledgePoints()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("重新提取")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - 分区
    
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .textStyle(.sectionTitle)
            .foregroundColor(.secondary)
            .padding(.top, 8)
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
                .textStyle(.secondaryText)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(logs.prefix(10).enumerated()), id: \.element.id) { idx, log in
                    HStack {
                        Circle()
                            .fill(Color(hex: log.rating.color))
                            .frame(width: 10, height: 10)
                        Text(log.rating.description)
                            .textStyle(.subsectionTitle)
                        Spacer()
                        Text("\(log.oldInterval)d → \(log.newInterval)d")
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                        Text(log.reviewDate.formatted(date: .abbreviated, time: .shortened))
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    if idx < min(logs.count, 10) - 1 { Divider().padding(.leading, 30) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
        }
    }
    
    // MARK: - 操作
    
    private func loadNote() {
        note = appState.storage.getNote(id: noteId)
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
    
    // MARK: - 知识点提取
    
    private func loadCachedKnowledgePoints() {
        guard let note = note else { return }
        if let cached = KnowledgeService.shared.loadExtraction(for: note.id) {
            knowledgePoints = cached
        }
    }
    
    private func extractKnowledgePoints() {
        guard let note = note else { return }
        guard appState.bailianConfig.isConfigured else { return }
        
        // 先检查缓存
        if let cached = KnowledgeService.shared.loadExtraction(for: note.id) {
            knowledgePoints = cached
            return
        }
        
        isExtractingKnowledge = true
        
        KnowledgeService.shared.extractKeywords(
            note: note,
            config: appState.bailianConfig,
            onPoint: { point in
                // 实时标记：每识别到一个知识点就添加到列表
                knowledgePoints.append(point)
            },
            completion: { points in
                isExtractingKnowledge = false
                knowledgePoints = points
            }
        )
    }
}

// MARK: - InfoChip

private struct InfoChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .textStyle(.tertiaryText)
                .foregroundStyle(.secondary)
            Text(value)
                .textStyle(.subsectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
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

// MARK: - 流式布局视图（用于标签云）

struct FlexibleView<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content
    
    @State private var totalHeight: CGFloat = .zero
    
    var body: some View {
        GeometryReader { geometry in
            self.generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }
    
    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        
        return ZStack(alignment: .topLeading) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, spacing)
                    .alignmentGuide(.leading) { dimension in
                        if abs(width - dimension.width) > geometry.size.width {
                            width = 0
                            height -= dimension.height
                        }
                        let result = width
                        if item == data.last {
                            width = 0
                        } else {
                            width -= dimension.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == data.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }
    
    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}
