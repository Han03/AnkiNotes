//
//  StorageService.swift
//  AnkiNotes
//
//  纯 WebDAV 客户端：文件系统即数据库
//  无索引文件，从 .meta sidecar 和目录结构构建内存数据
//

import Foundation

/// 存储服务：对外提供 Note / Folder 的增删改查
final class StorageService: ObservableObject {

    let fileSystem: FileSystemService
    var cloudSyncFS: CloudFileSystem?
    weak var quizService: QuizService?

    @Published private(set) var folders: [Folder] = []
    @Published private(set) var notes: [Note] = []

    var syncProgressCallback: ((_ step: String, _ progress: Double, _ detail: String) -> Void)?
    weak var syncSnapshotService: SyncSnapshotService?

    /// 讲稿存在性缓存
    private var lectureExistsCache: [String: Bool] = [:]

    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
        reloadFromCache()
    }

    /// 从本地文件系统重新加载所有数据
    func reloadFromCache() {
        let startTime = Date()
        let scannedFolders = fileSystem.scanFolders()
        let scannedNotes = fileSystem.scanNotes()
        let duration = Date().timeIntervalSince(startTime)
        
        folders = scannedFolders
        notes = scannedNotes
        lectureExistsCache.removeAll()
        triggerRefresh()
        
        // 诊断日志：记录扫描结果和线程信息
        let thread = Thread.isMainThread ? "main" : "background"
        let folderPreview = scannedFolders.prefix(3).map { "\($0.name)(path=\($0.path))" }.joined(separator: ", ")
        let notePreview = scannedNotes.prefix(3).map { "\($0.title)(folder=\($0.folderPath))" }.joined(separator: ", ")
        SyncLogger.shared.info("reloadFromCache 完成 [\(thread)]：文件夹 \(scannedFolders.count) 个，笔记 \(scannedNotes.count) 个，耗时 \(String(format: "%.3f", duration))s")
        SyncLogger.shared.info("  文件夹示例: \(folderPreview.isEmpty ? "(无)" : folderPreview)")
        SyncLogger.shared.info("  笔记示例: \(notePreview.isEmpty ? "(无)" : notePreview)")
    }

    func triggerRefresh() {
        objectWillChange.send()
    }

    // MARK: - 文件夹查询

    func getAllFolders() -> [Folder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func getSubFolders(of parentPath: String?) -> [Folder] {
        folders.filter { $0.parentPath == parentPath }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func getFolder(path: String) -> Folder? {
        folders.first { $0.path == path }
    }

    // MARK: - 文件夹 CRUD

    @discardableResult
    func createFolder(name: String, parentPath: String?) -> Folder {
        let path = parentPath.map { "\($0)/\(name)" } ?? name
        let folder = Folder(name: name, path: path, parentPath: parentPath)
        folders.append(folder)
        _ = try? fileSystem.createPhysicalFolder(named: name, parentPath: parentPath)
        return folder
    }

    func renameFolder(path: String, newName: String) {
        guard let idx = folders.firstIndex(where: { $0.path == path }) else { return }
        let oldName = folders[idx].name
        guard oldName != newName else { return }

        // 计算新旧路径
        let parentPath = folders[idx].parentPath
        let newPath = parentPath.map { "\($0)/\(newName)" } ?? newName

        // 更新该文件夹及所有子文件夹
        let affectedPaths = folders.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        for i in folders.indices {
            if folders[i].path == path {
                folders[i].name = newName
                folders[i].path = newPath
            } else if folders[i].path.hasPrefix(path + "/") {
                // 子文件夹：替换路径前缀
                let suffix = String(folders[i].path.dropFirst(path.count))
                folders[i].path = newPath + suffix
            }
        }

        // 更新所有笔记的 folderPath
        for i in notes.indices {
            if notes[i].folderPath == path {
                notes[i].folderPath = newPath
            } else if notes[i].folderPath.hasPrefix(path + "/") {
                let suffix = String(notes[i].folderPath.dropFirst(path.count))
                notes[i].folderPath = newPath + suffix
            }
        }

        // 重命名物理目录
        let oldURL = fileSystem.notesRootDirectory.appendingPathComponent(path, isDirectory: true)
        let newURL = fileSystem.notesRootDirectory.appendingPathComponent(newPath, isDirectory: true)
        try? FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    func deleteFolder(path: String) {
        // 删除该文件夹及子文件夹下所有笔记
        let pathsToDelete = folders.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map { $0.path }
        let notesToDelete = notes.filter { pathsToDelete.contains($0.folderPath) || $0.folderPath.hasPrefix(pathsToDelete.map { "\($0)/" }.joined()) }

        for note in notesToDelete {
            deleteNoteFiles(for: note)
        }
        notes.removeAll { n in notesToDelete.contains(where: { $0.notePath == n.notePath }) }

        // 删除物理文件夹
        let folderURL = fileSystem.notesRootDirectory.appendingPathComponent(path, isDirectory: true)
        fileSystem.deletePhysicalFolder(at: folderURL)

        folders.removeAll { pathsToDelete.contains($0.path) }

        // 删除相关题目
        let deletedNotePaths = notesToDelete.map { $0.notePath }
        if !deletedNotePaths.isEmpty {
            quizService?.deleteQuestions(for: deletedNotePaths)
        }
    }

    // MARK: - 笔记查询

    func getAllNotes() -> [Note] { notes }

    func getNotes(in folderPath: String) -> [Note] {
        notes.filter { $0.folderPath == folderPath }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func getNote(notePath: String) -> Note? {
        notes.first { $0.notePath == notePath }
    }

    /// 递归获取指定文件夹及其所有子文件夹中的笔记
    func getAllNotesRecursive(in folderPath: String) -> [Note] {
        let currentNotes = getNotes(in: folderPath)
        var subNotes: [(note: Note, path: String)] = []
        let subFolders = getSubFolders(of: folderPath.isEmpty ? nil : folderPath)
        for sub in subFolders {
            let subResult = getAllNotesRecursive(in: sub.path)
            for note in subResult {
                subNotes.append((note: note, path: note.folderPath))
            }
        }
        subNotes.sort {
            $0.path != $1.path
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : $0.note.title.localizedStandardCompare($1.note.title) == .orderedAscending
        }
        return currentNotes + subNotes.map { $0.note }
    }

    func countNotesRecursive(in folderPath: String) -> Int {
        var count = getNotes(in: folderPath).count
        let subFolders = getSubFolders(of: folderPath.isEmpty ? nil : folderPath)
        for sub in subFolders {
            count += countNotesRecursive(in: sub.path)
        }
        return count
    }

    func getNoteFolderPath(for note: Note) -> String {
        note.folderPath.isEmpty ? "根目录" : note.folderPath
    }

    // MARK: - 笔记 CRUD

    @discardableResult
    func createNote(title: String, folderPath: String = "", markdownContent: String = "", tags: [String] = []) -> Note {
        let note = Note(
            title: title,
            folderPath: folderPath,
            markdownContent: markdownContent.isEmpty ? defaultMarkdown(for: title) : markdownContent,
            tags: tags
        )

        // 写 .md 和 .meta
        let mdURL = fileSystem.noteURL(title: title, folderPath: folderPath)
        try? fileSystem.writeNoteContent(note.markdownContent, to: mdURL)
        let metaFile = NoteMetaFile(tags: note.tags, srs: note.srs, createdAt: note.createdAt, updatedAt: note.updatedAt)
        fileSystem.writeMeta(metaFile, title: title, folderPath: folderPath)

        notes.append(note)
        return note
    }

    func updateNote(_ note: Note) {
        guard let idx = notes.firstIndex(where: { $0.notePath == note.notePath }) else { return }
        var updated = note
        updated.updatedAt = Date()

        let mdURL = fileSystem.noteURL(title: updated.title, folderPath: updated.folderPath)
        try? fileSystem.writeNoteContent(updated.markdownContent, to: mdURL)
        let metaFile = NoteMetaFile(tags: updated.tags, srs: updated.srs, createdAt: updated.createdAt, updatedAt: updated.updatedAt, reviewLogs: updated.reviewLogs)
        fileSystem.writeMeta(metaFile, title: updated.title, folderPath: updated.folderPath)

        notes[idx] = updated
    }

    /// 只更新 SRS 数据（写 .meta sidecar）
    func updateNoteSRS(notePath: String, srs: SRSData) {
        guard let idx = notes.firstIndex(where: { $0.notePath == notePath }) else { return }
        notes[idx].srs = srs
        notes[idx].updatedAt = Date()
        let note = notes[idx]
        let metaFile = NoteMetaFile(tags: note.tags, srs: note.srs, createdAt: note.createdAt, updatedAt: note.updatedAt, reviewLogs: note.reviewLogs)
        fileSystem.writeMeta(metaFile, title: note.title, folderPath: note.folderPath)
    }

    func deleteNote(notePath: String) {
        guard let note = notes.first(where: { $0.notePath == notePath }) else { return }
        deleteNoteFiles(for: note)
        notes.removeAll { $0.notePath == notePath }
        quizService?.deleteQuestions(for: notePath)
    }

    /// 删除笔记的所有文件（.md + sidecars）
    private func deleteNoteFiles(for note: Note) {
        let mdURL = fileSystem.noteURL(title: note.title, folderPath: note.folderPath)
        fileSystem.deleteNoteFile(at: mdURL)
        fileSystem.deleteNoteSidecars(title: note.title, folderPath: note.folderPath)
    }

    private func defaultMarkdown(for title: String) -> String {
        """
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

    // MARK: - 讲稿

    func hasLecture(for note: Note) -> Bool {
        if let cached = lectureExistsCache[note.notePath] { return cached }
        let exists = fileSystem.lectureExists(title: note.title, folderPath: note.folderPath)
        lectureExistsCache[note.notePath] = exists
        return exists
    }

    func readLecture(for note: Note) throws -> String {
        let content = try fileSystem.readLecture(title: note.title, folderPath: note.folderPath)
        lectureExistsCache[note.notePath] = true
        return content
    }

    func writeLecture(_ content: String, for note: Note) {
        fileSystem.writeLecture(content, title: note.title, folderPath: note.folderPath)
        lectureExistsCache[note.notePath] = true
    }

    // MARK: - 复习日志（从 .meta 聚合）

    func addReviewLog(_ log: ReviewLog, for notePath: String) {
        guard let idx = notes.firstIndex(where: { $0.notePath == notePath }) else { return }
        notes[idx].reviewLogs.append(log)
        // 写回 .meta
        let note = notes[idx]
        let metaFile = NoteMetaFile(tags: note.tags, srs: note.srs, createdAt: note.createdAt, updatedAt: note.updatedAt, reviewLogs: note.reviewLogs)
        fileSystem.writeMeta(metaFile, title: note.title, folderPath: note.folderPath)
    }

    func getReviewLogs(for notePath: String) -> [ReviewLog] {
        guard let note = notes.first(where: { $0.notePath == notePath }) else { return [] }
        return note.reviewLogs.sorted { $0.reviewDate > $1.reviewDate }
    }

    /// 获取指定日期之后有复习记录的笔记路径集合（跨所有笔记聚合）
    func getReviewedNotePaths(since date: Date) -> Set<String> {
        var paths = Set<String>()
        for note in notes {
            if note.reviewLogs.contains(where: { $0.reviewDate >= date }) {
                paths.insert(note.notePath)
            }
        }
        return paths
    }

    /// 获取指定日期之后的所有复习日志（跨所有笔记聚合，用于统计）
    func getReviewLogs(since date: Date) -> [ReviewLog] {
        notes.flatMap { $0.reviewLogs.filter { $0.reviewDate >= date } }
    }

    // MARK: - 云端同步（单次扫描）

    /// 从云端导入数据（单次递归扫描 Notes/）
    func importFromCloud(rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) -> ImportReport {
        var report = ImportReport()
        guard let cloud = cloudSyncFS else { return report }

        let cloudNotesRoot = cloud.rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        let localNotesRoot = fileSystem.notesRootDirectory

        // 递归扫描云端 Notes/ 目录
        var directoryTimes: [String: Date] = [:]
        var fileTimes: [String: Date] = [:]
        var allCloudFiles: [URL] = []

        collectFilesFromFS(
            cloud, at: cloudNotesRoot,
            extensions: ["md", "meta", "txt", "questions", "json"],
            skipNames: [],
            into: &allCloudFiles,
            rootURL: cloudNotesRoot,
            snapshot: syncSnapshotService,
            directoryTimes: &directoryTimes,
            fileTimes: &fileTimes,
            rootScanChildren: nil
        )

        // 【修复】补录 Notes/ 目录自身的快照条目（collectFilesFromFS 只记录后代，不包含根目录自身）
        // 没有这个条目，根目录级跳过检查中 snapshotDirNames 永远找不到 "Notes"
        if let notesEntry = rootScanChildren?.first(where: { $0.url.lastPathComponent == "Notes" }),
           let notesMtime = notesEntry.lastModified {
            directoryTimes["Notes"] = notesMtime
        }

        report.scannedMarkdownFiles = allCloudFiles.filter { $0.pathExtension == "md" }.count
        syncProgressCallback?("同步云端文件", 10, "发现 \(allCloudFiles.count) 个需要检查的文件")

        // 逐个处理文件
        for (idx, srcURL) in allCloudFiles.enumerated() {
            if idx % 10 == 0 || idx == allCloudFiles.count - 1 {
                let total = max(allCloudFiles.count, 1)
                let progress = Double(10 + Int(Double(idx) / Double(total) * 80))
                let label = "\(idx + 1)/\(allCloudFiles.count)"
                syncProgressCallback?("下载文件", progress, label)
            }

            let relativePath = fileSystem.relativePathFromNotes(localURL(forCloud: srcURL, cloudRoot: cloudNotesRoot, localRoot: localNotesRoot))
            // 快照 key 需要与 collectFilesFromFS 中的格式一致（带 Notes/ 前缀）
            let snapshotKey = "Notes/" + relativePath

            // 快照跳过检查（传入云端 mtime，nil 会导致 isFileUpdated 永远返回 true）
            let fileMtime = fileTimes[snapshotKey]
            if let snap = syncSnapshotService,
               !snap.isFileUpdated(relativePath: snapshotKey, lastModified: fileMtime) {
                // 文件无更新，跳过下载，但仍刷新快照时间戳
                snap.updateFile(relativePath: snapshotKey, lastModified: fileMtime)
                continue
            }

            do {
                let data = try cloud.readData(at: srcURL)
                let localURL = localURL(forCloud: srcURL, cloudRoot: cloudNotesRoot, localRoot: localNotesRoot)
                try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: localURL, options: .atomic)

                // 更新快照（使用云端 mtime，而非本地 mtime）
                if let snap = syncSnapshotService {
                    let cloudMtime = fileTimes[snapshotKey]
                    snap.updateFile(relativePath: snapshotKey, lastModified: cloudMtime)
                }

                // 统计
                switch srcURL.pathExtension {
                case "md": report.importedCount += 1
                case "txt": report.lectureImportedCount += 1
                case "questions": report.questionImportedCount += 1
                default: break
                }
            } catch {
                report.failedCount += 1
                print("⚠️ 同步失败 \(srcURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 回写目录快照（使用云端目录 mtime，确保下次同步能正确跳过）
        for (dirPath, dirMtime) in directoryTimes {
            syncSnapshotService?.updateDirectory(relativePath: dirPath, lastModified: dirMtime)
        }
        
        // 调试日志：输出快照统计
        SyncLogger.shared.info("快照更新完成：目录快照 \(directoryTimes.count) 个，文件快照 \(fileTimes.count) 个")

        return report
    }

    /// 云端 URL → 本地 URL（恒等映射）
    private func localURL(forCloud cloudURL: URL, cloudRoot: URL, localRoot: URL) -> URL {
        var relativePath = cloudURL.path.replacingOccurrences(of: cloudRoot.path, with: "")
        // 移除所有前导斜杠，避免 appendingPathComponent 生成双斜杠路径（如 /Notes//Biology/file.md）
        while relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }
        return localRoot.appendingPathComponent(relativePath)
    }

    /// 递归收集文件（简化版 collectFilesFromFS）
    private func collectFilesFromFS(_ fs: CloudFileSystem, at url: URL, extensions: [String], skipNames: [String], into result: inout [URL], rootURL: URL, snapshot: SyncSnapshotService?, directoryTimes: inout [String: Date], fileTimes: inout [String: Date], rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]?) {
        let children: [(url: URL, isDirectory: Bool, lastModified: Date?)]
        if let rootScanChildren = rootScanChildren {
            children = rootScanChildren
        } else {
            do {
                children = try fs.contentsOfDirectoryWithMetadata(at: url)
            } catch { return }
        }

        for child in children {
            let name = child.url.lastPathComponent
            if skipNames.contains(name) || name.hasPrefix(".") { continue }

            if child.isDirectory {
                // 记录目录时间
                if let snap = snapshot {
                    let relativePath = snap.relativePath(for: child.url, rootURL: rootURL)
                    let prefixedPath = rootURL.lastPathComponent + (relativePath.isEmpty ? "" : "/" + relativePath)
                    if let modified = child.lastModified {
                        directoryTimes[prefixedPath] = modified
                    }
                }
                collectFilesFromFS(fs, at: child.url, extensions: extensions, skipNames: skipNames, into: &result, rootURL: rootURL, snapshot: snapshot, directoryTimes: &directoryTimes, fileTimes: &fileTimes, rootScanChildren: nil)
            } else {
                let ext = child.url.pathExtension.lowercased()
                if extensions.contains(ext) {
                    result.append(child.url)
                    // 记录云端文件 mtime（用于快照更新，避免使用本地 mtime）
                    if let snap = snapshot {
                        let relativePath = snap.relativePath(for: child.url, rootURL: rootURL)
                        let prefixedPath = rootURL.lastPathComponent + (relativePath.isEmpty ? "" : "/" + relativePath)
                        if let modified = child.lastModified {
                            fileTimes[prefixedPath] = modified
                        }
                    }
                }
            }
        }
    }

    // MARK: - 一致性校验

    /// 启动时校验：有 .meta 但无 .md 的笔记，用空内容兜底
    func consistencyCheck() {
        for i in notes.indices {
            let mdURL = fileSystem.noteURL(title: notes[i].title, folderPath: notes[i].folderPath)
            if !FileManager.default.fileExists(atPath: mdURL.path) {
                try? fileSystem.writeNoteContent("", to: mdURL, skipCloudSync: true)
            }
        }
    }

    // MARK: - 报告

    struct ImportReport {
        var scannedMarkdownFiles: Int = 0
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var failedCount: Int = 0
        var lectureImportedCount: Int = 0
        var questionImportedCount: Int = 0
        var scannedLectureFiles: Int = 0
        var scannedQuestionFiles: Int = 0
        var messages: [String] = []
        var warningMessages: [String] = []
    }
}
