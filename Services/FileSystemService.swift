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

    // MARK: - Markdown 文件 URL 派生（根据文件夹层级 → Notes/<folderPath>/<id>_<title>.md）

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
        let fileName = "\(noteId.uuidString)_\(safeTitle).md"
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
    func movePhysicalFolder(from sourceURL: URL, to destinationURL: URL) throws {
        // 确保目标目录的父目录存在
        try cloudFS.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())
        // 如果目标已存在，先删除
        try? cloudFS.removeItem(at: destinationURL)
        // 移动文件夹
        try cloudFS.moveItem(at: sourceURL, to: destinationURL)
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
        guard cloudFS.fileExists(at: url),
              let data = try? cloudFS.readData(at: url) else {
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
            try cloudFS.writeData(data, to: url)
        } catch {
            print("⚠️ JSON 写入失败 \(url.lastPathComponent): \(error)")
        }
    }
}
