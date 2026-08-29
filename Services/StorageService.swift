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
    var cloudSyncFS: CloudFileSystem?  // 云端同步实例（WebDAV），增删改后后台双写
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
    
    func getAllFolders() -> [Folder] { folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    
    func getSubFolders(of parentId: UUID?) -> [Folder] {
        return folders.filter { $0.parentId == parentId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    
    /// 重命名文件夹（同时重命名物理目录并更新云端）
    func renameFolder(id: UUID, newName: String) {
        guard let folder = getFolder(id: id),
              let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        let oldName = folder.name
        guard oldName != newName else { return }
        
        // 更新文件夹名称
        var updated = folder
        updated.name = newName
        updated.updatedAt = Date()
        folders[idx] = updated
        persistFolders()
        
        // 重命名物理目录（本地 + 云端）
        let oldURL = fileSystem.noteFileURL(
            noteId: UUID(), folderId: folder.parentId,
            title: oldName, folders: folders
        ).deletingLastPathComponent()
        .appendingPathComponent(fileSystem.sanitizeFileName(oldName), isDirectory: true)
        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(fileSystem.sanitizeFileName(newName), isDirectory: true)
        try? fileSystem.movePhysicalFolder(from: oldURL, to: newURL)
        
        // 更新该文件夹下所有笔记的 updatedAt（触发重新同步）
        let folderIds = collectDescendantFolderIds(from: id)
        for i in noteMetas.indices {
            if let fid = noteMetas[i].folderId, folderIds.contains(fid) {
                noteMetas[i].updatedAt = Date()
            }
        }
        persistNoteIndex()
        
        // 同步到云端
        syncFolderChangesToCloud()
    }
    
    /// 将文件夹变更同步到云端（简化版：触发全量同步）
    private func syncFolderChangesToCloud() {
        // 云端同步由 AppState 触发，这里只标记需要刷新
        triggerRefresh()
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
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .compactMap { loadNote(from: $0) }
    }
    
    func getNote(id: UUID) -> Note? {
        guard let meta = noteMetas.first(where: { $0.id == id }) else { return nil }
        return loadNote(from: meta)
    }

    /// 递归获取指定文件夹及其所有子文件夹中的笔记
    /// 排序规则：当前文件夹层级的笔记优先（按标题升序），然后子文件夹笔记按路径升序+标题升序
    func getAllNotesRecursive(in folderId: UUID?) -> [Note] {
        // 当前文件夹的笔记（按标题升序）
        let currentNotes = getNotes(in: folderId)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        
        // 递归获取所有子文件夹的笔记
        var subNotes: [(note: Note, path: String)] = []
        let subFolders = getSubFolders(of: folderId)
        for sub in subFolders {
            let notes = getAllNotesRecursive(in: sub.id)
            for note in notes {
                let path = getFolderPath(for: note.folderId)
                subNotes.append((note: note, path: path))
            }
        }
        // 子文件夹笔记按路径升序+标题升序
        subNotes.sort { a, b in
            if a.path != b.path {
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
            return a.note.title.localizedStandardCompare(b.note.title) == .orderedAscending
        }
        
        return currentNotes + subNotes.map { $0.note }
    }

    /// 递归统计指定文件夹及其所有子文件夹中的笔记数量
    func countNotesRecursive(in folderId: UUID?) -> Int {
        var count = getNotes(in: folderId).count
        let subFolders = getSubFolders(of: folderId)
        for sub in subFolders {
            count += countNotesRecursive(in: sub.id)
        }
        return count
    }

    /// 获取指定文件夹的完整路径（从根目录开始）
    func getFolderPath(for folderId: UUID?) -> String {
        guard let folderId = folderId else { return "根目录" }
        var components: [String] = []
        var currentId: UUID? = folderId
        while let fid = currentId {
            if let folder = getFolder(id: fid) {
                components.insert(folder.name, at: 0)
                currentId = folder.parentId
            } else {
                break
            }
        }
        return components.joined(separator: "/")
    }

    /// 获取笔记所在文件夹的路径
    func getNoteFolderPath(for note: Note) -> String {
        return getFolderPath(for: note.folderId)
    }
    
    @discardableResult
    func createNote(title: String, folderId: UUID?, markdownContent: String = "", tags: [String] = [], skipCloudSync: Bool = false) -> Note {
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
        // 后台同步到云端
        if !skipCloudSync, let cloud = cloudSyncFS {
            DispatchQueue.global(qos: .background).async {
                do {
                    let cloudURL = self.cloudNoteURL(for: fileURL, cloudFS: cloud)
                    try cloud.writeData(Data(note.markdownContent.utf8), to: cloudURL)
                } catch { print("⚠️ 云端同步笔记失败: \(error.localizedDescription)") }
            }
        }
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
        // 后台同步到云端
        if let cloud = cloudSyncFS {
            DispatchQueue.global(qos: .background).async {
                do {
                    let cloudURL = self.cloudNoteURL(for: fileURL, cloudFS: cloud)
                    try cloud.writeData(Data(note.markdownContent.utf8), to: cloudURL)
                } catch { print("⚠️ 云端更新笔记失败: \(error.localizedDescription)") }
            }
        }
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
        let localURL = buildOldFileURL(meta: meta)
        deleteNoteFileOnly(meta: meta)
        noteMetas.removeAll { $0.id == id }
        persistNoteIndex()
        // 后台从云端删除
        if let cloud = cloudSyncFS {
            DispatchQueue.global(qos: .background).async {
                do {
                    let cloudURL = self.cloudNoteURL(for: localURL, cloudFS: cloud)
                    try cloud.removeItem(at: cloudURL)
                } catch { print("⚠️ 云端删除笔记失败: \(error.localizedDescription)") }
            }
        }
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

    // MARK: - 云端同步

    /// 从云端同步笔记到本地（下拉刷新调用）
    func importFromCloud() -> ImportReport {
        var report = ImportReport()
        guard let cloud = cloudSyncFS else {
            report.warningMessages.append("未配置云端同步")
            return report
        }
        let cloudRoot = cloud.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        let skipNames: Set<String> = [".metadata"]
        var cloudFiles: [URL] = []
        collectMarkdownFilesFromFS(cloud, at: cloudRoot, skipNames: skipNames, into: &cloudFiles)
        report.scannedMarkdownFiles = cloudFiles.count
        guard report.scannedMarkdownFiles > 0 else {
            report.warningMessages.append("云端 Notes 目录没有发现 .md 文件")
            return report
        }
        for (idx, srcURL) in cloudFiles.enumerated() {
            do {
                let relativeComponents = relativePathComponents(of: srcURL, from: cloudRoot)
                let folderComponents = Array(relativeComponents.dropLast())
                let fileName = srcURL.lastPathComponent
                let rawBody = try cloud.readData(at: srcURL)
                let bodyStr = String(data: rawBody, encoding: .utf8) ?? ""
                let parsed = MarkdownFrontmatterParser.parse(bodyStr)
                var title = (parsed.title?.isEmpty == false) ? parsed.title! : parseTitleFromFileName(fileName)
                if title.isEmpty { title = "未命名-\(UUID().uuidString.prefix(6))" }
                let folderId = try getOrCreateFolder(pathComponents: folderComponents, createdCount: &report.folderCreatedCount)
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
                let bodyToUse = parsed.body.isEmpty ? bodyStr : parsed.body
                createNote(title: title, folderId: folderId, markdownContent: bodyToUse, tags: parsed.tags, skipCloudSync: true)
                report.importedCount += 1
                if report.messages.count < 10 {
                    let prefix = folderComponents.isEmpty ? "" : folderComponents.joined(separator: "/") + "/"
                    report.messages.append("✅ \(prefix)\(title)")
                }
            } catch {
                report.failedCount += 1
                if report.warningMessages.count < 5 {
                    report.warningMessages.append("❌ 导入失败 \(srcURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if idx % 50 == 0 {
                persistFolders()
                persistNoteIndex()
            }
        }
        persistFolders()
        persistNoteIndex()
        return report
    }

    /// 从云端同步单个笔记（打开编辑前调用，减少冲突）
    func syncSingleNoteFromCloud(noteId: UUID) -> Bool {
        guard let cloud = cloudSyncFS,
              let note = getNote(id: noteId) else {
            return false
        }
        // 找到该笔记在云端的对应文件
        let folderPath = getFolderPath(for: note.folderId)
        let cloudRoot = cloud.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        var cloudURL = cloudRoot
        if !folderPath.isEmpty {
            for component in folderPath.split(separator: "/") {
                cloudURL.appendPathComponent(String(component), isDirectory: true)
            }
        }
        cloudURL.appendPathComponent("\(note.title).md")
        
        // 尝试从云端下载
        do {
            let rawBody = try cloud.readData(at: cloudURL)
            let bodyStr = String(data: rawBody, encoding: .utf8) ?? ""
            let parsed = MarkdownFrontmatterParser.parse(bodyStr)
            let bodyToUse = parsed.body.isEmpty ? bodyStr : parsed.body
            
            // 更新本地笔记内容（保留 ID 和 SRS 状态）
            var updatedNote = note
            updatedNote.markdownContent = bodyToUse
            if !parsed.tags.isEmpty {
                updatedNote.tags = parsed.tags
            }
            updatedNote.updatedAt = Date()
            updateNote(updatedNote)
            return true
        } catch {
            // 云端不存在该笔记或下载失败，不更新本地
            return false
        }
    }

    /// 上传单个笔记到云端（保存后调用）
    func uploadSingleNoteToCloud(noteId: UUID) -> Bool {
        guard let cloud = cloudSyncFS,
              let note = getNote(id: noteId) else {
            return false
        }
        // 构建云端路径
        let folderPath = getFolderPath(for: note.folderId)
        let cloudRoot = cloud.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        var cloudURL = cloudRoot
        if !folderPath.isEmpty {
            for component in folderPath.split(separator: "/") {
                cloudURL.appendPathComponent(String(component), isDirectory: true)
            }
        }
        // 确保目录存在
        do {
            try cloud.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
        } catch {}
        cloudURL.appendPathComponent("\(note.title).md")
        
        // 生成带 frontmatter 的内容
        let body = MarkdownFrontmatterParser.build(title: note.title, tags: note.tags, body: note.markdownContent)
        guard let data = body.data(using: .utf8) else { return false }
        
        do {
            try cloud.writeData(data, to: cloudURL)
            return true
        } catch {
            return false
        }
    }

    /// 从指定 FS 递归扫描 .md 文件
    private func collectMarkdownFilesFromFS(_ fs: CloudFileSystem, at url: URL, skipNames: Set<String>, into result: inout [URL]) {
        let children: [URL]
        do { children = try fs.contentsOfDirectory(at: url) } catch { return }
        for child in children {
            let name = child.lastPathComponent
            if skipNames.contains(name) { continue }
            var subChildren: [URL] = []
            do { subChildren = try fs.contentsOfDirectory(at: child) } catch {}
            let ext = child.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                result.append(child)
            } else if !subChildren.isEmpty {
                collectMarkdownFilesFromFS(fs, at: child, skipNames: skipNames, into: &result)
            }
        }
    }

    /// 把本地文件 URL 映射到云端对应路径
    private func cloudNoteURL(for localURL: URL, cloudFS: CloudFileSystem) -> URL {
        let localRoot = fileSystem.notesRootDirectory
        let relative = relativePathComponents(of: localURL, from: localRoot)
        var cloudURL = cloudFS.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        for comp in relative {
            cloudURL = cloudURL.appendingPathComponent(comp)
        }
        return cloudURL
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
    
    /// ✅ 主线程触发 UI 刷新（导入在后台线程修改 @Published 属性后调用，确保 UI 更新）
    func triggerRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
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
    
    /// 从存储根目录递归扫描 Markdown 并导入笔记库（支持本机/iCloud/WebDAV 全部 Provider）
    /// - 跳过内部目录 Notes/ 和 .metadata/
    /// - 按物理相对路径自动创建 Folder 层级
    /// - 解析 YAML Frontmatter（title/tags/date）
    /// - 去重：同路径+同标题已存在时跳过
    @discardableResult
    func importMarkdownFromDocuments() -> ImportReport {
        let root = fileSystem.notesRootDirectory  // ✅ 只扫描 Notes 目录（笔记都在这里），不扫整个根目录
        var report = ImportReport()

        // 1. 递归枚举所有 .md / .markdown 文件（通过 cloudFS 协议，兼容 WebDAV）
        let skipNames: Set<String> = [".metadata"]  // 从 Notes 开始扫，不需要跳过 Notes 自身
        var mdFiles: [URL] = []
        collectMarkdownFiles(at: root, skipNames: skipNames, into: &mdFiles)

        report.scannedMarkdownFiles = mdFiles.count

        guard report.scannedMarkdownFiles > 0 else {
            report.warningMessages.append("Notes 目录没有发现 .md/.markdown 文件（请确认笔记放在了远端的 Notes/ 目录下；本机模式：通过爱思助手把 Markdown 文件夹拖入 App 共享目录的 Notes/ 下）")
            return report
        }

        // 2. 逐个导入
        for (idx, srcURL) in mdFiles.enumerated() {
            let relativePathComponents = relativePathComponents(of: srcURL, from: root)
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

    /// 递归扫描目录树，收集所有 .md/.markdown 文件 URL（通过 cloudFS 协议，兼容 WebDAV/iCloud/本机）
    private func collectMarkdownFiles(at url: URL, skipNames: Set<String>, into result: inout [URL]) {
        // ✅ 优先用带类型的列举（WebDAVFS 实现了 contentsOfDirectoryWithTypes），
        //    不再靠"尝试 PROPFIND 成不成功"来猜是不是文件夹
        let children: [(url: URL, isDirectory: Bool)]
        do {
            if let webdav = fileSystem.cloudFS as? WebDAVFS {
                children = try webdav.contentsOfDirectoryWithTypes(at: url)
            } else {
                // 本地 / iCloud：FileManager 可以直接拿 isDirectory
                let urls = try fileSystem.cloudFS.contentsOfDirectory(at: url)
                children = urls.map { u in
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return (u, isDir)
                }
            }
        } catch {
            return
        }
        for (child, isDirectory) in children {
            let name = child.lastPathComponent
            // 跳过内部目录
            if skipNames.contains(name) { continue }
            if isDirectory {
                // 是文件夹 → 直接递归
                collectMarkdownFiles(at: child, skipNames: skipNames, into: &result)
            } else {
                // 是文件 → 检查扩展名
                let ext = child.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" {
                    result.append(child)
                }
            }
        }
    }

    /// 计算 URL 相对于 root 的路径组件（兼容 WebDAV https:// URL 和本地 file:// URL）
    /// 计算 URL 相对于 root 的路径组件（兼容 WebDAV https:// URL 和本地 file:// URL）
    private func relativePathComponents(of url: URL, from root: URL) -> [String] {
        let rootParts = root.pathComponents
        let urlParts = url.pathComponents
        let common = rootCount(urlParts, rootParts)
        guard urlParts.count > common else { return [] }
        return Array(urlParts.dropFirst(common))
    }

    /// 计算共同前缀长度（用于 relativePathComponents）
    /// ✅ 从头对齐比较共同前缀（旧代码从末尾对齐，导致相对路径算错、文件夹结构丢失）
    private func rootCount(_ urlParts: [String], _ rootParts: [String]) -> Int {
        var common = 0
        let maxLen = min(urlParts.count, rootParts.count)
        while common < maxLen && urlParts[common] == rootParts[common] {
            common += 1
        }
        return common
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
