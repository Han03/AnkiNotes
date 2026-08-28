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
        var note = Note(
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
        let oldURL = fileSystem.notesRootDirectory
            .appendingPathComponent(oldMeta.fileName)  // 不完整路径，下面用旧 folder 构建
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
}
