//
//  FileSystemService.swift
//  AnkiNotes
//
//  重构版：通过 CloudFileSystem 协议调度（📁本地 / ☁️iCloud / 🥇WebDAV）
//  上层业务代码完全不感知底层 Provider 差异。
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 文件系统服务（StorageService 用它做文件/目录的 URL 派生 & 实际 IO 转发）
final class FileSystemService {

    // MARK: - 后端 Provider（由 AppState 在 bootstrap/applyProvider 时注入）

    let cloudFS: CloudFileSystem

    /// 本地元数据缓存目录（Library/Caches/Metadata）
    private var localCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func localCacheURL(for url: URL) -> URL {
        localCacheDirectory.appendingPathComponent(url.lastPathComponent)
    }
    
    init(cloudFS: CloudFileSystem) {
        self.cloudFS = cloudFS
    }

    // MARK: - 路径（URL 语义保持不变：root/Notes 和 root/.metadata）

    /// 根目录：本地 = Documents；iCloud = Container/Documents/AnkiNotes；WebDAV = 服务器+根路径
    var rootDirectory: URL { cloudFS.rootDirectory }

    /// Markdown 物理文件总目录（root/Notes）
    var notesRootDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: dir)
        return dir
    }

    /// 课堂讲稿总目录（root/Lecture）
    var lecturesRootDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("Lecture", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: dir)
        return dir
    }

    /// JSON 索引目录（root/.metadata，iCloud 下也会被自动同步，因为不是点开头会上传；
    /// 但我们在设置 URLResourceValues 隐藏仅是为了文件 App 不显示它）
    var metadataDirectory: URL {
        var dir = rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: dir)
        // 仅本地沙盒 / iCloud（URL 对象是 file://）时尝试隐藏属性
        if dir.isFileURL {
            var values = URLResourceValues()
            values.isHidden = true
            try? dir.setResourceValues(values)
        }
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
        try? cloudFS.createDirectoryIfNeeded(at: currentURL)
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
        try? cloudFS.createDirectoryIfNeeded(at: currentURL)
        let safeTitle = sanitizeFileName(title)
        let fileName = "\(safeTitle).txt"
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

    // MARK: - Markdown IO（转发到 cloudFS）

    func writeNoteContent(_ content: String, to url: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Markdown 内容转 UTF-8 失败"])
        }
        try cloudFS.writeData(data, to: url)
    }

    func readNoteContent(from url: URL) throws -> String {
        let data = try cloudFS.readData(at: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Markdown 文件不是有效的 UTF-8 编码"])
        }
        return str
    }

    // MARK: - 讲稿本地缓存目录
    
    /// 讲稿本地缓存目录（Library/Caches/Lectures）
    private var lectureCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Lectures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func lectureCacheURL(folderId: UUID?, title: String, folders: [Folder]) -> URL {
        var currentURL = lectureCacheDirectory
        if let folderId = folderId {
            let pathComponents = buildFolderPath(folderId: folderId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        let safeTitle = sanitizeFileName(title)
        return currentURL.appendingPathComponent("\(safeTitle).txt")
    }

    // MARK: - 讲稿 IO（带本地缓存）

    func lectureExists(folderId: UUID?, title: String, folders: [Folder]) -> Bool {
        let cacheURL = lectureCacheURL(folderId: folderId, title: title, folders: folders)
        // 优先检查本地缓存
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return true
        }
        // 缓存不存在，检查云端
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        return cloudFS.fileExists(at: url)
    }

    func readLecture(folderId: UUID?, title: String, folders: [Folder]) throws -> String {
        let cacheURL = lectureCacheURL(folderId: folderId, title: title, folders: folders)
        // 优先从本地缓存读取
        if let cacheData = try? Data(contentsOf: cacheURL),
           let str = String(data: cacheData, encoding: .utf8) {
            return str
        }
        // 缓存不存在，从云端读取并写入缓存
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        let data = try cloudFS.readData(at: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -4, userInfo: [NSLocalizedDescriptionKey: "讲稿文件不是有效的 UTF-8 编码"])
        }
        // 写入本地缓存
        try? data.write(to: cacheURL, options: .atomic)
        return str
    }

    func writeLecture(_ content: String, folderId: UUID?, title: String, folders: [Folder]) throws {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileSystemService", code: -5, userInfo: [NSLocalizedDescriptionKey: "讲稿内容转 UTF-8 失败"])
        }
        // 1. 先写本地缓存
        let cacheURL = lectureCacheURL(folderId: folderId, title: title, folders: folders)
        try data.write(to: cacheURL, options: .atomic)
        // 2. 异步写云端
        let url = lectureFileURL(folderId: folderId, title: title, folders: folders)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.cloudFS.writeData(data, to: url)
            } catch {
                print("⚠️ 讲稿云端写入失败: \(error.localizedDescription)")
            }
        }
    }

    func deleteNoteFile(at url: URL) throws {
        try cloudFS.removeItem(at: url)
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
        try cloudFS.createDirectoryIfNeeded(at: dirURL)
        return dirURL
    }

    func deletePhysicalFolder(at url: URL) throws {
        try cloudFS.removeItem(at: url)
    }
    
    /// 移动/重命名物理文件夹（本地 + 云端）
    /// 注意：CloudFileSystem 协议没有 moveItem 方法，这里只确保目标目录存在，
    /// 实际的文件移动通过后续的全量同步完成
    func movePhysicalFolder(from sourceURL: URL, to destinationURL: URL) throws {
        // 确保目标目录存在
        try cloudFS.createDirectoryIfNeeded(at: destinationURL)
        // 本地文件系统可以直接移动
        // 云端文件移动通过全量同步处理
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
        // 优先从本地缓存读取
        let cacheURL = localCacheURL(for: url)
        if let cacheData = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(T.self, from: cacheData) {
            return decoded
        }
        // 缓存不存在，从云端读取并写入缓存
        guard cloudFS.fileExists(at: url),
              let data = try? cloudFS.readData(at: url) else {
            return defaultValue
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            // 写入本地缓存
            try? data.write(to: cacheURL, options: .atomic)
            return decoded
        } catch {
            print("⚠️ JSON 解码失败 \(url.lastPathComponent): \(error)")
            return defaultValue
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            // 1. 先写本地缓存（保证快速读取）
            let cacheURL = localCacheURL(for: url)
            try data.write(to: cacheURL, options: .atomic)
            // 2. 异步写云端（不阻塞主线程）
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                do {
                    try self.cloudFS.writeData(data, to: url)
                } catch {
                    print("⚠️ JSON 云端写入失败 \(url.lastPathComponent): \(error)")
                }
            }
        } catch {
            print("⚠️ JSON 缓存写入失败 \(url.lastPathComponent): \(error)")
        }
    }
}
