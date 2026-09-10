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
    
    /// 快照读写锁：snapshot 可能被主线程（UI 触发）与后台同步队列并发访问，
    /// 必须加锁保护，防止数据竞争导致崩溃或快照损坏
    private let lock = NSLock()
    
    /// 防抖落盘：修改快照后延迟 1 秒合并写盘，避免同步期间逐文件频繁写盘
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.ankinotes.snapshot.save")
    
    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
    }
    
    // MARK: - 快照加载与保存
    
    /// 从本地加载快照
    func load() {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        ensureSnapshot()
        guard var snapshot = snapshot else { return }
        snapshot.lastSyncTime = Date()
        let url = fileSystem.metadataDirectory.appendingPathComponent(snapshotFileName)
        do {
            try FileManager.default.createDirectory(at: fileSystem.metadataDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            self.snapshot = snapshot
            print("📸 同步快照保存成功：\(snapshot.directories.count) 个目录，\(snapshot.files.count) 个文件，路径：\(url.path)")
        } catch {
            print("⚠️ 同步快照保存失败：\(error.localizedDescription)")
        }
    }
    
    /// 立即落盘（供完整同步结束等关键节点调用，确保快照及时持久化，避免 App 被杀丢失）
    func flush() {
        saveQueue.sync { [weak self] in
            self?.save()
        }
    }
    
    /// 重置快照（首次同步或快照损坏时调用）
    func reset(rootDirectory: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshot = SyncSnapshot(rootDirectory: rootDirectory)
        print("📸 同步快照已重置")
        scheduleSave()
    }
    
    /// 检查快照是否存在
    var hasSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot != nil
    }
    
    // MARK: - 目录修改时间检查
    
    /// 检查目录是否有更新（第2级：子目录级跳过）
    func isDirectoryUpdated(relativePath: String, lastModified: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDirectoryUpdatedUnlocked(relativePath: relativePath, lastModified: lastModified)
    }
    
    /// 检查根目录是否有更新（第1级：根目录级跳过）
    func isRootDirectoryUpdated(lastModified: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshot else { return true }
        return isDirectoryUpdatedUnlocked(relativePath: "", lastModified: lastModified)
    }
    
    /// 目录更新判断（不持有锁的私有实现，调用方必须已持有锁）
    private func isDirectoryUpdatedUnlocked(relativePath: String, lastModified: Date?) -> Bool {
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
    
    // MARK: - 文件修改时间检查
    
    /// 检查文件是否有更新（第3级：文件级跳过）
    func isFileUpdated(relativePath: String, lastModified: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
    
    /// 确保快照存在（如果不存在则自动创建），必须在持有锁时调用
    private func ensureSnapshot() {
        if snapshot == nil {
            snapshot = SyncSnapshot(rootDirectory: "default")
            print("📸 自动创建同步快照")
        }
    }
    
    /// 更新目录的修改时间（修改后自动防抖落盘）
    func updateDirectory(relativePath: String, lastModified: Date?) {
        lock.lock()
        defer { lock.unlock() }
        guard let modified = lastModified else { return }
        ensureSnapshot()  // 确保快照存在
        snapshot?.directories[relativePath] = modified
        scheduleSave()
    }
    
    /// 更新文件的修改时间（修改后自动防抖落盘）
    func updateFile(relativePath: String, lastModified: Date?) {
        lock.lock()
        defer { lock.unlock() }
        guard let modified = lastModified else { return }
        ensureSnapshot()  // 确保快照存在
        snapshot?.files[relativePath] = modified
        scheduleSave()
    }
    
    /// 删除目录记录（修改后自动防抖落盘）
    func removeDirectory(relativePath: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshot?.directories.removeValue(forKey: relativePath)
        scheduleSave()
    }
    
    /// 删除文件记录（修改后自动防抖落盘）
    func removeFile(relativePath: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshot?.files.removeValue(forKey: relativePath)
        scheduleSave()
    }
    
    // MARK: - 防抖落盘（内部，调用方需持有锁）
    
    /// 防抖落盘：1 秒内多次更新合并为一次写盘，避免同步期间逐文件频繁写盘
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
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
