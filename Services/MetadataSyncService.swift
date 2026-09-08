//
//  MetadataSyncService.swift
//  AnkiNotes
//
//  .metadata 元数据云端同步服务
//

import Foundation

/// 元数据同步服务
/// 负责 .metadata 目录下所有 JSON 索引文件的云端同步
final class MetadataSyncService {
    static let shared = MetadataSyncService()
    
    private let fileManager = FileManager.default
    private var lastPushTimestamps: [String: Date] = [:]
    private var pushWorkItem: DispatchWorkItem?
    private let pushQueue = DispatchQueue(label: "com.ankinotes.metadata.push", qos: .utility)
    
    /// 需要同步的元数据文件名
    /// 注意：quiz_questions.json 已废弃，题库现在按笔记文件夹结构存储在 Questions/ 目录
    private let metadataFiles: [String] = [
        "folders.json",
        "notes_index.json",
        "review_logs.json",
        "quiz_generated_notes.json"
    ]
    
    private init() {}
    
    // MARK: - 本地元数据目录
    
    /// 本地元数据目录（Documents/.metadata）
    private var localCacheDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".metadata", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func localCacheURL(for fileName: String) -> URL {
        localCacheDirectory.appendingPathComponent(fileName)
    }
    
    // MARK: - 智能合并：基于时间戳合并 SRS 数据，避免多端覆盖
    
    /// 合并本地和云端的 noteMetas，基于 updatedAt 保留较新的数据
    /// 解决多端同时复习时 SRS 数据被覆盖的问题
    /// - Parameters:
    ///   - local: 本地 noteMetas（包含未同步的复习记录）
    ///   - cloud: 云端 noteMetas
    /// - Returns: 合并后的 noteMetas
    func mergeNoteMetas(local: [NoteMeta], cloud: [NoteMeta]) -> [NoteMeta] {
        var merged: [UUID: NoteMeta] = [:]
        
        // 先加入云端数据
        for noteMeta in cloud {
            merged[noteMeta.id] = noteMeta
        }
        
        // 再加入本地数据，比较 updatedAt 保留较新的
        for localNote in local {
            if let cloudNote = merged[localNote.id] {
                // 两端都有，比较 updatedAt，保留较新的
                if localNote.updatedAt >= cloudNote.updatedAt {
                    merged[localNote.id] = localNote
                }
                // 否则保留云端的
            } else {
                // 只有本地有，保留本地
                merged[localNote.id] = localNote
            }
        }
        
        let result = Array(merged.values)
        let cloudIds = Set(cloud.map { $0.id })
        let localIds = Set(local.map { $0.id })
        let localOnly = local.filter { !cloudIds.contains($0.id) }.count
        let cloudOnly = cloud.filter { !localIds.contains($0.id) }.count
        let both = local.filter { cloudIds.contains($0.id) }.count
        print("🔄 SRS数据合并: 本地\(local.count)篇 + 云端\(cloud.count)篇 → 合并\(result.count)篇 (仅本地\(localOnly), 仅云端\(cloudOnly), 两端都有\(both))")
        return result
    }
    
    /// 从本地缓存读取 noteMetas
    func readLocalNoteMetas() -> [NoteMeta] {
        let localURL = localCacheURL(for: "notes_index.json")
        guard let data = try? Data(contentsOf: localURL),
              let decoded = try? JSONDecoder().decode([NoteMeta].self, from: data) else {
            return []
        }
        return decoded
    }
    
    /// 写入 noteMetas 到本地缓存
    func writeLocalNoteMetas(_ noteMetas: [NoteMeta]) {
        let localURL = localCacheURL(for: "notes_index.json")
        if let data = try? JSONEncoder().encode(noteMetas) {
            try? data.write(to: localURL, options: .atomic)
        }
    }
    
    // MARK: - Pull：从云端拉取元数据到本地缓存
    
    /// 从云端拉取所有元数据文件到本地缓存
    /// - Parameter cloudFS: 云端文件系统
    /// - Returns: 成功拉取的文件数
    @discardableResult
    func pullFromCloud(cloudFS: CloudFileSystem) -> Int {
        let metadataDir = cloudFS.rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        var pulledCount = 0
        
        for fileName in metadataFiles {
            let cloudURL = metadataDir.appendingPathComponent(fileName)
            let localURL = localCacheURL(for: fileName)
            
            do {
                // 检查云端文件是否存在
                guard cloudFS.fileExists(at: cloudURL) else { continue }
                
                // 读取云端数据
                let cloudData = try cloudFS.readData(at: cloudURL)
                
                // 比较本地缓存修改时间（如果存在）
                if let localData = try? Data(contentsOf: localURL),
                   localData == cloudData {
                    // 内容相同，跳过
                    continue
                }
                
                // 写入本地缓存
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                print("📥 元数据同步: 拉取 \(fileName) (\(cloudData.count) bytes)")
                
            } catch {
                print("⚠️ 元数据拉取失败 \(fileName): \(error.localizedDescription)")
            }
        }
        
        return pulledCount
    }
    
    // MARK: - Push：将本地缓存推送到云端
    
    /// 将本地缓存的元数据文件推送到云端
    /// - Parameter cloudFS: 云端文件系统
    /// - Returns: 成功推送的文件数
    @discardableResult
    func pushToCloud(cloudFS: CloudFileSystem) -> Int {
        let metadataDir = cloudFS.rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: metadataDir)
        
        var pushedCount = 0
        
        for fileName in metadataFiles {
            let localURL = localCacheURL(for: fileName)
            let cloudURL = metadataDir.appendingPathComponent(fileName)
            
            do {
                // 检查本地缓存是否存在
                guard fileManager.fileExists(atPath: localURL.path) else { continue }
                
                // 读取本地数据
                let localData = try Data(contentsOf: localURL)
                
                // 比较云端内容（如果存在）
                if let cloudData = try? cloudFS.readData(at: cloudURL),
                   cloudData == localData {
                    // 内容相同，跳过
                    continue
                }
                
                // 写入云端
                try cloudFS.writeData(localData, to: cloudURL)
                pushedCount += 1
                lastPushTimestamps[fileName] = Date()
                print("📤 元数据同步: 推送 \(fileName) (\(localData.count) bytes)")
                
            } catch {
                print("⚠️ 元数据推送失败 \(fileName): \(error.localizedDescription)")
            }
        }
        
        return pushedCount
    }
    
    // MARK: - 本地缓存读写（供 StorageService/QuizService 使用）
    
    /// 从本地缓存读取元数据
    func readFromCache<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        let localURL = localCacheURL(for: fileName)
        guard let data = try? Data(contentsOf: localURL),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return nil
        }
        return decoded
    }
    
    /// 写入元数据到本地缓存
    func writeToCache<T: Encodable>(_ value: T, fileName: String) {
        let localURL = localCacheURL(for: fileName)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: localURL, options: .atomic)
        } catch {
            print("⚠️ 元数据缓存写入失败 \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 检查本地缓存是否存在
    func cacheExists(fileName: String) -> Bool {
        fileManager.fileExists(atPath: localCacheURL(for: fileName).path)
    }
    
    // MARK: - Debounced Push（防抖推送）
    
    /// 标记元数据已变更，延迟推送（debounce 5秒）
    func markDirty() {
        pushWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            // 实际推送由 AppState 触发（需要 cloudFS）
            NotificationCenter.default.post(name: .metadataSyncNeeded, object: nil)
        }
        pushWorkItem = workItem
        pushQueue.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
    
    /// 立即执行待推送的任务（App 进入后台时调用）
    func flush() {
        pushWorkItem?.cancel()
        pushWorkItem = nil
        NotificationCenter.default.post(name: .metadataSyncNeeded, object: nil)
    }
    
    // MARK: - 知识点缓存同步（.knowledge_cache）
    
    /// 本地知识点缓存目录（Documents/.knowledge_cache）
    private var localKnowledgeCacheDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".knowledge_cache", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 从云端拉取知识点缓存到本地
    func pullKnowledgeCache(cloudFS: CloudFileSystem) -> Int {
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        var pulledCount = 0
        
        // 只扫描一层目录（知识点缓存文件直接存储在 .knowledge_cache 目录下）
        let cloudFiles = listFilesFlat(cloudFS: cloudFS, at: cloudDir)
        for cloudURL in cloudFiles {
            do {
                // 文件名就是相对路径（只有一层）
                let fileName = cloudURL.lastPathComponent
                let localURL = localKnowledgeCacheDir.appendingPathComponent(fileName)
                
                guard cloudFS.fileExists(at: cloudURL) else { continue }
                let cloudData = try cloudFS.readData(at: cloudURL)
                
                // 比较本地缓存
                if let localData = try? Data(contentsOf: localURL),
                   localData == cloudData {
                    continue
                }
                
                // 写入本地
                try? fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                print("📥 知识点缓存同步: 拉取 \(fileName)")
            } catch {
                print("⚠️ 知识点缓存拉取失败 \(cloudURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return pulledCount
    }
    
    /// 将本地知识点缓存推送到云端
    func pushKnowledgeCache(cloudFS: CloudFileSystem) -> Int {
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: cloudDir)
        var pushedCount = 0
        
        // 只扫描一层目录（知识点缓存文件直接存储在 .knowledge_cache 目录下）
        let localFiles = listLocalFilesFlat(at: localKnowledgeCacheDir)
        for localURL in localFiles {
            do {
                // 文件名就是相对路径（只有一层）
                let fileName = localURL.lastPathComponent
                let cloudURL = cloudDir.appendingPathComponent(fileName)
                
                guard fileManager.fileExists(atPath: localURL.path) else { continue }
                let localData = try Data(contentsOf: localURL)
                
                // 比较云端
                if let cloudData = try? cloudFS.readData(at: cloudURL),
                   cloudData == localData {
                    continue
                }
                
                // 写入云端
                try? cloudFS.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
                try cloudFS.writeData(localData, to: cloudURL)
                pushedCount += 1
                print("📤 知识点缓存同步: 推送 \(fileName)")
            } catch {
                print("⚠️ 知识点缓存推送失败 \(localURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return pushedCount
    }
    
    // MARK: - 清理异常目录
    
    /// 清理本地和云端的异常目录（知识点缓存只有一层目录，任何子目录都是异常的）
    func cleanupAbnormalDirectories(cloudFS: CloudFileSystem) {
        // 清理本地异常目录（所有子目录都是异常的）
        cleanupLocalSubdirectories(at: localKnowledgeCacheDir)
        
        // 清理云端异常目录（所有子目录都是异常的）
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        cleanupCloudSubdirectories(cloudFS: cloudFS, at: cloudDir)
    }
    
    /// 清理本地所有子目录（知识点缓存只有一层目录）
    private func cleanupLocalSubdirectories(at url: URL) {
        guard let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        
        for child in children {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                // 删除异常子目录
                try? fileManager.removeItem(at: child)
                print("🧹 知识点缓存清理: 删除本地异常子目录 \(child.lastPathComponent)")
            }
        }
    }
    
    /// 清理云端所有子目录（知识点缓存只有一层目录）
    private func cleanupCloudSubdirectories(cloudFS: CloudFileSystem, at url: URL) {
        guard let children = try? cloudFS.contentsOfDirectory(at: url) else { return }
        
        for child in children {
            // 检查是否是目录（有子项就是目录）
            if let subChildren = try? cloudFS.contentsOfDirectory(at: child), !subChildren.isEmpty {
                // 递归删除异常子目录
                deleteCloudDirectoryRecursive(cloudFS: cloudFS, at: child)
                print("🧹 知识点缓存清理: 删除云端异常子目录 \(child.lastPathComponent)")
            }
        }
    }
    
    /// 递归删除云端目录
    private func deleteCloudDirectoryRecursive(cloudFS: CloudFileSystem, at url: URL) {
        guard let children = try? cloudFS.contentsOfDirectory(at: url) else {
            // 可能是文件，直接删除
            try? cloudFS.removeItem(at: url)
            return
        }
        
        for child in children {
            if let subChildren = try? cloudFS.contentsOfDirectory(at: child), !subChildren.isEmpty {
                // 是目录，递归删除
                deleteCloudDirectoryRecursive(cloudFS: cloudFS, at: child)
            } else {
                // 是文件，直接删除
                try? cloudFS.removeItem(at: child)
            }
        }
        
        // 删除空目录
        try? cloudFS.removeItem(at: url)
    }
    
    // MARK: - 单层目录扫描工具（知识点缓存只有一层目录）
    
    /// 只扫描一层目录（云端），不递归子目录
    private func listFilesFlat(cloudFS: CloudFileSystem, at url: URL) -> [URL] {
        var result: [URL] = []
        let children: [URL]
        do { children = try cloudFS.contentsOfDirectory(at: url) } catch { return result }
        for child in children {
            // 跳过子目录（知识点缓存只有一层目录）
            var subChildren: [URL] = []
            do { subChildren = try cloudFS.contentsOfDirectory(at: child) } catch {}
            if subChildren.isEmpty {
                // 是文件
                result.append(child)
            } else {
                // 是子目录，跳过（知识点缓存不应该有子目录）
                print("⚠️ 知识点缓存扫描: 跳过子目录 \(child.lastPathComponent)")
            }
        }
        return result
    }
    
    /// 只扫描一层目录（本地），不递归子目录
    private func listLocalFilesFlat(at url: URL) -> [URL] {
        var result: [URL] = []
        guard let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return result }
        for child in children {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // 是子目录，跳过（知识点缓存不应该有子目录）
                    print("⚠️ 知识点缓存扫描: 跳过子目录 \(child.lastPathComponent)")
                } else {
                    // 是文件
                    result.append(child)
                }
            }
        }
        return result
    }
    
    // MARK: - 递归扫描文件工具
    
    private func listFilesRecursive(cloudFS: CloudFileSystem, at url: URL, maxDepth: Int = 10, currentDepth: Int = 0) -> [URL] {
        var result: [URL] = []
        guard currentDepth < maxDepth else {
            print("⚠️ 递归扫描: 达到最大深度 \(maxDepth)，停止递归 \(url.lastPathComponent)")
            return result
        }
        
        let children: [URL]
        do { children = try cloudFS.contentsOfDirectory(at: url) } catch { return result }
        for child in children {
            var subChildren: [URL] = []
            do { subChildren = try cloudFS.contentsOfDirectory(at: child) } catch {}
            if subChildren.isEmpty {
                // 是文件
                result.append(child)
            } else {
                // 是目录，递归
                result.append(contentsOf: listFilesRecursive(cloudFS: cloudFS, at: child, maxDepth: maxDepth, currentDepth: currentDepth + 1))
            }
        }
        return result
    }
    
    private func listLocalFilesRecursive(at url: URL, maxDepth: Int = 10, currentDepth: Int = 0) -> [URL] {
        var result: [URL] = []
        guard currentDepth < maxDepth else {
            print("⚠️ 递归扫描: 达到最大深度 \(maxDepth)，停止递归 \(url.lastPathComponent)")
            return result
        }
        
        guard let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return result }
        for child in children {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    result.append(contentsOf: listLocalFilesRecursive(at: child, maxDepth: maxDepth, currentDepth: currentDepth + 1))
                } else {
                    result.append(child)
                }
            }
        }
        return result
    }
}

// MARK: - Notification

extension Notification.Name {
    static let metadataSyncNeeded = Notification.Name("MetadataSyncNeeded")
}
