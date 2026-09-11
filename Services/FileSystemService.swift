//
//  FileSystemService.swift
//  AnkiNotes
//
//  纯 WebDAV 客户端：文件系统即数据库
//  单一根目录 Notes/，sidecar 文件存储各类数据
//

import Foundation

/// 文件系统服务
/// 单一根目录 Notes/，所有数据通过 sidecar 文件存储
final class FileSystemService {

    // MARK: - 后端 Provider

    let cloudFS: CloudFileSystem
    weak var syncSnapshotService: SyncSnapshotService?

    init(cloudFS: CloudFileSystem) {
        self.cloudFS = cloudFS
    }

    // MARK: - 路径

    /// 本地 Documents 目录
    var localDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 根目录：本地 Documents
    var rootDirectory: URL { localDocumentsDirectory }

    /// 唯一数据根目录（Documents/Notes）
    /// 所有笔记、讲稿、题库、知识点缓存均在此目录下
    var notesRootDirectory: URL {
        let dir = localDocumentsDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 同步快照文件路径（Notes/.sync_snapshot.json）
    var snapshotFileURL: URL {
        notesRootDirectory.appendingPathComponent(".sync_snapshot.json")
    }

    // MARK: - 文件 URL 派生（统一模式：Notes/{folderPath}/{title}.{ext}）

    /// 笔记 .md 文件 URL
    func noteURL(title: String, folderPath: String) -> URL {
        var dir = notesRootDirectory
        if !folderPath.isEmpty {
            for component in folderPath.split(separator: "/") {
                dir.appendPathComponent(String(component), isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitizeFileName(title)).md")
    }

    /// 笔记附属数据 .meta 文件 URL
    func metaURL(title: String, folderPath: String) -> URL {
        noteURL(title: title, folderPath: folderPath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sanitizeFileName(title)).meta")
    }

    /// 讲稿 .lecture 文件 URL
    func lectureURL(title: String, folderPath: String) -> URL {
        noteURL(title: title, folderPath: folderPath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sanitizeFileName(title)).lecture")
    }

    /// 题库 .questions 文件 URL
    func questionsURL(title: String, folderPath: String) -> URL {
        noteURL(title: title, folderPath: folderPath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sanitizeFileName(title)).questions")
    }

    /// 知识点缓存目录（Notes/{folderPath}/knowledge_cache/{title}/）
    func knowledgeCacheDirectory(title: String, folderPath: String) -> URL {
        var dir = noteURL(title: title, folderPath: folderPath).deletingLastPathComponent()
        dir.appendPathComponent("knowledge_cache", isDirectory: true)
        dir.appendPathComponent(sanitizeFileName(title), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 知识点缓存根目录（Notes/{folderPath}/knowledge_cache/）
    func knowledgeCacheRoot(for folderPath: String) -> URL {
        var dir = notesRootDirectory
        if !folderPath.isEmpty {
            for component in folderPath.split(separator: "/") {
                dir.appendPathComponent(String(component), isDirectory: true)
            }
        }
        dir.appendPathComponent("knowledge_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var safe = name.components(separatedBy: invalidChars).joined(separator: "_")
        if safe.isEmpty { safe = "Untitled" }
        if safe.count > 80 { safe = String(safe.prefix(80)) }
        return safe
    }

    // MARK: - 题库加载

    /// 递归扫描 Notes/ 下所有 .questions 文件，加载所有题目
    func loadAllQuestionsFromDisk() -> [Question] {
        var allQuestions: [Question] = []
        let fileManager = FileManager.default
        let rootURL = notesRootDirectory

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var fileCount = 0
        var successCount = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "questions" else { continue }
            fileCount += 1
            do {
                let data = try Data(contentsOf: fileURL)
                let questions = try JSONDecoder().decode([Question].self, from: data)
                allQuestions.append(contentsOf: questions)
                successCount += 1
            } catch {
                print("⚠️ loadAllQuestionsFromDisk: 解析失败 \(fileURL.lastPathComponent)")
            }
        }

        print("📚 loadAllQuestionsFromDisk: 扫描 \(fileCount) 个文件，成功 \(successCount) 个，题目 \(allQuestions.count) 道")
        return allQuestions
    }

    /// 构建 notePath → 题目文件所在目录的映射
    func loadQuestionNotePaths() -> [String: String] {
        var paths: [String: String] = [:]
        let fileManager = FileManager.default
        let rootURL = notesRootDirectory

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "questions" else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let questions = try? JSONDecoder().decode([Question].self, from: data),
                  let first = questions.first else { continue }
            // notePath 直接从题目数据中获取
            paths[first.notePath] = first.notePath
        }
        return paths
    }

    // MARK: - 笔记 IO

    func writeNoteContent(_ content: String, to url: URL, skipCloudSync: Bool = false) throws {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Markdown 内容转 UTF-8 失败"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if !skipCloudSync {
            syncToCloud(data: data, to: url)
        }
    }

    func readNoteContent(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Markdown 文件不是有效的 UTF-8 编码"])
        }
        return str
    }

    // MARK: - .meta IO

    func writeMeta(_ meta: NoteMetaFile, title: String, folderPath: String, skipCloudSync: Bool = false) {
        let url = metaURL(title: title, folderPath: folderPath)
        do {
            let data = try JSONEncoder().encode(meta)
            try data.write(to: url, options: .atomic)
            if !skipCloudSync {
                syncToCloud(data: data, to: url)
            }
        } catch {
            print("⚠️ 写入 .meta 失败: \(error.localizedDescription)")
        }
    }

    func readMeta(title: String, folderPath: String) -> NoteMetaFile? {
        let url = metaURL(title: title, folderPath: folderPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteMetaFile.self, from: data)
    }

    // MARK: - 讲稿 IO

    func lectureExists(title: String, folderPath: String) -> Bool {
        FileManager.default.fileExists(atPath: lectureURL(title: title, folderPath: folderPath).path)
    }

    func readLecture(title: String, folderPath: String) throws -> String {
        let url = lectureURL(title: title, folderPath: folderPath)
        let data = try Data(contentsOf: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -4, userInfo: [NSLocalizedDescriptionKey: "讲稿不是有效的 UTF-8 编码"])
        }
        return str
    }

    func writeLecture(_ content: String, title: String, folderPath: String, skipCloudSync: Bool = false) {
        let url = lectureURL(title: title, folderPath: folderPath)
        guard let data = content.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if !skipCloudSync {
            syncToCloud(data: data, to: url)
        }
    }

    // MARK: - 题库 IO

    func readQuestions(title: String, folderPath: String) -> [Question] {
        let url = questionsURL(title: title, folderPath: folderPath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Question].self, from: data)) ?? []
    }

    func writeQuestions(_ questions: [Question], title: String, folderPath: String, skipCloudSync: Bool = false) {
        let url = questionsURL(title: title, folderPath: folderPath)
        do {
            let data = try JSONEncoder().encode(questions)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if !skipCloudSync {
                syncToCloud(data: data, to: url)
            }
        } catch {
            print("⚠️ 写入题库失败: \(error.localizedDescription)")
        }
    }

    func deleteQuestions(title: String, folderPath: String) {
        let url = questionsURL(title: title, folderPath: folderPath)
        try? FileManager.default.removeItem(at: url)
        deleteCloudFile(at: url)
    }

    // MARK: - 文件删除

    func deleteNoteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        deleteCloudFile(at: url)
    }

    /// 删除笔记的所有关联文件（.md + .meta + .lecture + .questions）
    func deleteNoteSidecars(title: String, folderPath: String) {
        for ext in ["meta", "lecture", "questions"] {
            let url = noteURL(title: title, folderPath: folderPath)
                .deletingLastPathComponent()
                .appendingPathComponent("\(sanitizeFileName(title)).\(ext)")
            try? FileManager.default.removeItem(at: url)
            deleteCloudFile(at: url)
        }
    }

    // MARK: - 物理文件夹

    func createPhysicalFolder(named name: String, parentPath: String?) throws -> URL {
        var currentURL = notesRootDirectory
        if let parentPath = parentPath, !parentPath.isEmpty {
            for component in parentPath.split(separator: "/") {
                currentURL.appendPathComponent(String(component), isDirectory: true)
            }
        }
        let dirURL = currentURL.appendingPathComponent(sanitizeFileName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // 新目录的快照 key：Notes/{fullRelativePath}
        let fullRelative = relativePathFromNotes(dirURL)
        let dirSnapshotKey = "Notes/" + fullRelative
        // 父目录的快照 key
        let parentRelative = (fullRelative as NSString).deletingLastPathComponent
        let parentKey = parentRelative.isEmpty ? "Notes" : "Notes/\(parentRelative)"
        // 异步创建云端目录并更新快照
        let cloudDirURL = cloudURL(forLocalURL: dirURL)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            try? self.cloudFS.createDirectoryIfNeeded(at: cloudDirURL)
            // PROPFIND 获取云端目录真实 mtime
            let cloudMod = try? self.cloudFS.getItemMetadata(at: cloudDirURL)
            let cloudMtime = cloudMod?.lastModified ?? Date()
            self.syncSnapshotService?.updateDirectory(relativePath: dirSnapshotKey, lastModified: cloudMtime)
            self.syncSnapshotService?.updateDirectory(relativePath: parentKey, lastModified: cloudMtime)
        }
        return dirURL
    }

    func deletePhysicalFolder(at url: URL) {
        let relativePath = relativePathFromNotes(url)
        let dirSnapshotKey = "Notes/" + relativePath
        let parentRelative = (relativePath as NSString).deletingLastPathComponent
        let parentKey = parentRelative.isEmpty ? "Notes" : "Notes/\(parentRelative)"
        let now = Date()
        try? FileManager.default.removeItem(at: url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.cloudFS.removeItem(at: self?.cloudURL(forLocalURL: url) ?? url)
            // 清理该目录及所有子条目的快照
            self?.syncSnapshotService?.removeEntries(withPrefix: dirSnapshotKey + "/")
            self?.syncSnapshotService?.removeDirectory(relativePath: dirSnapshotKey)
            // 更新父目录快照
            self?.syncSnapshotService?.updateDirectory(relativePath: parentKey, lastModified: now)
        }
    }

    // MARK: - 云端同步

    /// 异步同步文件到云端（路径恒等映射：本地 Documents/Notes/X = 云端 Notes/X）
    private func syncToCloud(data: Data, to localURL: URL) {
        let cloudURL = cloudURL(forLocalURL: localURL)
        // 快照 key 格式：Notes/ 前缀 + 相对路径（与 collectFilesFromFS 中的 prefixedPath 一致）
        let snapshotKey = "Notes/" + relativePathFromNotes(localURL)
        let relativePath = relativePathFromNotes(localURL)
        let parentRelative = (relativePath as NSString).deletingLastPathComponent
        let parentKey = parentRelative.isEmpty ? "Notes" : "Notes/\(parentRelative)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.cloudFS.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
                try self.cloudFS.writeData(data, to: cloudURL)
                // PROPFIND 获取云端真实 mtime（快照内必须使用云端时间）
                let cloudMod = try? self.cloudFS.getItemMetadata(at: cloudURL)
                if let cloudMtime = cloudMod?.lastModified {
                    // 更新文件快照（子）+ 父目录快照（父，用子文件的云端时间）
                    self.syncSnapshotService?.updateFile(relativePath: snapshotKey, lastModified: cloudMtime)
                    self.syncSnapshotService?.updateDirectory(relativePath: parentKey, lastModified: cloudMtime)
                }
            } catch {
                print("⚠️ 云端同步失败: \(error.localizedDescription)")
            }
        }
    }

    /// 异步删除云端文件，并清理对应快照条目
    private func deleteCloudFile(at localURL: URL) {
        let cloudURL = cloudURL(forLocalURL: localURL)
        let relativePath = relativePathFromNotes(localURL)
        let snapshotKey = "Notes/" + relativePath
        let parentRelative = (relativePath as NSString).deletingLastPathComponent
        let parentKey = parentRelative.isEmpty ? "Notes" : "Notes/\(parentRelative)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.cloudFS.removeItem(at: cloudURL)
            // 删除文件快照（子）
            self?.syncSnapshotService?.removeFile(relativePath: snapshotKey)
            // 更新父目录快照（父）
            self?.syncSnapshotService?.updateDirectory(relativePath: parentKey, lastModified: Date())
        }
    }

    /// 本地 URL → 云端 URL（恒等映射：Documents/Notes/X → cloudRoot/Notes/X）
    func cloudURL(forLocalURL url: URL) -> URL {
        let localPath = localDocumentsDirectory.path
        var relativePath = url.path.replacingOccurrences(of: localPath, with: "")
        // 移除所有前导斜杠，避免 appendingPathComponent 生成双斜杠路径
        while relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }
        return cloudFS.rootDirectory.appendingPathComponent(relativePath)
    }

    /// 本地 URL → 相对 Notes/ 的路径（用于快照 key）
    func relativePathFromNotes(_ url: URL) -> String {
        let notesPath = notesRootDirectory.path
        let fullPath = url.path
        guard fullPath.hasPrefix(notesPath) else { return fullPath }
        var relative = String(fullPath.dropFirst(notesPath.count))
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return relative
    }

    // MARK: - 目录扫描工具

    /// 从 Notes/ 目录结构推导所有文件夹
    func scanFolders() -> [Folder] {
        var folders: [Folder] = []
        let fileManager = FileManager.default
        let root = notesRootDirectory

        SyncLogger.shared.debug("scanFolders: 扫描根目录 \(root.path)")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            SyncLogger.shared.warning("scanFolders: 无法创建目录枚举器")
            return folders
        }

        for case let dirURL as URL in enumerator {
            guard let values = try? dirURL.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }
            // 跳过知识点缓存目录（非隐藏，需显式过滤）
            if dirURL.lastPathComponent == "knowledge_cache" { continue }
            let relativePath = dirURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let name = dirURL.lastPathComponent
            let parentPath: String? = {
                let parent = dirURL.deletingLastPathComponent()
                let parentRelative = parent.path.replacingOccurrences(of: root.path + "/", with: "")
                return parentRelative == root.path || parentRelative.isEmpty ? nil : parentRelative
            }()
            folders.append(Folder(name: name, path: relativePath, parentPath: parentPath))
        }
        SyncLogger.shared.debug("scanFolders: 找到 \(folders.count) 个文件夹")
        return folders
    }

    /// 扫描所有 .meta 文件，构建笔记列表（不含 markdownContent）
    func scanNotes() -> [Note] {
        var notes: [Note] = []
        var metaFileCount = 0
        var parseFailCount = 0
        let fileManager = FileManager.default
        let root = notesRootDirectory

        SyncLogger.shared.debug("scanNotes: 扫描根目录 \(root.path)")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            SyncLogger.shared.warning("scanNotes: 无法创建文件枚举器")
            return notes
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "meta" else { continue }
            metaFileCount += 1
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? JSONDecoder().decode(NoteMetaFile.self, from: data) else {
                parseFailCount += 1
                SyncLogger.shared.warning("scanNotes: 解析失败 \(fileURL.lastPathComponent)")
                continue
            }

            let title = fileURL.deletingPathExtension().lastPathComponent
            let parentDir = fileURL.deletingLastPathComponent()
            let folderPath = parentDir.path.replacingOccurrences(of: root.path + "/", with: "")
            let effectiveFolderPath = folderPath == root.path || folderPath.isEmpty ? "" : folderPath

            // 读取 .md 内容
            let mdURL = parentDir.appendingPathComponent("\(title).md")
            let content = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""

            notes.append(Note(
                title: title,
                folderPath: effectiveFolderPath,
                markdownContent: content,
                tags: meta.tags,
                srs: meta.srs,
                createdAt: meta.createdAt,
                updatedAt: meta.updatedAt,
                reviewLogs: meta.reviewLogs
            ))
        }
        SyncLogger.shared.debug("scanNotes: .meta 文件 \(metaFileCount) 个，成功 \(notes.count) 个，失败 \(parseFailCount) 个")
        return notes
    }
}
