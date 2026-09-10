//
//  FileSystemService.swift
//  AnkiNotes
//
//  重构版：通过 CloudFileSystem 协议调度（📁本地 / ☁️iCloud / 🌐WebDAV）
//  上层业务代码完全不感知底层 Provider 差异。
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 文件系统服务（StorageService 用它做文件/目录的 URL 派生 & 实际 IO 转发）
final class FileSystemService {

    // MARK: - 后端 Provider（由 AppState 在 bootstrap/applyProvider 时注入）

    let cloudFS: CloudFileSystem

    init(cloudFS: CloudFileSystem) {
        self.cloudFS = cloudFS
    }

    // MARK: - 路径（全部指向本地 Documents，云端仅用于同步备份）

    /// 本地 Documents 目录（权威数据源）
    var localDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 根目录：本地 Documents（云端仅用于同步）
    var rootDirectory: URL { localDocumentsDirectory }

    /// Markdown 物理文件总目录（Documents/Notes）
    var notesRootDirectory: URL {
        let dir = localDocumentsDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 课堂讲稿总目录（Documents/Lecture）
    var lecturesRootDirectory: URL {
        let dir = localDocumentsDirectory.appendingPathComponent("Lecture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 题库总目录（Documents/Questions，按笔记文件夹结构存储）
    var questionsRootDirectory: URL {
        let dir = localDocumentsDirectory.appendingPathComponent("Questions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 直接遍历 Questions 目录下的所有 JSON 文件，加载所有题目（不依赖 notes/folders 数组）
    /// 这是最健壮的加载方式，避免 folders 数组不完整导致路径计算错误
    func loadAllQuestionsFromDisk() -> [Question] {
        var allQuestions: [Question] = []
        let fileManager = FileManager.default
        let rootURL = questionsRootDirectory
        
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            print("📂 loadAllQuestionsFromDisk: 无法创建目录枚举器")
            return []
        }
        
        var fileCount = 0
        var successCount = 0
        var failCount = 0
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            fileCount += 1
            
            do {
                let data = try Data(contentsOf: fileURL)
                let questions = try JSONDecoder().decode([Question].self, from: data)
                allQuestions.append(contentsOf: questions)
                successCount += 1
            } catch {
                failCount += 1
                print("⚠️ loadAllQuestionsFromDisk: 解析失败 \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        print("📚 loadAllQuestionsFromDisk: 遍历 \(fileCount) 个文件，成功 \(successCount) 个，失败 \(failCount) 个，题目总数 \(allQuestions.count)")
        return allQuestions
    }

    /// 构建 noteId → 题目文件所在目录（相对 Questions 根目录）的映射
    /// 不依赖 notes/folders 索引，用于题组列表展示真实路径（笔记索引缺失时也能正确显示）
    func loadQuestionNotePaths() -> [UUID: String] {
        var paths: [UUID: String] = [:]
        let fileManager = FileManager.default
        let rootURL = questionsRootDirectory

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [:]
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let questions = try? JSONDecoder().decode([Question].self, from: data),
                  let first = questions.first else { continue }
            // 相对路径：去掉根目录前缀和文件名，得到目录部分
            var relPath = fileURL.deletingLastPathComponent().path
            if relPath.hasPrefix(rootURL.path) {
                relPath = String(relPath.dropFirst(rootURL.path.count))
            }
            relPath = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            paths[first.noteId] = relPath
        }
        return paths
    }

    /// JSON 索引目录（Documents/.metadata）
    var metadataDirectory: URL {
        let dir = localDocumentsDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 隐藏属性
        var url = dir
        var values = URLResourceValues()
        values.isHidden = true
        try? url.setResourceValues(values)
        return dir
    }

    var foldersIndexFile: URL  { metadataDirectory.appendingPathComponent("folders.json") }
    var notesIndexFile:    URL { metadataDirectory.appendingPathComponent("notes_index.json") }
    var reviewLogsFile:    URL { metadataDirectory.appendingPathComponent("review_logs.json") }

    // MARK: - Markdown 文件 URL 派生（根据文件夹层级 → Notes/<folderPath>/<title>.md）

    func noteFileURL(noteId: UUID, folderId: UUID?, title: String, folders: [Folder]) -> URL {
        var currentURL = notesRootDirectory
        if let folderId = folderId {
            let pathComponents = buildFolderPath(folderId: folderId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        let safeTitle = sanitizeFileName(title)
        let fileName = "\(safeTitle).md"
        return currentURL.appendingPathComponent(fileName)
    }

    /// 讲稿文件 URL（与笔记相同路径和名称，扩展名为 .txt）
    func lectureFileURL(folderId: UUID?, title: String, folders: [Folder]) -> URL {
        var currentURL = lecturesRootDirectory
        if let folderId = folderId {
            let pathComponents = buildFolderPath(folderId: folderId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        let safeTitle = sanitizeFileName(title)
        let fileName = "\(safeTitle).txt"
        return currentURL.appendingPathComponent(fileName)
    }
    
    /// 题库文件 URL（与笔记相同路径和名称，扩展名为 .json）
    func questionFileURL(folderId: UUID?, title: String, folders: [Folder]) -> URL {
        var currentURL = questionsRootDirectory
        if let folderId = folderId {
            let pathComponents = buildFolderPath(folderId: folderId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        let safeTitle = sanitizeFileName(title)
        let fileName = "\(safeTitle).json"
        return currentURL.appendingPathComponent(fileName)
    }

    private func buildFolderPath(folderId: UUID, folders: [Folder]) -> [String] {
        var result: [String] = []
        var currentId: UUID? = folderId
        let folderDict = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        while let cid = currentId, let folder = folderDict[cid] {
            result.append(sanitizeFileName(folder.name))
            currentId = folder.parentId
        }
        return result
    }

    func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var safe = name.components(separatedBy: invalidChars).joined(separator: "_")
        if safe.isEmpty { safe = "Untitled" }
        if safe.count > 80 { safe = String(safe.prefix(80)) }
        return safe
    }

    // MARK: - Markdown IO（直接操作本地 Documents）

    func writeNoteContent(_ content: String, to url: URL, skipCloudSync: Bool = false) throws {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Markdown 内容转 UTF-8 失败"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // 异步同步到云端
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
    
    /// 异步同步文件到云端
    private func syncToCloud(data: Data, to url: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cloudURL = self.cloudURL(forLocalURL: url)
            SyncLogger.shared.stepStart("☁️ 上传笔记: \(url.lastPathComponent)")
            do {
                try self.cloudFS.writeData(data, to: cloudURL)
                SyncLogger.shared.stepDone("☁️ 上传笔记")
            } catch {
                SyncLogger.shared.stepFail("☁️ 上传笔记", error: error)
            }
        }
    }
    
    /// 本地 URL 转换为云端 URL
    private func cloudURL(forLocalURL url: URL) -> URL {
        let localPath = localDocumentsDirectory.path
        let relativePath = url.path.replacingOccurrences(of: localPath, with: "")
        return cloudFS.rootDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - 讲稿 IO（直接操作 Documents/Lecture）

    func lectureExists(folderId: UUID?, title: String, folders: [Folder]) -> Bool {
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func readLecture(folderId: UUID?, title: String, folders: [Folder]) throws -> String {
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        SyncLogger.shared.info("📖 读取讲稿: title=\(title), folderId=\(folderId?.uuidString ?? "nil"), folders=\(folders.count), path=\(url.path)")
        
        let exists = FileManager.default.fileExists(atPath: url.path)
        SyncLogger.shared.info("📖 讲稿文件是否存在: \(exists)")
        
        guard exists else {
            SyncLogger.shared.error("📖 讲稿文件不存在: \(url.path)")
            // 列出上级目录内容，便于排查
            let parentDir = url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path) {
                SyncLogger.shared.info("📖 上级目录内容(\(parentDir.path)): \(contents)")
            } else {
                SyncLogger.shared.error("📖 无法读取上级目录: \(parentDir.path)")
            }
            throw NSError(domain: "FileSystemService", code: -3, userInfo: [NSLocalizedDescriptionKey: "讲稿文件不存在: \(url.lastPathComponent)"])
        }
        
        let data = try Data(contentsOf: url)
        SyncLogger.shared.info("📖 讲稿文件大小: \(data.count) 字节")
        
        guard let str = String(data: data, encoding: .utf8) else {
            SyncLogger.shared.error("📖 讲稿文件不是有效的 UTF-8 编码")
            throw NSError(domain: "FileSystemService", code: -4, userInfo: [NSLocalizedDescriptionKey: "讲稿文件不是有效的 UTF-8 编码"])
        }
        
        SyncLogger.shared.info("📖 讲稿读取成功，内容长度: \(str.count) 字符，前100字: \(String(str.prefix(100)))")
        return str
    }

    func writeLecture(_ content: String, folderId: UUID?, title: String, folders: [Folder], skipCloudSync: Bool = false) throws {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -5, userInfo: [NSLocalizedDescriptionKey: "讲稿内容转 UTF-8 失败"])
        }
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // 异步同步到云端
        if !skipCloudSync {
            syncToCloud(data: data, to: url)
        }
    }

    // MARK: - 题库 IO（直接操作 Documents/Questions）

    func questionExists(folderId: UUID?, title: String, folders: [Folder]) -> Bool {
        let url = questionFileURL(folderId: folderId, title: title, folders: folders)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func readQuestions(folderId: UUID?, title: String, folders: [Folder]) throws -> [Question] {
        let url = questionFileURL(folderId: folderId, title: title, folders: folders)
        let data = try Data(contentsOf: url)
        guard let decoded = try? JSONDecoder().decode([Question].self, from: data) else {
            throw NSError(domain: "FileSystemService", code: -6, userInfo: [NSLocalizedDescriptionKey: "题库文件解析失败"])
        }
        return decoded
    }

    func writeQuestions(_ questions: [Question], folderId: UUID?, title: String, folders: [Folder], skipCloudSync: Bool = false) throws {
        let data = try JSONEncoder().encode(questions)
        let url = questionFileURL(folderId: folderId, title: title, folders: folders)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // 异步同步到云端
        if !skipCloudSync {
            syncToCloud(data: data, to: url)
        }
    }
    
    func deleteQuestions(folderId: UUID?, title: String, folders: [Folder]) {
        let url = questionFileURL(folderId: folderId, title: title, folders: folders)
        try? FileManager.default.removeItem(at: url)
        // 异步删除云端
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cloudURL = self.cloudURL(forLocalURL: url)
            try? self.cloudFS.removeItem(at: cloudURL)
        }
    }

    func deleteNoteFile(at url: URL) throws {
        // 删除本地文件
        try? FileManager.default.removeItem(at: url)
        // 异步删除云端
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cloudURL = self.cloudURL(forLocalURL: url)
            try? self.cloudFS.removeItem(at: cloudURL)
        }
    }

    func createPhysicalFolder(named name: String, parentFolderId: UUID?, folders: [Folder]) throws -> URL {
        var currentURL = notesRootDirectory
        if let parentId = parentFolderId {
            let pathComponents = buildFolderPath(folderId: parentId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        let dirURL = currentURL.appendingPathComponent(sanitizeFileName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // 异步创建云端目录
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cloudURL = self.cloudURL(forLocalURL: dirURL)
            try? self.cloudFS.createDirectoryIfNeeded(at: cloudURL)
        }
        return dirURL
    }

    func deletePhysicalFolder(at url: URL) throws {
        // 删除本地目录
        try? FileManager.default.removeItem(at: url)
        // 异步删除云端目录
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cloudURL = self.cloudURL(forLocalURL: url)
            try? self.cloudFS.removeItem(at: cloudURL)
        }
    }
    
    /// 移动/重命名物理文件夹（本地 + 云端）
    /// 注意：CloudFileSystem 协议没有 moveItem 方法，这里只确保目标目录存在，
    /// 实际的文件移动通过后续的全量同步完成
    func movePhysicalFolder(from sourceURL: URL, to destinationURL: URL) throws {
        // 确保目标目录存在
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        // 本地移动
        try? FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        // 云端移动通过全量同步处理
    }

    // MARK: - JSON 索引读写（转发到 cloudFS；失败打印警告）

    func loadFolders() -> [Folder] {
        loadJSON(from: foldersIndexFile, defaultValue: [])
    }

    func saveFolders(_ folders: [Folder]) {
        saveJSON(folders, to: foldersIndexFile)
    }

    func loadNoteIndex() -> [NoteMeta] {
        loadJSON(from: notesIndexFile, defaultValue: [])
    }

    func saveNoteIndex(_ meta: [NoteMeta]) {
        saveJSON(meta, to: notesIndexFile)
    }

    func loadReviewLogs() -> [ReviewLog] {
        loadJSON(from: reviewLogsFile, defaultValue: [])
    }

    func saveReviewLogs(_ logs: [ReviewLog]) {
        saveJSON(logs, to: reviewLogsFile)
    }

    // MARK: - 通用 JSON 工具

    private func loadJSON<T: Decodable>(from url: URL, defaultValue: T) -> T {
        // 直接从本地 Documents/.metadata 读取
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return defaultValue
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("⚠️ JSON 解码失败 \(url.lastPathComponent): \(error)")
            return defaultValue
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // 异步同步到云端
            syncToCloud(data: data, to: url)
        } catch {
            print("⚠️ JSON 写入失败 \(url.lastPathComponent): \(error)")
        }
    }
}
