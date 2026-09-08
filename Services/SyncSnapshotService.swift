//
//  SyncSnapshotService.swift
//  AnkiNotes
//
//  同步快照服务：记录云端文件/目录的最后修改时间，用于增量同步
//  实现三级跳过策略：根目录级、子目录级、文件级
//

import Foundation

/// 同步快照数据结构
struct SyncSnapshot: Codable {
    var lastSyncTime: Date
    var rootDirectory: String
    var directories: [String: Date]  // 目录相对路径 -> 最后修改时间
    var files: [String: Date]          // 文件相对路径 -> 最后修改时间
    
    init(rootDirectory: String) {
        self.lastSyncTime = Date()
        self.rootDirectory = rootDirectory
        self.directories = [:]
        self.files = [:]
    }
}

/// 同步快照服务
final class SyncSnapshotService {
    private let fileSystem: FileSystemService
    private var snapshot: SyncSnapshot?
    private let snapshotFileName = "sync_snapshot.json"
    
    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
    }
    
    // MARK: - 快照加载与保存
    
    /// 从本地加载快照
    func load() {
        let url = fileSystem.metadataDirectory.appendingPathComponent(snapshotFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("📸 同步快照不存在，将执行全量同步")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
            print("📸 同步快照加载成功：\(snapshot?.directories.count ?? 0) 个目录，\(snapshot?.files.count ?? 0) 个文件")
        } catch {
            print("⚠️ 同步快照加载失败：\(error.localizedDescription)，将执行全量同步")
            snapshot = nil
        }
    }
    
    /// 保存快照到本地
    func save() {
        guard var snapshot = snapshot else { return }
        snapshot.lastSyncTime = Date()
        let url = fileSystem.metadataDirectory.appendingPathComponent(snapshotFileName)
        do {
            try FileManager.default.createDirectory(at: fileSystem.metadataDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            self.snapshot = snapshot
            print("📸 同步快照保存成功：\(snapshot.directories.count) 个目录，\(snapshot.files.count) 个文件")
        } catch {
            print("⚠️ 同步快照保存失败：\(error.localizedDescription)")
        }
    }
    
    /// 重置快照（首次同步或快照损坏时调用）
    func reset(rootDirectory: String) {
        snapshot = SyncSnapshot(rootDirectory: rootDirectory)
        print("📸 同步快照已重置")
    }
    
    /// 检查快照是否存在
    var hasSnapshot: Bool {
        snapshot != nil
    }
    
    // MARK: - 目录修改时间检查
    
    /// 检查目录是否有更新（第2级：子目录级跳过）
    /// - Parameters:
    ///   - relativePath: 目录相对路径（如 "Notes/JAVA高级/01-Java核心"）
    ///   - lastModified: 云端目录的最后修改时间
    /// - Returns: true=有更新，需要扫描；false=无更新，跳过
    func isDirectoryUpdated(relativePath: String, lastModified: Date?) -> Bool {
        guard let snapshot = snapshot, let cloudModified = lastModified else {
            return true  // 无快照或无修改时间，保守处理为有更新
        }
        guard let localModified = snapshot.directories[relativePath] else {
            return true  // 本地无记录，是新增目录
        }
        // 比较修改时间，容忍1秒误差（某些服务器只精确到秒）
        let timeDiff = abs(cloudModified.timeIntervalSince(localModified))
        return timeDiff > 1.0
    }
    
    /// 检查根目录是否有更新（第1级：根目录级跳过）
    func isRootDirectoryUpdated(lastModified: Date?) -> Bool {
        guard let snapshot = snapshot else { return true }
        return isDirectoryUpdated(relativePath: "", lastModified: lastModified)
    }
    
    // MARK: - 文件修改时间检查
    
    /// 检查文件是否有更新（第3级：文件级跳过）
    /// - Parameters:
    ///   - relativePath: 文件相对路径（如 "Notes/JAVA高级/01-Java核心/IO与NIO.md"）
    ///   - lastModified: 云端文件的最后修改时间
    /// - Returns: true=有更新，需要读取；false=无更新，跳过
    func isFileUpdated(relativePath: String, lastModified: Date?) -> Bool {
        guard let snapshot = snapshot, let cloudModified = lastModified else {
            return true  // 无快照或无修改时间，保守处理为有更新
        }
        guard let localModified = snapshot.files[relativePath] else {
            return true  // 本地无记录，是新增文件
        }
        // 比较修改时间，容忍1秒误差
        let timeDiff = abs(cloudModified.timeIntervalSince(localModified))
        return timeDiff > 1.0
    }
    
    // MARK: - 快照更新
    
    /// 更新目录的修改时间
    func updateDirectory(relativePath: String, lastModified: Date?) {
        guard snapshot != nil, let modified = lastModified else { return }
        snapshot?.directories[relativePath] = modified
    }
    
    /// 更新文件的修改时间
    func updateFile(relativePath: String, lastModified: Date?) {
        guard snapshot != nil, let modified = lastModified else { return }
        snapshot?.files[relativePath] = modified
    }
    
    /// 删除目录记录
    func removeDirectory(relativePath: String) {
        snapshot?.directories.removeValue(forKey: relativePath)
    }
    
    /// 删除文件记录
    func removeFile(relativePath: String) {
        snapshot?.files.removeValue(forKey: relativePath)
    }
    
    // MARK: - 路径工具
    
    /// 计算相对路径（去掉根目录前缀）
    func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        var relative = String(fullPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        return relative
    }
}
