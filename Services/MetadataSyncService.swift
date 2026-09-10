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
    
    /// 同步快照服务（用于知识点缓存的增量同步跳过）
    private weak var syncSnapshotService: SyncSnapshotService?
    
    /// 配置同步快照服务
    func configure(syncSnapshotService: SyncSnapshotService) {
        self.syncSnapshotService = syncSnapshotService
    }
    
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
                // 用 > 而非 >=：时间相等时保留云端，避免无谓的本地覆盖导致合并结果与云端字节差异
                if localNote.updatedAt > cloudNote.updatedAt {
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
        var skippedBySnapshot = 0
        
        for fileName in metadataFiles {
            let cloudURL = metadataDir.appendingPathComponent(fileName)
            let localURL = localCacheURL(for: fileName)
            let relativePath = ".metadata/\(fileName)"
            
            do {
                // 检查云端文件是否存在
                guard cloudFS.fileExists(at: cloudURL) else { continue }
                
                // 【快照跳过】获取云端文件的修改时间，检查是否需要拉取
                if let snap = syncSnapshotService,
                   let cloudMeta = try? cloudFS.getItemMetadata(at: cloudURL),
                   let cloudModDate = cloudMeta.lastModified,
                   !snap.isFileUpdated(relativePath: relativePath, lastModified: cloudModDate) {
                    skippedBySnapshot += 1
                    continue
                }
                
                // 读取云端数据
                let cloudData = try cloudFS.readData(at: cloudURL)
                
                // 比较本地缓存内容（如果存在）
                if let localData = try? Data(contentsOf: localURL),
                   localData == cloudData {
                    // 内容相同，跳过写入，但更新快照
                    if let snap = syncSnapshotService,
                       let cloudMeta = try? cloudFS.getItemMetadata(at: cloudURL),
                       let cloudModDate = cloudMeta.lastModified {
                        snap.updateFile(relativePath: relativePath, lastModified: cloudModDate)
                    }
                    continue
                }
                
                // 写入本地缓存
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                
                // 【更新快照】记录文件的修改时间
                if let snap = syncSnapshotService,
                   let cloudMeta = try? cloudFS.getItemMetadata(at: cloudURL),
                   let cloudModDate = cloudMeta.lastModified {
                    snap.updateFile(relativePath: relativePath, lastModified: cloudModDate)
                }
                
                print("📥 元数据同步: 拉取 \(fileName) (\(cloudData.count) bytes)")
                
            } catch {
                print("⚠️ 元数据拉取失败 \(fileName): \(error.localizedDescription)")
            }
        }
        
        if skippedBySnapshot > 0 {
            print("📥 元数据同步: 快照跳过 \(skippedBySnapshot) 个文件，实际拉取 \(pulledCount) 个文件")
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
        var skippedBySnapshot = 0
        
        for fileName in metadataFiles {
            let localURL = localCacheURL(for: fileName)
            let cloudURL = metadataDir.appendingPathComponent(fileName)
            let relativePath = ".metadata/\(fileName)"
            
            do {
                // 检查本地缓存是否存在
                guard fileManager.fileExists(atPath: localURL.path) else { continue }
                
                // 【快照跳过】获取本地文件的修改时间，检查是否需要推送
                if let snap = syncSnapshotService,
                   let localAttributes = try? fileManager.attributesOfItem(atPath: localURL.path),
                   let localModDate = localAttributes[.modificationDate] as? Date,
                   !snap.isFileUpdated(relativePath: relativePath, lastModified: localModDate) {
                    skippedBySnapshot += 1
                    continue
                }
                
                // 读取本地数据
                let localData = try Data(contentsOf: localURL)
                
                // 比较云端内容（如果存在）
                if let cloudData = try? cloudFS.readData(at: cloudURL),
                   cloudData == localData {
                    // 内容相同，跳过写入，但更新快照
                    if let snap = syncSnapshotService,
                       let localAttributes = try? fileManager.attributesOfItem(atPath: localURL.path),
                       let localModDate = localAttributes[.modificationDate] as? Date {
                        snap.updateFile(relativePath: relativePath, lastModified: localModDate)
                    }
                    continue
                }
                
                // 写入云端
                try cloudFS.writeData(localData, to: cloudURL)
                pushedCount += 1
                lastPushTimestamps[fileName] = Date()
                
                // 【更新快照】记录文件的修改时间
                if let snap = syncSnapshotService,
                   let localAttributes = try? fileManager.attributesOfItem(atPath: localURL.path),
                   let localModDate = localAttributes[.modificationDate] as? Date {
                    snap.updateFile(relativePath: relativePath, lastModified: localModDate)
                }
                
                print("📤 元数据同步: 推送 \(fileName) (\(localData.count) bytes)")
                
            } catch {
                print("⚠️ 元数据推送失败 \(fileName): \(error.localizedDescription)")
            }
        }
        
        if skippedBySnapshot > 0 {
            print("📤 元数据同步: 快照跳过 \(skippedBySnapshot) 个文件，实际推送 \(pushedCount) 个文件")
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
    
    /// 从云端拉取知识点缓存到本地（支持递归扫描子目录和快照跳过）
    func pullKnowledgeCache(cloudFS: CloudFileSystem) -> Int {
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        var pulledCount = 0
        var skippedBySnapshot = 0
        
        // 根目录级跳过：检查 .knowledge_cache 目录的修改时间，如果没有更新，跳过整个同步
        if let snap = syncSnapshotService {
            let dirRelativePath = ".knowledge_cache"
            if let dirMeta = try? cloudFS.getItemMetadata(at: cloudDir),
               let dirModDate = dirMeta.lastModified,
               !snap.isDirectoryUpdated(relativePath: dirRelativePath, lastModified: dirModDate) {
                print("📥 知识点缓存同步: 根目录无更新，跳过整个同步（快照跳过）")
                return 0
            }
            if let dirMeta = try? cloudFS.getItemMetadata(at: cloudDir),
               let dirModDate = dirMeta.lastModified {
                snap.updateDirectory(relativePath: dirRelativePath, lastModified: dirModDate)
            }
        }
        
        // 递归扫描云端目录，获取所有文件（包含子目录）
        let allFiles = scanCloudDirectoryRecursive(cloudFS: cloudFS, at: cloudDir, baseRelativePath: ".knowledge_cache")
        
        for file in allFiles {
            let cloudURL = file.url
            let fileRelativePath = file.relativePath
            
            // 文件级跳过：检查文件的修改时间，如果没有更新，跳过该文件
            if let snap = syncSnapshotService,
               let fileModDate = file.lastModified,
               !snap.isFileUpdated(relativePath: fileRelativePath, lastModified: fileModDate) {
                skippedBySnapshot += 1
                continue
            }
            
            do {
                // 计算本地路径：将相对路径中的 .knowledge_cache/ 替换为本地目录
                let localRelativePath = fileRelativePath.replacingOccurrences(of: ".knowledge_cache/", with: "")
                let localURL = localKnowledgeCacheDir.appendingPathComponent(localRelativePath)
                
                let cloudData = try cloudFS.readData(at: cloudURL)
                
                // 比较本地缓存
                if let localData = try? Data(contentsOf: localURL),
                   localData == cloudData {
                    if let snap = syncSnapshotService,
                       let fileModDate = file.lastModified {
                        snap.updateFile(relativePath: fileRelativePath, lastModified: fileModDate)
                    }
                    continue
                }
                
                // 写入本地
                try? fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                
                if let snap = syncSnapshotService,
                   let fileModDate = file.lastModified {
                    snap.updateFile(relativePath: fileRelativePath, lastModified: fileModDate)
                }
                
                print("📥 知识点缓存同步: 拉取 \(fileRelativePath)")
            } catch {
                print("⚠️ 知识点缓存拉取失败 \(fileRelativePath): \(error.localizedDescription)")
            }
        }
        
        if skippedBySnapshot > 0 {
            print("📥 知识点缓存同步: 快照跳过 \(skippedBySnapshot) 个文件，实际拉取 \(pulledCount) 个文件")
        }
        
        return pulledCount
    }
    
    /// 递归扫描云端目录，返回所有文件（包含子目录中的文件）
    private func scanCloudDirectoryRecursive(
        cloudFS: CloudFileSystem,
        at dirURL: URL,
        baseRelativePath: String
    ) -> [(url: URL, relativePath: String, lastModified: Date?)] {
        var result: [(url: URL, relativePath: String, lastModified: Date?)] = []
        
        let children: [(url: URL, isDirectory: Bool, lastModified: Date?)]
        do {
            children = try cloudFS.contentsOfDirectoryWithMetadata(at: dirURL)
        } catch {
            print("⚠️ 知识点缓存扫描: 目录扫描失败 \(dirURL.lastPathComponent): \(error.localizedDescription)")
            return result
        }
        
        for child in children {
            let childRelativePath = "\(baseRelativePath)/\(child.url.lastPathComponent)"
            
            if child.isDirectory {
                // 子目录级跳过：检查子目录的修改时间，如果没有更新，跳过整个子目录
                if let snap = syncSnapshotService,
                   let dirModDate = child.lastModified,
                   !snap.isDirectoryUpdated(relativePath: childRelativePath, lastModified: dirModDate) {
                    // 子目录无更新，跳过
                    continue
                }
                // 更新子目录的修改时间到快照
                if let snap = syncSnapshotService,
                   let dirModDate = child.lastModified {
                    snap.updateDirectory(relativePath: childRelativePath, lastModified: dirModDate)
                }
                // 递归扫描子目录
                let subFiles = scanCloudDirectoryRecursive(
                    cloudFS: cloudFS,
                    at: child.url,
                    baseRelativePath: childRelativePath
                )
                result.append(contentsOf: subFiles)
            } else {
                // 是文件，添加到结果
                result.append((url: child.url, relativePath: childRelativePath, lastModified: child.lastModified))
            }
        }
        
        return result
    }
    
    /// 将本地知识点缓存推送到云端（支持递归扫描子目录和快照跳过）
    func pushKnowledgeCache(cloudFS: CloudFileSystem) -> Int {
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: cloudDir)
        var pushedCount = 0
        var skippedBySnapshot = 0
        
        // 根目录级跳过：检查本地 .knowledge_cache 目录的修改时间，如果没有更新，跳过整个推送
        if let snap = syncSnapshotService {
            let dirRelativePath = ".knowledge_cache"
            if let dirAttributes = try? fileManager.attributesOfItem(atPath: localKnowledgeCacheDir.path),
               let dirModDate = dirAttributes[.modificationDate] as? Date,
               !snap.isDirectoryUpdated(relativePath: dirRelativePath, lastModified: dirModDate) {
                print("📤 知识点缓存同步: 根目录无更新，跳过整个推送（快照跳过）")
                return 0
            }
        }
        
        // 递归扫描本地目录，获取所有文件（包含子目录中的文件）
        let allLocalFiles = scanLocalDirectoryRecursive(at: localKnowledgeCacheDir, baseRelativePath: ".knowledge_cache")
        
        for file in allLocalFiles {
            let localURL = file.url
            let fileRelativePath = file.relativePath
            
            guard fileManager.fileExists(atPath: localURL.path) else { continue }
            
            // 文件级快照跳过：检查本地文件的修改时间，如果没有更新，跳过该文件
            if let snap = syncSnapshotService,
               let localModDate = file.lastModified,
               !snap.isFileUpdated(relativePath: fileRelativePath, lastModified: localModDate) {
                skippedBySnapshot += 1
                continue
            }
            
            do {
                let localData = try Data(contentsOf: localURL)
                
                // 计算云端路径：将相对路径中的 .knowledge_cache/ 替换为云端目录
                let cloudRelativePath = fileRelativePath.replacingOccurrences(of: ".knowledge_cache/", with: "")
                let cloudURL = cloudDir.appendingPathComponent(cloudRelativePath)
                
                // 比较云端内容
                var needPush = true
                if let cloudData = try? cloudFS.readData(at: cloudURL),
                   cloudData == localData {
                    needPush = false
                }
                
                if !needPush {
                    // 内容相同，更新文件的修改时间到快照
                    if let snap = syncSnapshotService,
                       let localModDate = file.lastModified {
                        snap.updateFile(relativePath: fileRelativePath, lastModified: localModDate)
                    }
                    continue
                }
                
                // 写入云端
                try? cloudFS.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
                try cloudFS.writeData(localData, to: cloudURL)
                pushedCount += 1
                
                // 更新文件的修改时间到快照
                if let snap = syncSnapshotService,
                   let localModDate = file.lastModified {
                    snap.updateFile(relativePath: fileRelativePath, lastModified: localModDate)
                }
                
                print("📤 知识点缓存同步: 推送 \(fileRelativePath)")
            } catch {
                print("⚠️ 知识点缓存推送失败 \(fileRelativePath): \(error.localizedDescription)")
            }
        }
        
        if skippedBySnapshot > 0 {
            print("📤 知识点缓存同步: 快照跳过 \(skippedBySnapshot) 个文件，实际推送 \(pushedCount) 个文件")
        }
        
        return pushedCount
    }
    
    /// 递归扫描本地目录，返回所有文件（包含子目录中的文件）
    private func scanLocalDirectoryRecursive(
        at dirURL: URL,
        baseRelativePath: String
    ) -> [(url: URL, relativePath: String, lastModified: Date?)] {
        var result: [(url: URL, relativePath: String, lastModified: Date?)] = []
        
        guard let children = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return result
        }
        
        for child in children {
            let childRelativePath = "\(baseRelativePath)/\(child.lastPathComponent)"
            
            let resourceValues = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let lastModified = resourceValues?.contentModificationDate
            
            if isDirectory {
                // 子目录级跳过：检查子目录的修改时间，如果没有更新，跳过整个子目录
                if let snap = syncSnapshotService,
                   let dirModDate = lastModified,
                   !snap.isDirectoryUpdated(relativePath: childRelativePath, lastModified: dirModDate) {
                    continue
                }
                // 更新子目录的修改时间到快照
                if let snap = syncSnapshotService,
                   let dirModDate = lastModified {
                    snap.updateDirectory(relativePath: childRelativePath, lastModified: dirModDate)
                }
                // 递归扫描子目录
                let subFiles = scanLocalDirectoryRecursive(at: child, baseRelativePath: childRelativePath)
                result.append(contentsOf: subFiles)
            } else {
                // 是文件，添加到结果
                result.append((url: child, relativePath: childRelativePath, lastModified: lastModified))
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
