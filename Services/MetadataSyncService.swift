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
    
    /// 同步快照服务（用于知识点缓存的增量同步跳过）
    private weak var syncSnapshotService: SyncSnapshotService?
    /// StorageService 引用（用于共用 collectFilesFromFS / updateSnapshotAfterFileSync）
    weak var storage: StorageService?
    
    /// 配置同步快照服务
    func configure(syncSnapshotService: SyncSnapshotService) {
        self.syncSnapshotService = syncSnapshotService
    }
    
    /// 需要同步的元数据文件名
    private let metadataFiles: [String] = [
        "folders.json",
        "notes_index.json",
        "review_logs.json"
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
    /// - Parameters:
    ///   - cloudFS: 云端文件系统
    ///   - rootScanChildren: 根目录 PROPFIND Depth:1 的直接子项结果（由 syncFromCloud 传入），
    ///     用于 .metadata 目录的快照门控，避免额外的 PROPFIND
    /// - Returns: 成功拉取的文件数
    @discardableResult
    func pullFromCloud(cloudFS: CloudFileSystem,
                       rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) -> Int {
        let metadataDir = cloudFS.rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        var pulledCount = 0
        var skippedBySnapshot = 0
        
        // 【优化】利用根目录扫描结果中 .metadata 的修改时间做快照门控，
        // 快照命中时跳过整个 pull（0 次 PROPFIND），避免额外的 contentsOfDirectoryWithMetadata 调用
        if let children = rootScanChildren,
           let metadataEntry = children.first(where: { $0.url.lastPathComponent == ".metadata" }),
           let metadataModDate = metadataEntry.lastModified,
           let snap = syncSnapshotService {
            if !snap.isDirectoryUpdated(relativePath: ".metadata", lastModified: metadataModDate) {
                print("📥 元数据同步: .metadata 目录无更新，跳过整个拉取（根目录扫描快照命中）")
                return 0
            }
            snap.updateDirectory(relativePath: ".metadata", lastModified: metadataModDate)
        }
        
        // 一次 PROPFIND Depth:1 列举 .metadata/ 目录，替代对每个文件单独 getItemMetadata（3 次 PROPFIND → 1 次）
        let dirChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]
        do {
            dirChildren = try cloudFS.contentsOfDirectoryWithMetadata(at: metadataDir)
        } catch {
            // .metadata 目录不存在或读取失败，无需拉取
            return 0
        }
        // 构建文件名 → 修改时间的查找表
        var fileModDates: [String: Date] = [:]
        for child in dirChildren where !child.isDirectory {
            if let modDate = child.lastModified {
                fileModDates[child.url.lastPathComponent] = modDate
            }
        }
        
        for fileName in metadataFiles {
            let cloudURL = metadataDir.appendingPathComponent(fileName)
            let localURL = localCacheURL(for: fileName)
            let relativePath = ".metadata/\(fileName)"
            
            do {
                // 从已获取的目录列表中查找修改时间（无额外网络请求）
                guard let cloudModDate = fileModDates[fileName] else { continue }
                
                // 【快照跳过】利用已获取的修改时间检查是否需要拉取
                if let snap = syncSnapshotService,
                   !snap.isFileUpdated(relativePath: relativePath, lastModified: cloudModDate) {
                    skippedBySnapshot += 1
                    continue
                }
                
                // 读取云端数据
                let cloudData = try cloudFS.readData(at: cloudURL)
                
                // 比较本地缓存内容（如果存在）
                if let localData = try? Data(contentsOf: localURL),
                   localData == cloudData {
                    // 内容相同，跳过写入，但更新快照（复用已获取的 cloudModDate，不再重复 PROPFIND）
                    syncSnapshotService?.updateFile(relativePath: relativePath, lastModified: cloudModDate)
                    continue
                }
                
                // 写入本地缓存
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                
                // 【更新快照】复用已获取的 cloudModDate，不再重复 PROPFIND
                syncSnapshotService?.updateFile(relativePath: relativePath, lastModified: cloudModDate)
                
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
                // 检查本地缓存是否存在，同时获取修改时间（只读一次 attributes，复用三处）
                guard let localAttributes = try? fileManager.attributesOfItem(atPath: localURL.path),
                      let localModDate = localAttributes[.modificationDate] as? Date else { continue }
                
                // 【快照跳过】利用已获取的修改时间检查是否需要推送
                if let snap = syncSnapshotService,
                   !snap.isFileUpdated(relativePath: relativePath, lastModified: localModDate) {
                    skippedBySnapshot += 1
                    continue
                }
                
                // 读取本地数据
                let localData = try Data(contentsOf: localURL)
                
                // 【优化】快照已确认本地有变更，直接 PUT 覆盖，省去 GET 内容比对
                // 元数据文件通常 < 100KB，幂等写入代价极低；即使内容与云端相同也只是多一次小 PUT
                SyncLogger.shared.stepStart("☁️ 推送元数据: \(fileName)")
                try cloudFS.writeData(localData, to: cloudURL)
                pushedCount += 1
                lastPushTimestamps[fileName] = Date()
                SyncLogger.shared.stepDone("☁️ 推送元数据")
                
                // 【更新快照】复用已获取的 localModDate
                syncSnapshotService?.updateFile(relativePath: relativePath, lastModified: localModDate)
                
            } catch {
                SyncLogger.shared.stepFail("☁️ 推送元数据: \(fileName)", error: error)
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
    
    // MARK: - 知识点缓存同步（.knowledge_cache）
    
    /// 本地知识点缓存目录（Documents/.knowledge_cache）
    private var localKnowledgeCacheDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".knowledge_cache", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 从云端拉取知识点缓存到本地（与笔记/讲稿/题目共用 collectFilesFromFS 扫描 + updateSnapshotAfterFileSync 快照更新）
    func pullKnowledgeCache(cloudFS: CloudFileSystem,
                            rootScanChildren: [(url: URL, isDirectory: Bool, lastModified: Date?)]? = nil) -> Int {
        let cloudDir = cloudFS.rootDirectory.appendingPathComponent(".knowledge_cache", isDirectory: true)
        guard let storage = storage else { return 0 }
        
        // 【优化】根目录级跳过：优先使用根目录扫描结果中 .knowledge_cache 的修改时间，
        // 省去单独的 getItemMetadata PROPFIND；若无预扫描结果则回退到 getItemMetadata
        let knowledgeCacheModDate: Date?
        if let children = rootScanChildren,
           let entry = children.first(where: { $0.url.lastPathComponent == ".knowledge_cache" }) {
            knowledgeCacheModDate = entry.lastModified
        } else if let meta = try? cloudFS.getItemMetadata(at: cloudDir) {
            knowledgeCacheModDate = meta.lastModified
        } else {
            knowledgeCacheModDate = nil
        }
        if let snap = syncSnapshotService, let date = knowledgeCacheModDate {
            if !snap.isDirectoryUpdated(relativePath: ".knowledge_cache", lastModified: date) {
                print("📥 知识点缓存同步: 根目录无更新，跳过整个同步（快照跳过）")
                return 0
            }
            snap.updateDirectory(relativePath: ".knowledge_cache", lastModified: date)
        }
        
        // 用共用方法扫描云端目录（目录级 + 文件级快照跳过，与笔记/讲稿/题目完全一致）
        var directoryTimes: [String: Date] = [:]
        var fileTimes: [String: Date] = [:]
        let kcChildren = rootScanChildren?.first(where: { $0.url.lastPathComponent == ".knowledge_cache" }).flatMap { [$0] }
        var allFiles: [URL] = []
        storage.collectFilesFromFS(
            cloudFS, at: cloudDir, extensions: ["json", "md"],
            skipNames: [], into: &allFiles,
            rootURL: cloudDir,
            snapshot: syncSnapshotService,
            directoryTimes: &directoryTimes,
            fileTimes: &fileTimes,
            rootScanChildren: kcChildren
        )
        
        // 下载变更文件 + 统一快照更新
        var pulledCount = 0
        for fileURL in allFiles {
            do {
                let cloudData = try cloudFS.readData(at: fileURL)
                // 计算本地路径：文件相对于 cloudDir 的路径
                let relativePath = syncSnapshotService?.relativePath(for: fileURL, rootURL: cloudDir) ?? fileURL.lastPathComponent
                let localURL = localKnowledgeCacheDir.appendingPathComponent(relativePath)
                try? fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloudData.write(to: localURL, options: .atomic)
                pulledCount += 1
                // 用共用方法更新快照（文件级 + 父目录级，与笔记/讲稿/题目完全一致）
                if let snap = syncSnapshotService {
                    storage.updateSnapshotAfterFileSync(
                        cloud: cloudFS, snap: snap,
                        rootURL: cloudDir, fileURL: fileURL,
                        directoryTimes: directoryTimes, fileTimes: fileTimes
                    )
                }
                print("📥 知识点缓存同步: 拉取 \(fileURL.lastPathComponent)")
            } catch {
                print("⚠️ 知识点缓存拉取失败 \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        return pulledCount
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

