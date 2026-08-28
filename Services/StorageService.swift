//
//  StorageService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 存储服务：对外提供 Note / Folder 的增删改查
final class StorageService: ObservableObject {
    
    private let fileSystem: FileSystemService
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var noteMetas: [NoteMeta] = []
    @Published private(set) var reviewLogs: [ReviewLog] = []
    
    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
        self.folders = fileSystem.loadFolders()
        self.noteMetas = fileSystem.loadNoteIndex()
        self.reviewLogs = fileSystem.loadReviewLogs()
        consistencyCheck()
    }
    
    // MARK: - 文件夹 CRUD
    
    func getAllFolders() -> [Folder] { folders }
    
    func getSubFolders(of parentId: UUID?) -> [Folder] {
        return folders.filter { $0.parentId == parentId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    
    func getFolder(id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }
    
    @discardableResult
    func createFolder(name: String, parentId: UUID?) -> Folder {
        let folder = Folder(name: name, parentId: parentId)
        folders.append(folder)
        persistFolders()
        // 创建物理目录
        _ = try? fileSystem.createPhysicalFolder(named: name, parentFolderId: parentId, folders: folders)
        return folder
    }
    
    func updateFolder(_ folder: Folder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        var updated = folder
        updated.updatedAt = Date()
        folders[idx] = updated
        persistFolders()
    }
    
    func deleteFolder(id: UUID) {
        // 递归获取该文件夹及其子文件夹下的所有笔记并删除
        let folderIdsToDelete = collectDescendantFolderIds(from: id)
        let notesToDelete = noteMetas.filter { meta in
            if let fid = meta.folderId { return folderIdsToDelete.contains(fid) }
            return false
        }
        notesToDelete.forEach { meta in
            deleteNoteFileOnly(meta: meta)
        }
        noteMetas.removeAll { meta in
            if let fid = meta.folderId { return folderIdsToDelete.contains(fid) }
            return false
        }
        
        // 删除物理文件夹
        if let folder = getFolder(id: id) {
            let url = fileSystem.noteFileURL(
                noteId: UUID(), folderId: folder.parentId,
                title: folder.name, folders: folders
            ).deletingLastPathComponent()
            let target = url.appendingPathComponent(fileSystem.sanitizeFileName(folder.name), isDirectory: true)
            try? fileSystem.deletePhysicalFolder(at: target)
        }
        
        folders.removeAll { folderIdsToDelete.contains($0.id) }
        persistFolders()
        persistNoteIndex()
    }
    
    private func collectDescendantFolderIds(from rootId: UUID) -> Set<UUID> {
        var result: Set<UUID> = [rootId]
        var queue: [UUID] = [rootId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            let children = folders.filter { $0.parentId == id }.map { $0.id }
            result.formUnion(children)
            queue.append(contentsOf: children)
        }
        return result
    }
    
    // MARK: - 笔记 CRUD
    
    func getAllNotes() -> [Note] {
        return noteMetas.compactMap { loadNote(from: $0) }
    }
    
    func getNotes(in folderId: UUID?) -> [Note] {
        return noteMetas
            .filter { $0.folderId == folderId }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { loadNote(from: $0) }
    }
    
    func getNote(id: UUID) -> Note? {
        guard let meta = noteMetas.first(where: { $0.id == id }) else { return nil }
        return loadNote(from: meta)
    }
    
    @discardableResult
    func createNote(title: String, folderId: UUID?, markdownContent: String = "", tags: [String] = []) -> Note {
        let note = Note(
            title: title,
            folderId: folderId,
            markdownContent: markdownContent.isEmpty ? defaultMarkdown(for: title) : markdownContent,
            tags: tags
        )
        
        let fileURL = fileSystem.noteFileURL(noteId: note.id, folderId: folderId, title: title, folders: folders)
        try? fileSystem.writeNoteContent(note.markdownContent, to: fileURL)
        
        let meta = NoteMeta(
            id: note.id, title: note.title, folderId: note.folderId,
            fileName: fileURL.lastPathComponent, srs: note.srs,
            createdAt: note.createdAt, updatedAt: note.updatedAt, tags: note.tags
        )
        noteMetas.append(meta)
        persistNoteIndex()
        return note
    }
    
    /// 默认 Markdown 模板
    private func defaultMarkdown(for title: String) -> String {
        return """
        # \(title)
        
        在这里写下笔记的详细内容...
        
        ## 要点
        
        - 
        
        ## 示例
        
        ```
        代码示例或引用
        ```
        """
    }
    
    func updateNote(_ note: Note) {
        guard let idx = noteMetas.firstIndex(where: { $0.id == note.id }) else { return }
        
        var note = note
        note.updatedAt = Date()
        
        let oldMeta = noteMetas[idx]
        let fileURL = noteFileURL(for: note)
        // 删除旧文件（仅当文件夹或标题发生变更时）
        if oldMeta.title != note.title || oldMeta.folderId != note.folderId {
            let oldFileURL = buildOldFileURL(meta: oldMeta)
            try? fileSystem.deleteNoteFile(at: oldFileURL)
        }
        
        // 写新内容
        try? fileSystem.writeNoteContent(note.markdownContent, to: fileURL)
        
        let meta = NoteMeta(
            id: note.id, title: note.title, folderId: note.folderId,
            fileName: fileURL.lastPathComponent, srs: note.srs,
            createdAt: note.createdAt, updatedAt: note.updatedAt, tags: note.tags
        )
        noteMetas[idx] = meta
        persistNoteIndex()
    }
    
    /// 只更新 SRS 数据，不重写 Markdown 文件
    func updateNoteSRS(noteId: UUID, srs: SRSData) {
        guard let idx = noteMetas.firstIndex(where: { $0.id == noteId }) else { return }
        var meta = noteMetas[idx]
        meta.srs = srs
        meta.updatedAt = Date()
        noteMetas[idx] = meta
        persistNoteIndex()
    }
    
    func deleteNote(id: UUID) {
        guard let meta = noteMetas.first(where: { $0.id == id }) else { return }
        deleteNoteFileOnly(meta: meta)
        noteMetas.removeAll { $0.id == id }
        persistNoteIndex()
    }
    
    // MARK: - 复习日志
    
    func addReviewLog(_ log: ReviewLog) {
        reviewLogs.append(log)
        persistReviewLogs()
    }
    
    func getReviewLogs(for noteId: UUID) -> [ReviewLog] {
        reviewLogs
            .filter { $0.noteId == noteId }
            .sorted { $0.reviewDate > $1.reviewDate }
    }
    
    func getReviewLogs(since date: Date) -> [ReviewLog] {
        reviewLogs.filter { $0.reviewDate >= date }
    }
    
    // MARK: - 辅助方法
    
    private func noteFileURL(for note: Note) -> URL {
        fileSystem.noteFileURL(noteId: note.id, folderId: note.folderId, title: note.title, folders: folders)
    }
    
    private func buildOldFileURL(meta: NoteMeta) -> URL {
        fileSystem.noteFileURL(noteId: meta.id, folderId: meta.folderId, title: meta.title, folders: folders)
    }
    
    private func loadNote(from meta: NoteMeta) -> Note? {
        let fileURL = buildOldFileURL(meta: meta)
        let content = (try? fileSystem.readNoteContent(from: fileURL)) ?? ""
        return Note(
            id: meta.id,
            title: meta.title,
            folderId: meta.folderId,
            markdownContent: content,
            srs: meta.srs,
            createdAt: meta.createdAt,
            updatedAt: meta.updatedAt,
            tags: meta.tags
        )
    }
    
    private func deleteNoteFileOnly(meta: NoteMeta) {
        let url = buildOldFileURL(meta: meta)
        try? fileSystem.deleteNoteFile(at: url)
    }
    
    // MARK: - 持久化
    
    private func persistFolders() {
        fileSystem.saveFolders(folders)
    }
    
    private func persistNoteIndex() {
        fileSystem.saveNoteIndex(noteMetas)
    }
    
    private func persistReviewLogs() {
        fileSystem.saveReviewLogs(reviewLogs)
    }
    
    // MARK: - 一致性校验
    
    /// 启动时校验：索引存在但文件丢失的笔记，用空内容兜底
    private func consistencyCheck() {
        var didFix = false
        for (idx, meta) in noteMetas.enumerated() {
            let url = buildOldFileURL(meta: meta)
            if !FileManager.default.fileExists(atPath: url.path) {
                // 文件丢失：重新写入
                let content = defaultMarkdown(for: meta.title)
                try? fileSystem.writeNoteContent(content, to: url)
                didFix = true
                var newMeta = meta
                newMeta.fileName = url.lastPathComponent
                noteMetas[idx] = newMeta
            }
        }
        if didFix { persistNoteIndex() }
    }
    
    // MARK: - Markdown 批量导入（通过文件共享）
    
    /// 批量导入报告
    struct ImportReport: Identifiable, Equatable {
        let id = UUID()
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var failedCount: Int = 0
        var folderCreatedCount: Int = 0
        var scannedMarkdownFiles: Int = 0
        var messages: [String] = []   // 简单说明 / 错误 / 导入的笔记标题样例 (最多前 10)
        var warningMessages: [String] = [] // 警告（如空文件）
    }
    
    /// 从 App Documents 目录（文件共享拖入）递归扫描 Markdown 并导入笔记库
    /// - 跳过内部目录 Notes/ 和 .metadata/
    /// - 按物理相对路径自动创建 Folder 层级
    /// - 解析 YAML Frontmatter（title/tags/date）
    /// - 去重：同路径+同标题已存在时跳过
    @discardableResult
    func importMarkdownFromDocuments() -> ImportReport {
        let fm = FileManager.default
        let root = fileSystem.rootDirectory
        var report = ImportReport()
        
        // 1. 递归枚举所有 .md / .markdown 文件，跳过 Notes 和 .metadata
        let skipNames: Set<String> = ["Notes", ".metadata"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .pathKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            report.warningMessages.append("无法创建 Documents 目录枚举器")
            return report
        }
        
        var mdFiles: [URL] = []
        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.isDirectory ?? false {
                if let name = rv.name, skipNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                mdFiles.append(url)
            }
        }
        report.scannedMarkdownFiles = mdFiles.count
        
        guard report.scannedMarkdownFiles > 0 else {
            report.warningMessages.append("Documents 目录没有发现 .md/.markdown 文件（请通过爱思助手/iTunes 文件共享先把 Markdown 文件夹拖入）")
            return report
        }
        
        // 2. 逐个导入
        for (idx, srcURL) in mdFiles.enumerated() {
            // 防止重复（按标题+folder 路径粗略查重）
            // 显式声明 [String] + Array(dropFirst) 避免 Swift 在
            // Sequence.dropFirst / Array.dropFirst 两重载间类型推断 ambiguous
            let paths: [String] = srcURL.pathComponents
            let rootCount = root.pathComponents.count
            let relativePathComponents: [String]
            if paths.count > rootCount {
                relativePathComponents = Array(paths.dropFirst(rootCount))
            } else {
                relativePathComponents = []
            }
            let folderComponents = Array(relativePathComponents.dropLast()) // 去掉文件名
            let fileName = srcURL.lastPathComponent
            
            do {
                let rawBody = try fileSystem.readNoteContent(from: srcURL)
                let parsed = MarkdownFrontmatterParser.parse(rawBody)
                
                // 标题：Frontmatter.title → 文件名去掉 .md → 默认 "未命名"
                var title = (parsed.title?.isEmpty == false) ? parsed.title! : parseTitleFromFileName(fileName)
                if title.isEmpty { title = "未命名-\(UUID().uuidString.prefix(6))" }
                
                // 文件夹：按相对路径创建层级
                let folderId = try getOrCreateFolder(pathComponents: folderComponents,
                                                     createdCount: &report.folderCreatedCount)
                
                // 粗略查重（同 folder + 同 title → 跳过）
                let exists = noteMetas.contains { m in
                    m.folderId == folderId && m.title.lowercased() == title.lowercased()
                }
                if exists {
                    report.skippedCount += 1
                    if report.messages.count < 10 {
                        report.messages.append("⏭️ 跳过重复：\(folderComponents.joined(separator: "/"))/\(title)")
                    }
                    continue
                }
                
                // 创建笔记（调用现有 createNote 自动生成 SRS 默认值、写 Notes/ 目录、索引）
                let bodyToUse = parsed.body.isEmpty ? rawBody : parsed.body
                createNote(
                    title: title,
                    folderId: folderId,
                    markdownContent: bodyToUse,
                    tags: parsed.tags
                )
                report.importedCount += 1
                
                if report.messages.count < 10 {
                    let prefix = folderComponents.isEmpty ? "" : folderComponents.joined(separator: "/") + "/"
                    report.messages.append("✅ \(prefix)\(title)")
                }
            } catch {
                report.failedCount += 1
                if report.warningMessages.count < 5 {
                    report.warningMessages.append("❌ 导入失败 \(fileName): \(error.localizedDescription)")
                }
            }
            
            // 每 50 条持久化一次，避免丢数据
            if idx % 50 == 0 {
                persistFolders()
                persistNoteIndex()
            }
        }
        
        persistFolders()
        persistNoteIndex()
        
        return report
    }
    
    // MARK: - 导入辅助
    
    /// 按「从根到当前」的路径组件数组，查重创建 Folder 树，返回最终文件夹 ID（nil 表示根）
    private func getOrCreateFolder(pathComponents: [String],
                                    createdCount: inout Int) throws -> UUID? {
        guard !pathComponents.isEmpty else { return nil }
        var parentId: UUID? = nil
        
        for name in pathComponents {
            let clean = fileSystem.sanitizeFileName(name)
            guard !clean.isEmpty else { continue }
            
            // 查重：同 parent 同 name
            if let existed = folders.first(where: { f in
                f.parentId == parentId && f.name.lowercased() == clean.lowercased()
            }) {
                parentId = existed.id
                continue
            }
            // 新建
            let f = createFolder(name: clean, parentId: parentId)
            createdCount += 1
            parentId = f.id
        }
        return parentId
    }
    
    /// 从文件名提取标题（去掉 UUID 前缀、.md/.markdown 后缀、去除非法字符占位、去前后空格）
    private func parseTitleFromFileName(_ fileName: String) -> String {
        var s = fileName
        // 去掉 .md / .markdown
        if s.lowercased().hasSuffix(".markdown") {
            s = String(s.dropLast(".markdown".count))
        } else if s.lowercased().hasSuffix(".md") {
            s = String(s.dropLast(3))
        }
        // 去掉形如 "UUID_Title" 或 "UUIDTitle" 中的 UUID 前缀
        // UUID 固定 36 位 8-4-4-4-12
        if s.count > 36 {
            let prefixPart = String(s.prefix(36))
            let uuidRegex = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
            if prefixPart.range(of: uuidRegex, options: .regularExpression) != nil {
                s = String(s.dropFirst(36))
                if s.first == "_" || s.first == "-" || s.first == " " { s = String(s.dropFirst()) }
            }
        }
        // 把下划线/连字符替换成空格
        s = s.replacingOccurrences(of: "_", with: " ")
             .replacingOccurrences(of: "-", with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}
