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
    private let metadataFiles: [String] = [
        "folders.json",
        "notes_index.json",
        "review_logs.json",
        "quiz_questions.json",
        "quiz_generated_notes.json"
    ]
    
    private init() {}
    
    // MARK: - 本地缓存目录
    
    /// 本地元数据缓存目录（App 沙盒 Library/Caches/Metadata）
    private var localCacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Metadata", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func localCacheURL(for fileName: String) -> URL {
        localCacheDirectory.appendingPathComponent(fileName)
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
        
        // 扫描云端 .knowledge_cache 目录
        let cloudFiles = listFilesRecursive(cloudFS: cloudFS, at: cloudDir)
        for cloudURL in cloudFiles {
            do {
                let relativePath = cloudURL.path.replacingOccurrences(of: cloudDir.path, with: "")
                let localURL = localKnowledgeCacheDir.appendingPathComponent(relativePath)
                
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
                print("📥 知识点缓存同步: 拉取 \(cloudURL.lastPathComponent)")
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
        
        // 扫描本地 .knowledge_cache 目录
        let localFiles = listLocalFilesRecursive(at: localKnowledgeCacheDir)
        for localURL in localFiles {
            do {
                let relativePath = localURL.path.replacingOccurrences(of: localKnowledgeCacheDir.path, with: "")
                let cloudURL = cloudDir.appendingPathComponent(relativePath)
                
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
                print("📤 知识点缓存同步: 推送 \(localURL.lastPathComponent)")
            } catch {
                print("⚠️ 知识点缓存推送失败 \(localURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return pushedCount
    }
    
    // MARK: - 递归扫描文件工具
    
    private func listFilesRecursive(cloudFS: CloudFileSystem, at url: URL) -> [URL] {
        var result: [URL] = []
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
                result.append(contentsOf: listFilesRecursive(cloudFS: cloudFS, at: child))
            }
        }
        return result
    }
    
    private func listLocalFilesRecursive(at url: URL) -> [URL] {
        var result: [URL] = []
        guard let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return result }
        for child in children {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    result.append(contentsOf: listLocalFilesRecursive(at: child))
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
