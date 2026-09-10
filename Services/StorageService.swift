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
    weak var quizService: QuizService?  // 用于删除笔记时同时删除相关题目
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var noteMetas: [NoteMeta] = []
    @Published private(set) var reviewLogs: [ReviewLog] = []
    
    /// 同步进度回调（step: 当前步骤, progress: 0-100, detail: 详情）
    var syncProgressCallback: ((_ step: String, _ progress: Double, _ detail: String) -> Void)?
    /// 同步快照服务（用于增量同步）
    weak var syncSnapshotService: SyncSnapshotService?
    
    /// 讲稿存在性缓存（避免频繁检查文件系统）
    private var lectureExistsCache: [UUID: Bool] = [:]
    
    /// 文件夹路径缓存：folderId -> 完整路径字符串 (用于 O(1) 快速查询)
    private var folderPathCache: [UUID: String] = [:]
    
    /// 清除讲稿存在性缓存（讲稿/笔记发生变化时调用）
    func clearLectureCache() {
        lectureExistsCache.removeAll()
    }
    
    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
        self.folders = fileSystem.loadFolders()
        self.noteMetas = fileSystem.loadNoteIndex()
        self.reviewLogs = fileSystem.loadReviewLogs()
        consistencyCheck()
        // 初始化时构建文件夹路径缓存
        rebuildFolderPathCache()
    }
    
    /// 从本地缓存重新加载所有元数据（元数据同步后调用）
    func reloadFromCache() {
        folders = fileSystem.loadFolders()
        noteMetas = fileSystem.loadNoteIndex()
        reviewLogs = fileSystem.loadReviewLogs()
        clearLectureCache()  // 重新加载后清除讲稿缓存
        rebuildFolderPathCache() // 重新加载后重建路径缓存
        triggerRefresh()
    }
    
    /// 重建文件夹路径缓存
    private func rebuildFolderPathCache() {
        folderPathCache.removeAll()
        for folder in folders {
            let path = computeFolderPath(folderId: folder.id, folders: folders)
            folderPathCache[folder.id] = path.isEmpty ? "根目录" : path
        }
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
        // 更新缓存：直接计算并存储新文件夹的路径
        let path = computeFolderPath(folderId: folder.id, folders: folders)
        folderPathCache[folder.id] = path.isEmpty ? "根目录" : path
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
        // 更新缓存
        let path = computeFolderPath(folderId: folder.id, folders: folders)
        folderPathCache[folder.id] = path.isEmpty ? "根目录" : path
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
        
        // 更新缓存：重新计算该文件夹及其所有子文件夹的路径
        let affectedIds = collectDescendantFolderIds(from: id)
        for fid in affectedIds {
            let path = computeFolderPath(folderId: fid, folders: folders)
            folderPathCache[fid] = path.isEmpty ? "根目录" : path
        }
        
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
        
        // 收集需要删除的笔记 ID（用于删除相关题目）
        let deletedNoteIds = notesToDelete.map { $0.id }
        
        // 收集云端文件 URL（用于后台删除）
        var cloudURLsToDelete: [URL] = []
        if let cloud = cloudSyncFS {
            for meta in notesToDelete {
                let localURL = buildOldFileURL(meta: meta)
                let cloudURL = cloudNoteURL(for: localURL, cloudFS: cloud)
                cloudURLsToDelete.append(cloudURL)
            }
        }
        
        // 删除本地笔记文件
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
            
            // 后台删除云端文件夹
            if let cloud = cloudSyncFS {
                let cloudFolderURL = cloudNoteURL(for: target, cloudFS: cloud)
                DispatchQueue.global(qos: .background).async {
                    try? cloud.removeItem(at: cloudFolderURL)
                    print("☁️ 云端删除文件夹: \(folder.name)")
                }
            }
        }
        
        // 后台删除云端笔记文件
        if !cloudURLsToDelete.isEmpty {
            DispatchQueue.global(qos: .background).async { [weak self] in
                guard let cloud = self?.cloudSyncFS else { return }
                for url in cloudURLsToDelete {
                    try? cloud.removeItem(at: url)
                }
                print("☁️ 云端删除 \(cloudURLsToDelete.count) 个笔记文件")
            }
        }
        
        folders.removeAll { folderIdsToDelete.contains($0.id) }
        persistFolders()
        persistNoteIndex()
        
        // 更新缓存：移除已删除文件夹的路径
        folderIdsToDelete.forEach { folderPathCache.removeValue(forKey: $0) }
        
        // 删除相关题目
        if !deletedNoteIds.isEmpty {
            quizService?.deleteQuestions(for: deletedNoteIds)
        }
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
    /// 计算文件夹的完整路径（通用方法，可指定 folders 列表）
    private func computeFolderPath(folderId: UUID?, folders: [Folder]) -> String {
        guard let folderId = folderId else { return "" }
        var components: [String] = []
        var currentId: UUID? = folderId
        while let fid = currentId {
            if let folder = folders.first(where: { $0.id == fid }) {
                components.insert(folder.name, at: 0)
                currentId = folder.parentId
            } else {
                break
            }
        }
        return components.joined(separator: "/")
    }

    func getFolderPath(for folderId: UUID?) -> String {
        guard let folderId = folderId else { return "根目录" }
        if let cached = folderPathCache[folderId] {
            return cached
        }
        // 缓存未命中，回退到计算逻辑
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
        let path = components.joined(separator: "/")
        folderPathCache[folderId] = path.isEmpty ? "根目录" : path
        return folderPathCache[folderId]!
    }

    /// 获取笔记所在文件夹的路径
    func getNoteFolderPath(for note: Note) -> String {
        return getFolderPath(for: note.folderId)
    }
    
    // MARK: - 课堂讲稿
    
    /// 检查笔记是否有对应的课堂讲稿（带缓存，避免频繁检查文件系统）
    func hasLecture(for note: Note) -> Bool {
        // 先检查缓存
        if let cached = lectureExistsCache[note.id] {
            return cached
        }
        // 缓存未命中，检查文件系统
        let exists = fileSystem.lectureExists(folderId: note.folderId, title: note.title, folders: folders)
        lectureExistsCache[note.id] = exists
        return exists
    }
    
    /// 读取课堂讲稿内容
    func readLecture(for note: Note) throws -> String {
        let content = try fileSystem.readLecture(folderId: note.folderId, title: note.title, folders: folders)
        // 读取成功后更新缓存
        lectureExistsCache[note.id] = true
        return content
    }
    
    @discardableResult
    func createNote(title: String, folderId: UUID?, markdownContent: String = "", tags: [String] = [], skipCloudSync: Bool = false, noteId: UUID? = nil, srs: SRSData? = nil) -> Note {
        let note = Note(
            id: noteId ?? UUID(),
            title: title,
            folderId: folderId,
            markdownContent: markdownContent.isEmpty ? defaultMarkdown(for: title) : markdownContent,
            srs: srs ?? SRSData(),
            tags: tags
        )
        
        let fileURL = fileSystem.noteFileURL(noteId: note.id, folderId: folderId, title: title, folders: folders)
        // 只写本地，不隐式上传（下方统一由 cloudNoteURL 路径显式上传，避免双重上传）
        try? fileSystem.writeNoteContent(note.markdownContent, to: fileURL, skipCloudSync: true)
        
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
        
        // 写新内容（只写本地，不隐式上传，下方统一由 cloudNoteURL 路径显式上传，避免双重上传）
        try? fileSystem.writeNoteContent(note.markdownContent, to: fileURL, skipCloudSync: true)
        
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
        // 删除相关题目
        quizService?.deleteQuestions(for: id)
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
        // 优先使用 meta.fileName 中保存的文件名（兼容旧的带 uuid 文件名）
        // 如果该文件不存在，则使用新的不带 uuid 的文件名
        let newURL = fileSystem.noteFileURL(noteId: meta.id, folderId: meta.folderId, title: meta.title, folders: folders)
        let oldURL = newURL.deletingLastPathComponent().appendingPathComponent(meta.fileName)
        if FileManager.default.fileExists(atPath: oldURL.path) {
            return oldURL
        }
        return newURL
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
    func importFromCloud(rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) -> ImportReport {
        var report = ImportReport()
        guard let cloud = cloudSyncFS else {
            report.warningMessages.append("未配置云端同步")
            return report
        }
        
        // 加载从云端拉取的元数据（用于恢复 SRS 记忆数据）
        // pullFromCloud 已将云端 .metadata 同步到本地，这里读取本地文件
        let cloudCachedFolders = fileSystem.loadFolders()
        let cloudCachedNoteMetas = fileSystem.loadNoteIndex()
        // 建立 folderId -> 文件夹完整路径 的映射
        var cloudFolderPathMap: [UUID: String] = [:]
        for folder in cloudCachedFolders {
            cloudFolderPathMap[folder.id] = computeFolderPath(folderId: folder.id, folders: cloudCachedFolders)
        }
        // 建立 "文件夹路径/笔记标题" -> noteMeta 的映射（用于恢复 SRS 数据）
        var cloudNoteMetaMap: [String: NoteMeta] = [:]
        for noteMeta in cloudCachedNoteMetas {
            if let fid = noteMeta.folderId, let folderPath = cloudFolderPathMap[fid] {
                let key = "\(folderPath)/\(noteMeta.title.lowercased())"
                cloudNoteMetaMap[key] = noteMeta
            }
        }
        if !cloudNoteMetaMap.isEmpty {
            print("📥 从云端元数据恢复记忆数据，共 \(cloudNoteMetaMap.count) 篇笔记的记忆记录")
        }
        
        let cloudRoot = cloud.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        let skipNames: Set<String> = [".metadata"]
        var cloudFiles: [URL] = []
        // 收集目录的云端修改时间（下载成功后用于更新快照目录记录）
        var directoryTimes: [String: Date] = [:]
        // 收集文件的云端修改时间（跳过分支用于更新快照，使快照收敛）
        var fileTimes: [String: Date] = [:]
        // 传入快照和根目录，支持目录级和文件级跳过
        collectMarkdownFilesFromFS(cloud, at: cloudRoot, skipNames: skipNames, into: &cloudFiles, rootURL: cloudRoot, snapshot: syncSnapshotService, directoryTimes: &directoryTimes, fileTimes: &fileTimes, rootScanChildren: rootScanChildren)
        report.scannedMarkdownFiles = cloudFiles.count
        syncProgressCallback?("扫描云端文件", 5, "发现 \(cloudFiles.count) 篇需要更新的笔记")
        // 云端 Notes 目录没有 .md 文件是正常状态（可能只同步讲稿/题目），不阻断后续同步
        for (idx, srcURL) in cloudFiles.enumerated() {
            // 更新同步进度（笔记导入占 5%-50%）
            let noteProgress = 5.0 + Double(idx) / Double(cloudFiles.count) * 45.0
            if idx % 5 == 0 || idx == cloudFiles.count - 1 {
                syncProgressCallback?("导入笔记", noteProgress, "\(idx + 1)/\(cloudFiles.count) - \(srcURL.lastPathComponent)")
            }
            do {
                let relativeComponents = relativePathComponents(of: srcURL, from: cloudRoot)
                let folderComponents = Array(relativeComponents.dropLast())
                let fileName = srcURL.lastPathComponent
                // 直接取文件名去掉 .md/.markdown 后缀作为 title，不使用 frontmatter title
                // 保证笔记 title 与题库/讲稿文件名匹配一致（无需下载内容即可计算）
                var title = fileName
                if title.lowercased().hasSuffix(".markdown") {
                    title = String(title.dropLast(9))
                } else if title.lowercased().hasSuffix(".md") {
                    title = String(title.dropLast(3))
                }
                if title.isEmpty { title = "未命名-\(UUID().uuidString.prefix(6))" }
                let folderId = try getOrCreateFolder(pathComponents: folderComponents, createdCount: &report.folderCreatedCount)
                // 【优化】exists 判断提前到下载内容之前：本地已存在的文件无需 GET 云端全文
                let exists = noteMetas.contains { m in
                    m.folderId == folderId && m.title.lowercased() == title.lowercased()
                }
                if exists {
                    report.skippedCount += 1
                    if report.messages.count < 10 {
                        report.messages.append("⏭️ 跳过重复：\(folderComponents.joined(separator: "/"))/\(title)")
                    }
                    // 【修复】跳过分支也更新快照（用扫描时已知的云端修改时间，不额外请求）
                    // 使快照收敛：本地已存在的文件下次同步不再判定"有更新"，
                    // 避免"判定有更新但本地已存在"的文件每次同步都重新下载全文，永不收敛
                    if let snap = syncSnapshotService {
                        updateSnapshotForSkippedFile(snap: snap, rootURL: cloudRoot, fileURL: srcURL, fileTimes: fileTimes, directoryTimes: directoryTimes)
                    }
                    continue
                }
                // 只有真正需要创建时才下载内容
                let rawBody = try cloud.readData(at: srcURL)
                let bodyStr = String(data: rawBody, encoding: .utf8) ?? ""
                let parsed = MarkdownFrontmatterParser.parse(bodyStr)
                let bodyToUse = parsed.body.isEmpty ? bodyStr : parsed.body
                // 尝试从云端元数据中恢复 SRS 记忆数据（通过文件夹路径+标题匹配）
                let folderPath = folderComponents.joined(separator: "/")
                let matchKey = "\(folderPath)/\(title.lowercased())"
                var recoveredNoteId: UUID? = nil
                var recoveredSrs: SRSData? = nil
                if let cloudNoteMeta = cloudNoteMetaMap[matchKey] {
                    recoveredNoteId = cloudNoteMeta.id
                    recoveredSrs = cloudNoteMeta.srs
                    report.messages.append("📥 恢复记忆: \(title) (间隔:\(cloudNoteMeta.srs.interval)天 难度:\(String(format: "%.2f", cloudNoteMeta.srs.easeFactor)))")
                }
                createNote(title: title, folderId: folderId, markdownContent: bodyToUse, tags: parsed.tags, skipCloudSync: true, noteId: recoveredNoteId, srs: recoveredSrs)
                report.importedCount += 1
                if report.messages.count < 10 {
                    let prefix = folderComponents.isEmpty ? "" : folderComponents.joined(separator: "/") + "/"
                    report.messages.append("✅ \(prefix)\(title)")
                }
                // 更新快照中的文件修改时间（下载成功后才更新，失败文件下次同步可重试）
                if let snap = syncSnapshotService {
                    updateSnapshotAfterFileSync(cloud: cloud, snap: snap, rootURL: cloudRoot, fileURL: srcURL, directoryTimes: directoryTimes, fileTimes: fileTimes)
                }
            } catch {
                report.failedCount += 1
                if report.warningMessages.count < 5 {
                    report.warningMessages.append("❌ 导入失败 \(srcURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // 每 50 条且确有导入/建文件夹时才持久化（避免无变化时刷新索引文件修改时间触发重复推送）
            if idx % 50 == 0 && (report.importedCount > 0 || report.folderCreatedCount > 0) {
                persistFolders()
                persistNoteIndex()
            }
        }
        // 只在确有变化时持久化；无变化时重写会刷新修改时间，导致 pushToCloud 误判有更新
        if report.importedCount > 0 || report.folderCreatedCount > 0 {
            persistFolders()
            persistNoteIndex()
        }
        
        // 同步课堂讲稿（Lecture 目录下的 .txt 文件）
        syncProgressCallback?("同步讲稿", 55, "正在扫描云端讲稿...")
        syncLecturesFromCloud(cloud: cloud, report: &report, snapshot: syncSnapshotService, rootScanChildren: rootScanChildren)
        syncProgressCallback?("同步题库", 75, "正在扫描云端题库...")
        syncQuestionsFromCloud(cloud: cloud, report: &report, snapshot: syncSnapshotService, rootScanChildren: rootScanChildren)
        syncProgressCallback?("同步完成", 100, "笔记 \(report.importedCount) 篇，讲稿 \(report.lectureImportedCount) 个，题库已同步")
        
        return report
    }
    
    /// 智能合并题目：基于 updatedAt 合并本地和云端题目，避免多端做题时覆盖答题记录
    private func mergeQuestions(local: [Question], cloud: [Question]) -> [Question] {
        var merged: [UUID: Question] = [:]
        
        // 先加入云端题目
        for q in cloud {
            merged[q.id] = q
        }
        
        // 再加入本地题目，比较 updatedAt 保留较新的
        for localQ in local {
            if let cloudQ = merged[localQ.id] {
                // 两端都有，比较 updatedAt，保留较新的答题记录
                if localQ.updatedAt >= cloudQ.updatedAt {
                    merged[localQ.id] = localQ
                }
                // 否则保留云端的
            } else {
                // 只有本地有，保留本地
                merged[localQ.id] = localQ
            }
        }
        
        let result = Array(merged.values)
        let cloudIds = Set(cloud.map { $0.id })
        let localIds = Set(local.map { $0.id })
        let localOnly = local.filter { !cloudIds.contains($0.id) }.count
        let cloudOnly = cloud.filter { !localIds.contains($0.id) }.count
        let both = local.filter { cloudIds.contains($0.id) }.count
        if !local.isEmpty || !cloud.isEmpty {
            print("🔄 题目数据合并: 本地\(local.count)题 + 云端\(cloud.count)题 → 合并\(result.count)题 (仅本地\(localOnly), 仅云端\(cloudOnly), 两端都有\(both))")
        }
        return result
    }

    /// 从云端同步课堂讲稿
    private func syncLecturesFromCloud(cloud: CloudFileSystem, report: inout ImportReport, snapshot: SyncSnapshotService? = nil, rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) {
        let lectureRoot = cloud.rootDirectory.appendingPathComponent("Lecture", isDirectory: true)
        var lectureFiles: [URL] = []
        // 收集目录的云端修改时间（下载成功后用于更新快照目录记录）
        var directoryTimes: [String: Date] = [:]
        var fileTimes: [String: Date] = [:]
        // 【优化】从根目录扫描结果中查找 Lecture 子项，省去一次 PROPFIND
        let lectureChildren = rootScanChildren?.first(where: { $0.url.lastPathComponent == "Lecture" }).flatMap { [$0] }
        collectFilesFromFS(cloud, at: lectureRoot, extensions: ["txt"], skipNames: [], into: &lectureFiles, rootURL: lectureRoot, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes, rootScanChildren: lectureChildren)
        report.scannedLectureFiles = lectureFiles.count
        print("📖 讲稿同步: 扫描到 \(lectureFiles.count) 个需要更新的讲稿文件")
        for srcURL in lectureFiles {
            do {
                let relativeComponents = relativePathComponents(of: srcURL, from: lectureRoot)
                let folderComponents = Array(relativeComponents.dropLast())
                let fileName = srcURL.lastPathComponent
                // 直接取文件名去掉 .txt 后缀作为 title，与笔记 title（文件名去掉.md）保持一致
                let title = fileName.lowercased().hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
                // 找到对应的文件夹
                let folderId = getFolderId(for: folderComponents)
                if folderId == nil && !folderComponents.isEmpty {
                    print("⚠️ 讲稿同步: 文件夹未找到 \(folderComponents.joined(separator: "/"))，讲稿 \(title) 将写到根目录")
                }
                // 保存讲稿到本地
                let rawBody = try cloud.readData(at: srcURL)
                let bodyStr = String(data: rawBody, encoding: .utf8) ?? ""
                // 不使用 try?，捕获错误并打印
                do {
                    try fileSystem.writeLecture(bodyStr, folderId: folderId, title: title, folders: folders, skipCloudSync: true)
                    report.lectureImportedCount += 1
                    print("✅ 讲稿同步: 导入 \(title) (\(bodyStr.count) 字符)")
                    // 更新快照中的文件修改时间（下载成功后才更新，失败文件下次同步可重试）
                    if let snap = snapshot {
                        updateSnapshotAfterFileSync(cloud: cloud, snap: snap, rootURL: lectureRoot, fileURL: srcURL, directoryTimes: directoryTimes, fileTimes: fileTimes)
                    }
                } catch {
                    print("❌ 讲稿同步: 写入失败 \(title): \(error.localizedDescription)")
                    report.lectureFailedCount += 1
                }
            } catch {
                print("❌ 讲稿同步: 读取失败 \(srcURL.lastPathComponent): \(error.localizedDescription)")
                report.lectureFailedCount += 1
            }
        }
    }
    
    /// 从云端同步题库（Questions 目录，按笔记文件夹结构存储）
    private func syncQuestionsFromCloud(cloud: CloudFileSystem, report: inout ImportReport, snapshot: SyncSnapshotService? = nil, rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) {
        let questionsRoot = cloud.rootDirectory.appendingPathComponent("Questions", isDirectory: true)
        var questionFiles: [URL] = []
        // 收集目录的云端修改时间（下载成功后用于更新快照目录记录）
        var directoryTimes: [String: Date] = [:]
        var fileTimes: [String: Date] = [:]
        // 【优化】从根目录扫描结果中查找 Questions 子项，省去一次 PROPFIND
        let questionsChildren = rootScanChildren?.first(where: { $0.url.lastPathComponent == "Questions" }).flatMap { [$0] }
        collectFilesFromFS(cloud, at: questionsRoot, extensions: ["json"], skipNames: [], into: &questionFiles, rootURL: questionsRoot, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes, rootScanChildren: questionsChildren)
        report.scannedQuestionFiles = questionFiles.count
        print("📚 题库同步: 扫描到 \(questionFiles.count) 个题目文件")
        for srcURL in questionFiles {
            do {
                let relativeComponents = relativePathComponents(of: srcURL, from: questionsRoot)
                let folderComponents = Array(relativeComponents.dropLast())
                let fileName = srcURL.lastPathComponent
                // 直接取文件名去掉 .json 后缀作为 title，与笔记 title（文件名去掉.md）保持一致
                let title = fileName.lowercased().hasSuffix(".json") ? String(fileName.dropLast(5)) : fileName
                // 找到对应的文件夹
                let folderId = getFolderId(for: folderComponents)
                if folderId == nil && !folderComponents.isEmpty {
                    print("⚠️ 题库同步: 文件夹未找到 \(folderComponents.joined(separator: "/"))，题目 \(title) 将写到根目录")
                }
                // 读取云端题目文件
                let rawBody = try cloud.readData(at: srcURL)
                // 解码（不使用 try?，捕获错误并打印）
                let cloudQuestions: [Question]
                do {
                    cloudQuestions = try JSONDecoder().decode([Question].self, from: rawBody)
                } catch {
                    print("❌ 题库同步: 解码失败 \(fileName): \(error.localizedDescription)")
                    report.questionFailedCount += 1
                    continue
                }
                // 先读取本地题目（如果存在）
                let localQuestions = (try? fileSystem.readQuestions(folderId: folderId, title: title, folders: folders)) ?? []
                // 合并：按题目 ID 比较 updatedAt，保留较新的答题记录
                let mergedQuestions = mergeQuestions(local: localQuestions, cloud: cloudQuestions)
                // 写入本地（不使用 try?，捕获错误并打印）
                do {
                    try fileSystem.writeQuestions(mergedQuestions, folderId: folderId, title: title, folders: folders, skipCloudSync: true)
                    report.questionImportedCount += 1
                    print("✅ 题库同步: 导入 \(title) (\(mergedQuestions.count)题)")
                    // 更新快照中的文件修改时间（下载成功后才更新，失败文件下次同步可重试）
                    if let snap = snapshot {
                        updateSnapshotAfterFileSync(cloud: cloud, snap: snap, rootURL: questionsRoot, fileURL: srcURL, directoryTimes: directoryTimes, fileTimes: fileTimes)
                    }
                } catch {
                    print("❌ 题库同步: 写入失败 \(title): \(error.localizedDescription)")
                    report.questionFailedCount += 1
                }
            } catch {
                print("❌ 题库同步: 读取失败 \(srcURL.lastPathComponent): \(error.localizedDescription)")
                report.questionFailedCount += 1
            }
        }
    }
    
    /// 根据路径组件查找文件夹 ID
    private func getFolderId(for pathComponents: [String]) -> UUID? {
        guard !pathComponents.isEmpty else { return nil }
        var currentId: UUID? = nil
        for name in pathComponents {
            let safeName = fileSystem.sanitizeFileName(name)
            // 不区分大小写匹配，与 getOrCreateFolder 保持一致
            if let found = folders.first(where: { $0.parentId == currentId && $0.name.lowercased() == safeName.lowercased() }) {
                currentId = found.id
            } else {
                return nil
            }
        }
        return currentId
    }

    /// 从云端同步单个笔记（打开编辑前调用，减少冲突）
    func syncSingleNoteFromCloud(noteId: UUID) -> Bool {
        guard let cloud = cloudSyncFS,
              let note = getNote(id: noteId) else {
            return false
        }
        // 使用与本地一致的文件名规则（带 noteId），通过 cloudNoteURL 映射到云端
        let localFileURL = fileSystem.noteFileURL(noteId: note.id, folderId: note.folderId, title: note.title, folders: folders)
        let cloudURL = cloudNoteURL(for: localFileURL, cloudFS: cloud)
        
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
            // 只更新本地内容，不触发云端上传（避免循环）
            guard let idx = noteMetas.firstIndex(where: { $0.id == noteId }) else { return false }
            let meta = NoteMeta(
                id: updatedNote.id, title: updatedNote.title, folderId: updatedNote.folderId,
                fileName: localFileURL.lastPathComponent, srs: updatedNote.srs,
                createdAt: updatedNote.createdAt, updatedAt: updatedNote.updatedAt, tags: updatedNote.tags
            )
            noteMetas[idx] = meta
            // 只更新本地内容，不触发云端上传（避免循环：上传会刷新云端修改时间，导致下次同步又拉取）
            try? fileSystem.writeNoteContent(updatedNote.markdownContent, to: localFileURL, skipCloudSync: true)
            persistNoteIndex()
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
    private func collectMarkdownFilesFromFS(_ fs: CloudFileSystem, at url: URL, skipNames: Set<String>, into result: inout [URL], rootURL: URL? = nil, snapshot: SyncSnapshotService? = nil, directoryTimes: inout [String: Date], fileTimes: inout [String: Date], rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) {
        collectFilesFromFS(fs, at: url, extensions: ["md", "markdown"], skipNames: skipNames, into: &result, rootURL: rootURL, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes, rootScanChildren: rootScanChildren)
    }
    
    /// 递归收集指定扩展名的云端文件（供 MetadataSyncService 知识点缓存同步共用）
    /// - Parameter rootScanChildren: 预获取的目录子项列表（由根目录扫描传入），非 nil 时省去一次 PROPFIND
    func collectFilesFromFS(_ fs: CloudFileSystem, at url: URL, extensions: [String], skipNames: Set<String>, into result: inout [URL], rootURL: URL? = nil, snapshot: SyncSnapshotService? = nil, directoryTimes: inout [String: Date], fileTimes: inout [String: Date], rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) {
        // 【优化】如果传入了预扫描的子项列表（来自根目录 PROPFIND Depth:1），直接使用，省去一次 PROPFIND
        let children: [(url: URL, isDirectory: Bool, lastModified: Date?)]
        if let preScanned = rootScanChildren {
            children = preScanned
        } else {
            // 使用 contentsOfDirectoryWithMetadata 一次获取子项和类型及修改时间，避免对每个子项发起额外请求
            do { children = try fs.contentsOfDirectoryWithMetadata(at: url) } catch { return }
        }
        processChildItems(children, fs: fs, extensions: extensions, skipNames: skipNames, into: &result, rootURL: rootURL, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes)
    }
    
    /// 处理目录子项：收集匹配文件、递归子目录（从 collectFilesFromFS 提取，避免代码重复）
    private func processChildItems(_ children: [(url: URL, isDirectory: Bool, lastModified: Date?)], fs: CloudFileSystem, extensions: [String], skipNames: Set<String>, into result: inout [URL], rootURL: URL?, snapshot: SyncSnapshotService?, directoryTimes: inout [String: Date], fileTimes: inout [String: Date]) {
        for (child, isDirectory, lastModified) in children {
            let name = child.lastPathComponent
            if skipNames.contains(name) { continue }
            let ext = child.pathExtension.lowercased()
            if extensions.contains(ext) {
                // 文件级跳过：基于【上次】快照判断，有更新才加入下载列表
                // 【修复】不在扫描阶段写入快照（旧逻辑先 updateFile 再 isFileUpdated 导致永远判定无更新被跳过）
                // 快照只在文件实际下载成功/确认本地已存在后更新，避免下载失败的文件被永久跳过
                if let root = rootURL, let snap = snapshot {
                    let relativePath = snap.relativePath(for: child, rootURL: root)
                    // key 加根目录前缀，避免 Notes/Lecture/Questions 下同名子目录互相覆盖
                    let prefixedPath = root.lastPathComponent + "/" + relativePath
                    // 收集文件的云端修改时间（跳过分支用于更新快照，支持下次文件级跳过）
                    if let modified = lastModified {
                        fileTimes[prefixedPath] = modified
                    }
                    if !snap.isFileUpdated(relativePath: prefixedPath, lastModified: lastModified) {
                        continue  // 文件无更新，跳过
                    }
                }
                result.append(child)
            } else if isDirectory {
                // 目录级跳过：仅当快照中已有该目录记录且无更新时才跳过
                // 快照目录记录只在目录下有文件下载成功时写入，避免上次同步失败后目录被误跳过
                if let root = rootURL, let snap = snapshot {
                    let relativePath = snap.relativePath(for: child, rootURL: root)
                    let prefixedPath = root.lastPathComponent + "/" + relativePath
                    // 收集目录的云端修改时间（下载成功后用于更新快照目录记录，支持下次目录级跳过）
                    if let modified = lastModified {
                        directoryTimes[prefixedPath] = modified
                    }
                    if !snap.isDirectoryUpdated(relativePath: prefixedPath, lastModified: lastModified) {
                        continue  // 目录无更新且已有成功记录，跳过
                    }
                }
                // 递归子目录（不再传递 rootScanChildren，子目录需要自己的 PROPFIND）
                collectFilesFromFS(fs, at: child, extensions: extensions, skipNames: skipNames, into: &result, rootURL: rootURL, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes)
            }
        }
    }
    
    /// 文件下载成功后更新快照（文件级 + 父目录级）
    /// - 快照 key 带根目录前缀（Notes/Lecture/Questions），避免同名子目录互相覆盖
    /// - 只有下载成功才更新，失败文件下次同步可重试
    /// - 【优化】使用扫描阶段已收集的 fileTimes 代替额外的 getItemMetadata PROPFIND
    func updateSnapshotAfterFileSync(cloud: CloudFileSystem, snap: SyncSnapshotService, rootURL: URL, fileURL: URL, directoryTimes: [String: Date], fileTimes: [String: Date]) {
        let rootName = rootURL.lastPathComponent
        let relativePath = snap.relativePath(for: fileURL, rootURL: rootURL)
        let prefixedPath = rootName + "/" + relativePath
        
        // 【优化】文件记录：使用扫描阶段已收集的修改时间，不再额外发起 PROPFIND
        if let modified = fileTimes[prefixedPath] {
            snap.updateFile(relativePath: prefixedPath, lastModified: modified)
        } else if let meta = try? cloud.getItemMetadata(at: fileURL), let time = meta.lastModified {
            // 兆底：如果 fileTimes 中没有记录（理论上不应发生），回退到 getItemMetadata
            snap.updateFile(relativePath: prefixedPath, lastModified: time)
        }
        
        // 更新所有父目录记录（用扫描时收集的云端目录修改时间，支持下次目录级跳过）
        var dirPath = String(prefixedPath.dropLast(fileURL.lastPathComponent.count))
        if dirPath.hasSuffix("/") { dirPath = String(dirPath.dropLast()) }
        while !dirPath.isEmpty {
            if let dirTime = directoryTimes[dirPath] {
                snap.updateDirectory(relativePath: dirPath, lastModified: dirTime)
            }
            if let idx = dirPath.lastIndex(of: "/") {
                dirPath = String(dirPath[..<idx])
            } else {
                break
            }
        }
    }

    /// 跳过分支更新快照（文件 + 父目录），用扫描时已知的云端修改时间，不额外发起请求
    /// 目的：本地已存在的文件（exists 跳过）也记录快照，使快照收敛，
    /// 避免"判定有更新但本地已存在"的文件每次同步都重新下载判定，永不收敛
    private func updateSnapshotForSkippedFile(snap: SyncSnapshotService, rootURL: URL, fileURL: URL, fileTimes: [String: Date], directoryTimes: [String: Date]) {
        let rootName = rootURL.lastPathComponent
        let relativePath = snap.relativePath(for: fileURL, rootURL: rootURL)
        let prefixedPath = rootName + "/" + relativePath

        // 文件记录（用扫描时收集的云端修改时间，不额外请求）
        if let modified = fileTimes[prefixedPath] {
            snap.updateFile(relativePath: prefixedPath, lastModified: modified)
        }

        // 更新所有父目录记录（与 updateSnapshotAfterFileSync 相同逻辑）
        var dirPath = String(prefixedPath.dropLast(fileURL.lastPathComponent.count))
        if dirPath.hasSuffix("/") { dirPath = String(dirPath.dropLast()) }
        while !dirPath.isEmpty {
            if let dirTime = directoryTimes[dirPath] {
                snap.updateDirectory(relativePath: dirPath, lastModified: dirTime)
            }
            if let idx = dirPath.lastIndex(of: "/") {
                dirPath = String(dirPath[..<idx])
            } else {
                break
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
        SyncLogger.shared.debug("☁️ 路径映射: \(localURL.lastPathComponent) -> \(cloudURL.path)")
        return cloudURL
    }
    
    // MARK: - 一致性校验
    
    /// 启动时校验：索引存在但文件丢失的笔记，用空内容兜底
    private func consistencyCheck() {
        var didFix = false
        for (idx, meta) in noteMetas.enumerated() {
            let newURL = fileSystem.noteFileURL(noteId: meta.id, folderId: meta.folderId, title: meta.title, folders: folders)
            let oldURL = newURL.deletingLastPathComponent().appendingPathComponent(meta.fileName)
            
            // 情况1：新文件名存在，正常
            if FileManager.default.fileExists(atPath: newURL.path) {
                if meta.fileName != newURL.lastPathComponent {
                    var newMeta = meta
                    newMeta.fileName = newURL.lastPathComponent
                    noteMetas[idx] = newMeta
                    didFix = true
                }
                continue
            }
            
            // 情况2：旧文件名（带 uuid）存在，迁移到新文件名
            if FileManager.default.fileExists(atPath: oldURL.path) && oldURL.path != newURL.path {
                do {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                    var newMeta = meta
                    newMeta.fileName = newURL.lastPathComponent
                    noteMetas[idx] = newMeta
                    didFix = true
                    print("✅ 迁移旧文件: \(meta.fileName) -> \(newURL.lastPathComponent)")
                } catch {
                    print("⚠️ 迁移文件失败: \(error.localizedDescription)")
                }
                continue
            }
            
            // 情况3：文件确实丢失，重新写入空内容（只重建本地，不隐式上传，避免用空模板覆盖云端真实内容）
            let content = defaultMarkdown(for: meta.title)
            try? fileSystem.writeNoteContent(content, to: newURL, skipCloudSync: true)
            var newMeta = meta
            newMeta.fileName = newURL.lastPathComponent
            noteMetas[idx] = newMeta
            didFix = true
            print("⚠️ 文件丢失，重新创建: \(meta.title)")
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
        var scannedLectureFiles: Int = 0
        var lectureImportedCount: Int = 0
        var lectureFailedCount: Int = 0
        var scannedQuestionFiles: Int = 0
        var questionImportedCount: Int = 0
        var questionFailedCount: Int = 0
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

        // Notes 目录没有 .md 文件是正常状态（没有可导入内容），直接返回空报告
        guard report.scannedMarkdownFiles > 0 else {
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

                // 标题：直接取文件名去掉 .md/.markdown 后缀，不使用 frontmatter title
                // 保证笔记 title 与题库/讲稿文件名匹配一致
                var title = fileName
                if title.lowercased().hasSuffix(".markdown") {
                    title = String(title.dropLast(9))
                } else if title.lowercased().hasSuffix(".md") {
                    title = String(title.dropLast(3))
                }
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

            // 每 50 条且确有导入/建文件夹时才持久化（避免无变化时刷新索引文件修改时间触发重复推送）
            if idx % 50 == 0 && (report.importedCount > 0 || report.folderCreatedCount > 0) {
                persistFolders()
                persistNoteIndex()
            }
        }

        // 只在确有变化时持久化；无变化时重写会刷新修改时间，导致 pushToCloud 误判有更新
        if report.importedCount > 0 || report.folderCreatedCount > 0 {
            persistFolders()
            persistNoteIndex()
        }

        return report
    }

    /// 递归扫描目录树，收集所有 .md/.markdown 文件 URL（通过 cloudFS 协议，兼容 WebDAV/iCloud/本机）
    private func collectMarkdownFiles(at url: URL, skipNames: Set<String>, into result: inout [URL]) {
        // ✅ 优先用带类型和修改时间的列举（contentsOfDirectoryWithMetadata），
        //    不再靠"尝试 PROPFIND 成不成功"来猜是不是文件夹
        let children: [(url: URL, isDirectory: Bool, lastModified: Date?)]
        do {
            children = try fileSystem.cloudFS.contentsOfDirectoryWithMetadata(at: url)
        } catch {
            return
        }
        for (child, isDirectory, _) in children {
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
    
}
