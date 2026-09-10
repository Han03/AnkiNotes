//
//  MetadataPushService.swift
//  AnkiNotes
//
//  元数据推送服务：独立于同步流程，负责 .metadata 目录的延迟批量推送
//  支持持久化兜底，保证 App 被杀后元数据不丢失
//

import Foundation

/// 元数据推送服务
public final class MetadataPushService {
    public static let shared = MetadataPushService()
    
    private var dirtyFiles: Set<String> = []
    private var pushTimer: Timer?
    private let debounceInterval: TimeInterval = 10  // 10秒防抖
    
    /// 持久化 Key
    private static let keyDirtyFiles = "AnkiNotes.MetadataPush.DirtyFiles"
    
    weak var cloudFS: CloudFileSystem?
    weak var syncSnapshotService: SyncSnapshotService?
    
    private init() {
        // 启动时恢复待推送文件
        restorePendingFiles()
    }
    
    // MARK: - 公共接口
    
    /// 标记元数据文件为"脏"（有变更待推送）
    public func markDirty(_ fileName: String) {
        dirtyFiles.insert(fileName)
        savePendingFiles()
        schedulePush()
    }
    
    /// 立即执行待推送任务（App 进入后台时调用）
    func flush() {
        pushTimer?.invalidate()
        executePush()
    }
    
    // MARK: - 私有方法
    
    /// 调度推送（防抖）
    private func schedulePush() {
        pushTimer?.invalidate()
        pushTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.executePush()
        }
    }
    
    /// 执行批量推送
    private func executePush() {
        guard !dirtyFiles.isEmpty, let cloudFS = cloudFS else { return }
        
        print("📤 开始批量推送元数据: \(dirtyFiles.joined(separator: ", "))")
        
        // ① 获取云端锁
        guard CloudLockService.shared.acquireLock(cloudFS: cloudFS) else {
            print("⚠️ 元数据推送失败：无法获取锁，10秒后重试")
            schedulePush()  // 重试
            return
        }
        
        defer {
            CloudLockService.shared.releaseLock(cloudFS: cloudFS)
        }
        
        // ② 逐个推送脏文件
        var allSuccess = true
        for fileName in dirtyFiles {
            do {
                try pushSingleFile(fileName, cloudFS: cloudFS)
                print("✅ 推送成功: \(fileName)")
            } catch {
                print("⚠️ 推送 \(fileName) 失败: \(error.localizedDescription)")
                allSuccess = false
                // 推送失败不清除脏标记，下次重试
                break
            }
        }
        
        // ③ 全部成功才清空脏标记
        if allSuccess {
            dirtyFiles.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.keyDirtyFiles)
            print("📤 元数据推送完成，已清除脏标记")
        }
    }
    
    /// 推送单个元数据文件
    private func pushSingleFile(_ fileName: String, cloudFS: CloudFileSystem) throws {
        let localURL = localCacheURL(for: fileName)
        let cloudURL = cloudFS.rootDirectory
            .appendingPathComponent(".metadata", isDirectory: true)
            .appendingPathComponent(fileName)
        
        // 确保目录存在
        try cloudFS.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
        
        switch fileName {
        case "notes_index.json":
            // 【关键】智能合并 SRS 数据
            try pushWithMerge(fileName: fileName, localURL: localURL, cloudURL: cloudURL, cloudFS: cloudFS)
            
        case "review_logs.json":
            // 【关键】合并复习日志（按 ID 去重）
            try pushWithMerge(fileName: fileName, localURL: localURL, cloudURL: cloudURL, cloudFS: cloudFS)
            
        case "folders.json":
            // 直接覆盖（文件夹结构简单，updatedAt 最新者胜）
            let data = try Data(contentsOf: localURL)
            try cloudFS.writeData(data, to: cloudURL)
            
        default:
            break
        }
        
        // 更新快照
        if let modDate = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date {
            syncSnapshotService?.updateFile(relativePath: ".metadata/\(fileName)", lastModified: modDate)
        }
    }
    
    /// 带合并逻辑的推送（用于 notes_index.json 和 review_logs.json）
    private func pushWithMerge(fileName: String, localURL: URL, cloudURL: URL, cloudFS: CloudFileSystem) throws {
        // ① 读取本地数据
        let localData = try Data(contentsOf: localURL)
        
        // ② 尝试读取云端数据（用于合并）
        var mergedData = localData
        do {
            let cloudData = try cloudFS.readData(at: cloudURL)
            
            switch fileName {
            case "notes_index.json":
                let localMetas = try JSONDecoder().decode([NoteMeta].self, from: localData)
                let cloudMetas = try JSONDecoder().decode([NoteMeta].self, from: cloudData)
                let merged = mergeNoteMetas(local: localMetas, cloud: cloudMetas)
                mergedData = try JSONEncoder().encode(merged)
                
            case "review_logs.json":
                let localLogs = try JSONDecoder().decode([ReviewLog].self, from: localData)
                let cloudLogs = try JSONDecoder().decode([ReviewLog].self, from: cloudData)
                let merged = mergeReviewLogs(local: localLogs, cloud: cloudLogs)
                mergedData = try JSONEncoder().encode(merged)
                
            default:
                break
            }
        } catch {
            // 云端文件不存在或解析失败，直接使用本地数据
            print("⚠️ 读取云端 \(fileName) 失败，使用本地数据: \(error.localizedDescription)")
        }
        
        // ③ 推送合并后的数据
        try cloudFS.writeData(mergedData, to: cloudURL)
    }
    
    /// 合并 SRS 数据（复用 MetadataSyncService 的逻辑）
    private func mergeNoteMetas(local: [NoteMeta], cloud: [NoteMeta]) -> [NoteMeta] {
        var merged: [UUID: NoteMeta] = [:]
        
        for meta in cloud {
            merged[meta.id] = meta
        }
        
        for localMeta in local {
            if let cloudMeta = merged[localMeta.id] {
                // 保留 updatedAt 较新的
                if localMeta.updatedAt > cloudMeta.updatedAt {
                    merged[localMeta.id] = localMeta
                }
            } else {
                merged[localMeta.id] = localMeta
            }
        }
        
        return Array(merged.values)
    }
    
    /// 合并复习日志（按 ID 去重，保留较新的）
    private func mergeReviewLogs(local: [ReviewLog], cloud: [ReviewLog]) -> [ReviewLog] {
        var merged: [UUID: ReviewLog] = [:]
        
        for log in cloud {
            merged[log.id] = log
        }
        
        for localLog in local {
            if let cloudLog = merged[localLog.id] {
                if localLog.updatedAt >= cloudLog.updatedAt {
                    merged[localLog.id] = localLog
                }
            } else {
                merged[localLog.id] = localLog
            }
        }
        
        return Array(merged.values).sorted { $0.reviewDate > $1.reviewDate }
    }
    
    // MARK: - 持久化
    
    /// 保存待推送文件列表到 UserDefaults
    private func savePendingFiles() {
        if let data = try? JSONEncoder().encode(Array(dirtyFiles)) {
            UserDefaults.standard.set(data, forKey: Self.keyDirtyFiles)
        }
    }
    
    /// 从 UserDefaults 恢复待推送文件列表
    private func restorePendingFiles() {
        guard let data = UserDefaults.standard.data(forKey: Self.keyDirtyFiles),
              let files = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        dirtyFiles = Set(files)
        
        // 【关键】如果有残留的待推送文件，立即调度推送
        if !dirtyFiles.isEmpty {
            print("📤 发现 \(dirtyFiles.count) 个待推送元数据文件，立即调度")
            schedulePush()
        }
    }
    
    private func localCacheURL(for fileName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(".metadata").appendingPathComponent(fileName)
    }
}
