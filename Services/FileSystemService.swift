//
//  FileSystemService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 存储位置：本地 Documents / iCloud Drive
enum StorageMode: String, Codable, CaseIterable, Identifiable {
    case local      // 本机 Documents（免费侧载默认、离线模式）
    case iCloud     // iCloud Drive ▸ AnkiNotes（需付费 Dev 账号配置 iCloud Container）
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local:  return "📁 本机存储"
        case .iCloud: return "☁️ iCloud 同步"
        }
    }
}

/// 文件系统服务 - 处理实际的 Markdown 文件读写、文件夹创建
/// 支持「本地 Documents」与「iCloud Drive ▸ AnkiNotes」两种根目录模式切换
final class FileSystemService {

    // MARK: - 存储模式（持久化 + 切换时回调）

    /// 当前存储模式（持久化到 UserDefaults，下次启动自动恢复）
    private(set) var storageMode: StorageMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.storageModeKey) ?? StorageMode.local.rawValue
            return StorageMode(rawValue: raw) ?? .local
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.storageModeKey)
        }
    }
    private static let storageModeKey = "AnkiNotes.StorageMode"

    // MARK: - 路径

    /// **真实根目录**（根据 storageMode + iCloud 是否可用动态决定）
    /// - 如果是 iCloud 模式但 iCloud 容器不可用（未买 Dev、未登录 Apple ID、entitlements 未生效）
    ///   → 自动 fallback 到本地（保证数据不丢）
    var rootDirectory: URL {
        switch storageMode {
        case .local:
            return Self.localDocumentsDirectory
        case .iCloud:
            if let iCloudRoot = ubiquityContainerDocumentsDirectory {
                return iCloudRoot
            }
            // iCloud 不可用时自动回退本地
            return Self.localDocumentsDirectory
        }
    }

    /// 笔记物理存放目录（root/Notes）
    var notesRootDirectory: URL {
        let dir = rootDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 元数据索引目录（root/.metadata，隐藏）
    var metadataDirectory: URL {
        var dir = rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isHidden = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// 文件夹索引文件
    var foldersIndexFile: URL { metadataDirectory.appendingPathComponent("folders.json") }
    /// 笔记索引文件（SRS数据 + 标题 + folderId 映射）
    var notesIndexFile:   URL { metadataDirectory.appendingPathComponent("notes_index.json") }
    /// 复习日志索引文件
    var reviewLogsFile:   URL { metadataDirectory.appendingPathComponent("review_logs.json") }

    // MARK: - iCloud 可用性 / 真实路径

    /// 付费 Dev + entitlements + 登录 iCloud 三者皆满足时返回 true（可真实生效）
    var iCloudContainerAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    /// iCloud「文件 App」中实际显示的路径字符串（用于 UI 提示）
    /// Apple 的 iCloud Drive 实际容器名是 NSUbiquitousContainerName，一般在文件 App 显示为「AnkiNotes」
    var iCloudDisplayPath: String? {
        guard storageMode == .iCloud || iCloudContainerAvailable else { return nil }
        return "iCloud Drive ▸ AnkiNotes ▸ Notes  /  .metadata"
    }

    // MARK: - 存储模式切换 + 数据迁移

    /// 切换存储模式（默认迁移现有数据）。
    /// - migrate:  true  → 把旧目录 Notes/.metadata 复制到新目录（冲突自动备份旧版避免覆盖）
    ///             false → 直接切到新目录（常用于重置 / 强制切换）
    func setStorageMode(_ newMode: StorageMode, migrate: Bool = true) throws {
        let oldMode = storageMode
        guard newMode != oldMode else { return }

        if newMode == .iCloud && !iCloudContainerAvailable {
            throw FileSystemError.iCloudNotAvailable
        }

        if migrate {
            try migrateData(from: rootDirectory(of: oldMode), to: rootDirectory(of: newMode))
        }

        storageMode = newMode
    }

    // MARK: - Markdown 文件操作

    /// 根据文件夹层级生成一个笔记的完整文件 URL
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

    /// 创建物理文件夹（在 Notes 目录下）
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

    func loadFolders() -> [Folder] { loadJSON(from: foldersIndexFile, defaultValue: []) }
    func saveFolders(_ folders: [Folder]) { saveJSON(folders, to: foldersIndexFile) }
    func loadNoteIndex() -> [NoteMeta] { loadJSON(from: notesIndexFile, defaultValue: []) }
    func saveNoteIndex(_ meta: [NoteMeta]) { saveJSON(meta, to: notesIndexFile) }
    func loadReviewLogs() -> [ReviewLog] { loadJSON(from: reviewLogsFile, defaultValue: []) }
    func saveReviewLogs(_ logs: [ReviewLog]) { saveJSON(logs, to: reviewLogsFile) }

    // MARK: - 错误类型

    enum FileSystemError: LocalizedError {
        case iCloudNotAvailable
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .iCloudNotAvailable:
                return "iCloud 不可用，请先在系统登录 Apple ID 并确认已在 Apple Developer Portal 为该 App 配置 iCloud Container（需付费 Developer 账号）。"
            case .migrationFailed(let detail):
                return "数据迁移失败：\(detail)"
            }
        }
    }

    // MARK: - 内部工具

    private static var localDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// iCloud 容器的 Documents/AnkiNotes 路径（不可用时返回 nil）
    private var ubiquityContainerDocumentsDirectory: URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let dir = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("AnkiNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 获取指定存储模式的根目录（不触发 fallback，纯用于迁移时拿到旧模式真实路径）
    private func rootDirectory(of mode: StorageMode) -> URL {
        switch mode {
        case .local: return Self.localDocumentsDirectory
        case .iCloud:
            if let d = ubiquityContainerDocumentsDirectory { return d }
            // 如果是新切 iCloud 模式但是还没迁移时就不可用，就用本地（不会发生）
            return Self.localDocumentsDirectory
        }
    }

    /// 迁移 Notes/ + .metadata/ 两个目录到新位置；
    /// 冲突策略：目标若已存在该目录 → 先把目标目录备份为 xxx_backup_时间戳，再复制源目录过去（防止互相覆盖丢数据）
    private func migrateData(from oldRoot: URL, to newRoot: URL) throws {
        guard oldRoot != newRoot else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let dirs = ["Notes", ".metadata"]
        let ts = Int(Date().timeIntervalSince1970)
        for dir in dirs {
            let src = oldRoot.appendingPathComponent(dir, isDirectory: true)
            let dst = newRoot.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) {
                let backup = newRoot.appendingPathComponent("\(dir)_backup_\(ts)", isDirectory: true)
                try fm.moveItem(at: dst, to: backup)
            }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                throw FileSystemError.migrationFailed("复制 \(dir) 失败：\(error.localizedDescription)")
            }
        }
    }

    private func loadJSON<T: Decodable>(from url: URL, defaultValue: T) -> T {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return defaultValue }
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
