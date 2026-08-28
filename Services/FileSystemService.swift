//
//  FileSystemService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 文件系统服务 - 处理实际的 Markdown 文件读写、文件夹创建
final class FileSystemService {
    
    // MARK: - 路径
    
    /// App 沙盒 Documents 目录作为根目录
    var rootDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    /// 笔记存放的根目录
    var notesRootDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 元数据（索引）存放目录
    var metadataDirectory: URL {
        var dir = rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 隐藏目录，在文件App中不显示
        var values = URLResourceValues()
        values.isHidden = true
        try? dir.setResourceValues(values)
        return dir
    }
    
    /// 文件夹索引文件路径
    var foldersIndexFile: URL {
        return metadataDirectory.appendingPathComponent("folders.json")
    }
    
    /// 笔记元数据索引文件路径（SRS数据 + 标题映射 + folderId）
    var notesIndexFile: URL {
        return metadataDirectory.appendingPathComponent("notes_index.json")
    }
    
    /// 复习日志索引文件路径
    var reviewLogsFile: URL {
        return metadataDirectory.appendingPathComponent("review_logs.json")
    }
    
    // MARK: - Markdown 文件操作
    
    /// 根据文件夹层级生成一个笔记的完整文件 URL
    func noteFileURL(noteId: UUID, folderId: UUID?, title: String, folders: [Folder]) -> URL {
        var currentURL = notesRootDirectory
        
        // 递归向上构建文件夹路径
        if let folderId = folderId {
            let pathComponents = buildFolderPath(folderId: folderId, folders: folders)
            for folderName in pathComponents.reversed() {
                currentURL = currentURL.appendingPathComponent(folderName, isDirectory: true)
            }
        }
        
        try? FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        // 文件名：id_title.md
        let safeTitle = sanitizeFileName(title)
        let fileName = "\(noteId.uuidString)_\(safeTitle).md"
        return currentURL.appendingPathComponent(fileName)
    }
    
    /// 根据 folderId 递归获取从根到父文件夹的名称数组（倒序，从当前文件夹往上）
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
    
    /// 文件名安全处理（去除非法字符，限制长度）
    func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var safe = name.components(separatedBy: invalidChars).joined(separator: "_")
        if safe.isEmpty { safe = "Untitled" }
        if safe.count > 80 { safe = String(safe.prefix(80)) }
        return safe
    }
    
    /// 写入 Markdown 内容到文件
    func writeNoteContent(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    /// 读取 Markdown 文件内容
    func readNoteContent(from url: URL) throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    /// 删除 Markdown 文件
    func deleteNoteFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    /// 创建文件夹（在 Notes 目录下）
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
        return dirURL
    }
    
    /// 删除物理文件夹（连同内部的 md 文件）
    func deletePhysicalFolder(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - JSON 索引读写
    
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
            try data.write(to: url, options: .atomic)
        } catch {
            print("⚠️ JSON 写入失败 \(url.lastPathComponent): \(error)")
        }
    }
}

/// NoteMeta: Note 的轻量索引记录，对应 JSON 索引文件
struct NoteMeta: Codable, Hashable {
    let id: UUID
    var title: String
    var folderId: UUID?
    var fileName: String      // 实际文件名（含 id_ 前缀）
    var srs: SRSData
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
}
