//
//  TTSCacheManager.swift
//  AnkiNotes
//
//  TTS 音频缓存管理器：两级缓存（内存 + 磁盘），支持 LRU 淘汰
//  磁盘缓存按讲稿目录分层存储，镜像讲稿的文件夹结构：
//  .tts_cache/{folderPath}/{noteTitle}/{hash}.mp3 + index.json
//

import Foundation
import CryptoKit

/// 缓存条目元数据
struct TTSCacheEntry: Codable {
    let fileName: String          // 磁盘文件名（{cacheKey}.mp3）
    let sentenceHash: String      // 句子文本哈希
    let voice: String             // 音色
    let pitch: Int                // 音调
    let fileSize: Int             // 文件大小（字节）
    let createdAt: TimeInterval   // 创建时间
    var lastAccessedAt: TimeInterval  // 最后访问时间
    var accessCount: Int          // 访问次数
}

/// TTS 音频缓存管理器
final class TTSCacheManager {
    static let shared = TTSCacheManager()
    
    // MARK: - 配置
    private let maxDiskCacheSize: Int = 100 * 1024 * 1024  // 磁盘缓存最大 100MB
    private let maxMemoryCacheCount: Int = 20                // 内存缓存最多 20 句
    private let cacheExpirationDays: Int = 30                 // 缓存过期天数
    
    // MARK: - 内存缓存
    private var memoryCache: [String: Data] = [:]              // cacheKey -> 音频数据
    private var memoryCacheOrder: [String] = []                // LRU 顺序（最近使用的在末尾）
    
    // MARK: - 磁盘缓存
    private var diskCacheIndex: [String: TTSCacheEntry] = [:] // cacheKey -> 元数据
    private let cacheQueue = DispatchQueue(label: "com.ankinotes.ttscache", attributes: .concurrent)
    private let indexLock = NSLock()
    
    // MARK: - 缓存目录（按讲稿路径分层）
    
    /// 当前讲稿的缓存子路径（如 "JAVA高级/01-Java核心/IO与NIO"）
    /// 为 nil 时使用全局目录（_global），用于无讲稿上下文时的兜底
    private var currentLectureSubPath: String? = nil
    
    /// 设置当前讲稿的缓存路径（每次播放讲稿时调用）
    /// - Parameter lecturePath: 讲稿相对路径，如 "JAVA高级/01-Java核心/IO与NIO"
    func setLecturePath(_ lecturePath: String?) {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        // 规范化：去除首尾斜杠、合并连续斜杠、清理非法字符
        var normalized = lecturePath?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .split(separator: "/")
            .map { sanitizePathComponent(String($0)) }
            .joined(separator: "/")
        if let n = normalized, n.isEmpty { normalized = nil }
        
        let oldPath = currentLectureSubPath
        currentLectureSubPath = normalized
        
        // 切换讲稿时，重新加载该讲稿的索引
        if oldPath != currentLectureSubPath {
            diskCacheIndex = [:]
            loadCacheIndex()
            SyncLogger.shared.info("💾 TTSCacheManager 切换讲稿缓存路径: \(currentLectureSubPath ?? "_global")，磁盘缓存 \(diskCacheIndex.count) 条")
        }
    }
    
    /// 清理路径组件中的非法字符（防止目录穿越和特殊字符问题）
    private func sanitizePathComponent(_ component: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = component
            .components(separatedBy: illegal)
            .joined(separator: "_")
        return cleaned.isEmpty ? "_" : cleaned
    }
    
    /// 根缓存目录（.tts_cache）
    private var rootCacheDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documentsDir.appendingPathComponent(".tts_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 隐藏目录
        var url = dir
        var values = URLResourceValues()
        values.isHidden = true
        try? url.setResourceValues(values)
        return dir
    }
    
    /// 当前讲稿的缓存目录（按讲稿路径分层）
    private var cacheDirectory: URL {
        let root = rootCacheDirectory
        guard let subPath = currentLectureSubPath else {
            // 无讲稿上下文：使用 _global 目录
            let dir = root.appendingPathComponent("_global", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = root.appendingPathComponent(subPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 当前讲稿的缓存索引文件
    private var indexFileURL: URL {
        cacheDirectory.appendingPathComponent("index.json")
    }
    
    /// 所有讲稿的缓存目录列表（递归查找所有包含 index.json 的目录）
    /// 返回的 URL 是每个讲稿的缓存目录（.tts_cache/{folderPath}/{noteTitle}/）
    func allLectureCacheDirectories() -> [URL] {
        let root = rootCacheDirectory
        var result: [URL] = []
        
        // 递归遍历根目录，找到所有包含 index.json 的目录（即每个讲稿的缓存目录）
        func walk(_ dir: URL) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for url in files {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    // 如果是目录：如果包含 index.json 则作为一个讲稿缓存目录；否则递归
                    let indexURL = url.appendingPathComponent("index.json")
                    if FileManager.default.fileExists(atPath: indexURL.path) {
                        result.append(url)
                    } else {
                        walk(url)
                    }
                }
            }
        }
        walk(root)
        
        return result
    }
    
    // MARK: - 初始化
    private init() {
        // 检测并清除旧版扁平结构缓存（旧版：.tts_cache 根目录直接放 mp3 + cache_index.json）
        // 新版：按讲稿目录分层存储（.tts_cache/{folderPath}/{noteTitle}/index.json）
        // 旧缓存不会被新代码命中，会占用空间，所以首次启动时清除
        clearLegacyCacheIfNeeded()
        
        loadCacheIndex()
        cleanupExpiredCache()
        SyncLogger.shared.info("💾 TTSCacheManager 初始化完成，磁盘缓存 \(diskCacheIndex.count) 条，总大小 \(totalDiskCacheSize() / 1024)KB")
    }
    
    // MARK: - 旧缓存清理
    
    /// 检测并清除旧版缓存（两种情况）：
    /// 1. 旧格式缓存（Key 包含语速字段）
    /// 2. 旧扁平结构缓存（根目录直接放 mp3 + cache_index.json，无分层子目录）
    private func clearLegacyCacheIfNeeded() {
        let root = rootCacheDirectory
        
        // 情况1：旧格式缓存索引（包含 speed 字段）
        let legacyIndexURL = root.appendingPathComponent("cache_index.json")
        if FileManager.default.fileExists(atPath: legacyIndexURL.path),
           let data = try? Data(contentsOf: legacyIndexURL) {
            struct LegacyCacheEntry: Codable {
                let speed: Double?
            }
            if let legacyEntries = try? JSONDecoder().decode([String: LegacyCacheEntry].self, from: data),
               let firstEntry = legacyEntries.values.first,
               firstEntry.speed != nil {
                SyncLogger.shared.warning("💾 检测到旧格式缓存（包含语速字段），清除所有缓存重新开始")
                clearRootCacheDirectory()
                return
            }
        }
        
        // 情况2：旧扁平结构缓存（根目录直接有 mp3 文件或 cache_index.json，但无讲稿子目录）
        // 判断方法：根目录下有 .mp3 文件 或 cache_index.json，说明是旧扁平结构
        if let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let hasLegacyFiles = files.contains { url in
                url.pathExtension == "mp3" || url.lastPathComponent == "cache_index.json"
            }
            if hasLegacyFiles {
                SyncLogger.shared.warning("💾 检测到旧版扁平结构缓存（根目录直接存放音频），清除以切换到分层结构")
                clearRootCacheDirectory()
            }
        }
    }
    
    /// 清空整个缓存根目录（用于版本升级迁移）
    private func clearRootCacheDirectory() {
        let root = rootCacheDirectory
        do {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            SyncLogger.shared.info("💾 旧版缓存已清除，共删除 \(files.count) 个文件/目录")
        } catch {
            SyncLogger.shared.warning("💾 清除旧版缓存失败: \(error.localizedDescription)")
        }
        diskCacheIndex = [:]
        memoryCache.removeAll()
        memoryCacheOrder.removeAll()
        saveCacheIndex()
    }
    
    // MARK: - 缓存 Key 计算
    
    /// 计算缓存 key（基于句子文本 + 音色 + 音调，不包含语速，因为语速通过播放时后处理实现）
    func cacheKey(for sentence: String, voice: String, pitch: Int) -> String {
        let combined = "\(sentence)|\(voice)|\(pitch)"
        let hash = SHA256.hash(data: Data(combined.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// 计算句子文本哈希（用于统计）
    func sentenceHash(for sentence: String) -> String {
        let hash = SHA256.hash(data: Data(sentence.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - 内存缓存
    
    /// 从内存缓存读取
    func memoryCache(forKey key: String) -> Data? {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        guard let data = memoryCache[key] else { return nil }
        
        // 更新 LRU 顺序
        if let idx = memoryCacheOrder.firstIndex(of: key) {
            memoryCacheOrder.remove(at: idx)
        }
        memoryCacheOrder.append(key)
        
        return data
    }
    
    /// 写入内存缓存
    func setMemoryCache(_ data: Data, forKey key: String) {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        memoryCache[key] = data
        
        // 更新 LRU 顺序
        if let idx = memoryCacheOrder.firstIndex(of: key) {
            memoryCacheOrder.remove(at: idx)
        }
        memoryCacheOrder.append(key)
        
        // 超过容量时淘汰最旧的
        while memoryCacheOrder.count > maxMemoryCacheCount {
            let oldestKey = memoryCacheOrder.removeFirst()
            memoryCache.removeValue(forKey: oldestKey)
        }
    }
    
    // MARK: - 磁盘缓存
    
    /// 检查磁盘缓存是否存在
    func hasDiskCache(forKey key: String) -> Bool {
        indexLock.lock()
        defer { indexLock.unlock() }
        return diskCacheIndex[key] != nil
    }
    
    /// 从磁盘缓存读取（异步）
    func diskCache(forKey key: String, completion: @escaping (Data?) -> Void) {
        // 捕获调用时的目录和索引快照（避免异步执行时讲稿已切换）
        let targetDir = cacheDirectory
        let targetPath = currentLectureSubPath
        
        cacheQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            // 如果讲稿已切换，用目标目录的索引而不是当前内存索引
            var entry: TTSCacheEntry? = nil
            if targetPath == self.currentLectureSubPath {
                self.indexLock.lock()
                entry = self.diskCacheIndex[key]
                self.indexLock.unlock()
            } else {
                let indexURL = targetDir.appendingPathComponent("index.json")
                if let data = try? Data(contentsOf: indexURL),
                   let decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) {
                    entry = decoded[key]
                }
            }
            
            guard let entry = entry else {
                completion(nil)
                return
            }
            
            let fileURL = targetDir.appendingPathComponent(entry.fileName)
            guard let data = try? Data(contentsOf: fileURL) else {
                // 文件不存在，清理索引
                self.removeCache(forKey: key, inDirectory: targetDir)
                completion(nil)
                return
            }
            
            // 更新访问时间和访问次数
            self.updateAccessStats(forKey: key, inDirectory: targetDir, subPath: targetPath)
            
            // 写入内存缓存
            self.setMemoryCache(data, forKey: key)
            
            completion(data)
        }
    }
    
    /// 写入磁盘缓存（异步，不阻塞调用线程）
    func setDiskCache(_ data: Data, forKey key: String, sentence: String, voice: String, pitch: Int) {
        // 捕获调用时的目标目录（避免异步执行时讲稿已切换导致写入错误目录）
        let targetDir = cacheDirectory
        let currentPath = currentLectureSubPath
        
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let fileName = "\(key).mp3"
            let fileURL = targetDir.appendingPathComponent(fileName)
            
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                SyncLogger.shared.warning("💾 TTSCacheManager 写入磁盘缓存失败: \(error.localizedDescription)")
                return
            }
            
            let entry = TTSCacheEntry(
                fileName: fileName,
                sentenceHash: self.sentenceHash(for: sentence),
                voice: voice,
                pitch: pitch,
                fileSize: data.count,
                createdAt: Date().timeIntervalSince1970,
                lastAccessedAt: Date().timeIntervalSince1970,
                accessCount: 1
            )
            
            // 如果写入的正是当前讲稿目录，更新内存索引；否则直接更新对应目录的 index.json
            if currentPath == self.currentLectureSubPath, targetDir.path == self.cacheDirectory.path {
                self.indexLock.lock()
                self.diskCacheIndex[key] = entry
                self.indexLock.unlock()
                self.saveCacheIndex()
            } else {
                // 写入其他（或已切换的）讲稿目录：直接更新该目录的 index.json
                let indexURL = targetDir.appendingPathComponent("index.json")
                var decoded = [String: TTSCacheEntry]()
                if let data = try? Data(contentsOf: indexURL),
                   let existing = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) {
                    decoded = existing
                }
                decoded[key] = entry
                if let newData = try? JSONEncoder().encode(decoded) {
                    try? newData.write(to: indexURL, options: .atomic)
                }
            }
            
            // 检查缓存大小，必要时淘汰
            self.evictIfNeeded()
            
            SyncLogger.shared.info("💾 TTSCacheManager 写入磁盘缓存: key=\(key.prefix(8))..., size=\(data.count)字节")
        }
    }
    
    // MARK: - 统一读取接口（内存 -> 磁盘 -> 回调 nil）
    
    /// 统一读取缓存：先查内存，再查磁盘，都没有则返回 nil
    func getCache(forKey key: String, completion: @escaping (Data?) -> Void) {
        // 先查内存
        if let data = memoryCache(forKey: key) {
            SyncLogger.shared.info("💾 TTSCacheManager 内存命中: key=\(key.prefix(8))...")
            completion(data)
            return
        }
        
        // 内存未命中，查磁盘
        diskCache(forKey: key) { data in
            if data != nil {
                SyncLogger.shared.info("💾 TTSCacheManager 磁盘命中: key=\(key.prefix(8))...")
            }
            completion(data)
        }
    }
    
    /// 统一写入缓存：同时写入内存和磁盘
    func setCache(_ data: Data, forKey key: String, sentence: String, voice: String, pitch: Int) {
        setMemoryCache(data, forKey: key)
        setDiskCache(data, forKey: key, sentence: sentence, voice: voice, pitch: pitch)
    }
    
    // MARK: - 缓存淘汰
    
    /// 检查缓存大小，超过限制时按 LRU 淘汰（跨所有讲稿目录全局淘汰）
    private func evictIfNeeded() {
        let totalSize = totalDiskCacheSize()
        guard totalSize > maxDiskCacheSize else { return }
        
        SyncLogger.shared.info("💾 TTSCacheManager 缓存大小 \(totalSize / 1024)KB 超过限制 \(maxDiskCacheSize / 1024)KB，开始全局 LRU 淘汰")
        
        // 收集所有目录的 (目录URL, 条目) 并按 lastAccessedAt 升序排序（最久未使用的在前）
        var allEntries: [(dirURL: URL, key: String, entry: TTSCacheEntry)] = []
        
        // 当前讲稿目录（内存索引）
        let currentDir = cacheDirectory
        for (key, entry) in diskCacheIndex {
            allEntries.append((currentDir, key, entry))
        }
        
        // 其他讲稿目录（递归查找，跳过当前讲稿目录避免重复）
        let root = rootCacheDirectory
        for dirURL in allLectureCacheDirectories() {
            // 跳过当前讲稿目录
            if dirURL.path == currentDir.path { continue }
            let relativePath = dirURL.path.replacingOccurrences(of: root.path + "/", with: "")
            if relativePath == currentLectureSubPath { continue }
            
            let indexURL = dirURL.appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: indexURL),
                  let decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) else { continue }
            for (key, entry) in decoded {
                allEntries.append((dirURL, key, entry))
            }
        }
        
        let sortedEntries = allEntries.sorted { $0.entry.lastAccessedAt < $1.entry.lastAccessedAt }
        
        var currentSize = totalSize
        var evictedCount = 0
        
        for item in sortedEntries {
            if currentSize <= maxDiskCacheSize * 8 / 10 { break }  // 淘汰到 80% 容量
            
            removeCache(forKey: item.key, inDirectory: item.dirURL)
            currentSize -= item.entry.fileSize
            evictedCount += 1
        }
        
        SyncLogger.shared.info("💾 TTSCacheManager 全局 LRU 淘汰完成，淘汰 \(evictedCount) 条")
    }
    
    /// 清理过期缓存（超过 30 天未访问，跨所有讲稿目录）
    private func cleanupExpiredCache() {
        let now = Date().timeIntervalSince1970
        let expirationInterval = TimeInterval(cacheExpirationDays * 24 * 60 * 60)
        
        var expiredCount = 0
        
        // 当前讲稿目录
        for (key, entry) in diskCacheIndex {
            if now - entry.lastAccessedAt > expirationInterval {
                removeCache(forKey: key, inDirectory: cacheDirectory)
                expiredCount += 1
            }
        }
        saveCacheIndex()
        
        // 其他讲稿目录（跳过当前讲稿目录避免重复处理）
        let currentDir = cacheDirectory
        for dirURL in allLectureCacheDirectories() {
            if dirURL.path == currentDir.path { continue }
            
            let indexURL = dirURL.appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: indexURL),
                  var decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) else { continue }
            
            var dirExpiredCount = 0
            for (key, entry) in decoded {
                if now - entry.lastAccessedAt > expirationInterval {
                    // 删除文件
                    let fileURL = dirURL.appendingPathComponent(entry.fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                    decoded.removeValue(forKey: key)
                    dirExpiredCount += 1
                }
            }
            if dirExpiredCount > 0 {
                if let newData = try? JSONEncoder().encode(decoded) {
                    try? newData.write(to: indexURL, options: .atomic)
                }
                expiredCount += dirExpiredCount
            }
        }
        
        if expiredCount > 0 {
            SyncLogger.shared.info("💾 TTSCacheManager 清理过期缓存 \(expiredCount) 条")
        }
    }
    
    /// 删除单个缓存（当前讲稿目录）
    private func removeCache(forKey key: String) {
        removeCache(forKey: key, inDirectory: cacheDirectory)
    }
    
    /// 删除指定目录中的单个缓存
    private func removeCache(forKey key: String, inDirectory dirURL: URL) {
        // 先从当前内存索引中移除（如果存在）
        indexLock.lock()
        let entry = diskCacheIndex.removeValue(forKey: key)
        indexLock.unlock()
        
        // 如果当前目录中没有找到，尝试从目录的索引文件中查找文件名
        var fileName: String? = entry?.fileName
        if fileName == nil {
            let indexURL = dirURL.appendingPathComponent("index.json")
            if let data = try? Data(contentsOf: indexURL),
               let decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data),
               let dirEntry = decoded[key] {
                fileName = dirEntry.fileName
            }
        }
        
        // 删除磁盘文件
        if let fileName = fileName {
            let fileURL = dirURL.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // 更新对应目录的索引文件
        let indexURL = dirURL.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           var decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) {
            decoded.removeValue(forKey: key)
            if let newData = try? JSONEncoder().encode(decoded) {
                try? newData.write(to: indexURL, options: .atomic)
            }
        }
        
        // 如果是当前讲稿目录，内存索引已更新，保存到磁盘
        if dirURL.path == cacheDirectory.path {
            saveCacheIndex()
        }
        
        // 删除内存缓存
        indexLock.lock()
        memoryCache.removeValue(forKey: key)
        if let idx = memoryCacheOrder.firstIndex(of: key) {
            memoryCacheOrder.remove(at: idx)
        }
        indexLock.unlock()
    }
    
    // MARK: - 访问统计更新
    
    private func updateAccessStats(forKey key: String) {
        updateAccessStats(forKey: key, inDirectory: cacheDirectory, subPath: currentLectureSubPath)
    }
    
    /// 更新指定目录中条目的访问统计
    private func updateAccessStats(forKey key: String, inDirectory dirURL: URL, subPath: String?) {
        // 当前讲稿目录：更新内存索引
        if subPath == currentLectureSubPath, dirURL.path == cacheDirectory.path {
            indexLock.lock()
            guard var entry = diskCacheIndex[key] else {
                indexLock.unlock()
                return
            }
            entry.lastAccessedAt = Date().timeIntervalSince1970
            entry.accessCount += 1
            diskCacheIndex[key] = entry
            indexLock.unlock()
            
            // 异步保存索引（避免频繁写入）
            cacheQueue.async { [weak self] in
                self?.saveCacheIndex()
            }
        } else {
            // 其他讲稿目录：直接更新对应 index.json
            let indexURL = dirURL.appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: indexURL),
                  var decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data),
                  var entry = decoded[key] else { return }
            entry.lastAccessedAt = Date().timeIntervalSince1970
            entry.accessCount += 1
            decoded[key] = entry
            if let newData = try? JSONEncoder().encode(decoded) {
                try? newData.write(to: indexURL, options: .atomic)
            }
        }
    }
    
    // MARK: - 索引文件读写
    
    private func loadCacheIndex() {
        guard FileManager.default.fileExists(atPath: indexFileURL.path),
              let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data) else {
            diskCacheIndex = [:]
            return
        }
        diskCacheIndex = decoded
    }
    
    private func saveCacheIndex() {
        guard let data = try? JSONEncoder().encode(diskCacheIndex) else { return }
        try? data.write(to: indexFileURL, options: .atomic)
    }
    
    // MARK: - 跨讲稿目录的全局统计与清理
    
    /// 遍历所有讲稿目录的缓存索引，返回 (子路径, 索引字典) 数组
    /// 用于全局统计、LRU淘汰、过期清理（不受当前讲稿上下文限制）
    private func allLectureCacheIndexes() -> [(subPath: String, index: [String: TTSCacheEntry])] {
        var result: [(String, [String: TTSCacheEntry])] = []
        let root = rootCacheDirectory
        
        // 遍历所有讲稿缓存目录（递归），读取各自索引
        for dirURL in allLectureCacheDirectories() {
            // 计算相对根目录的子路径（如 "JAVA高级/01-Java核心/IO与NIO"）
            let relativePath = dirURL.path.replacingOccurrences(of: root.path + "/", with: "")
            // 跳过当前已统计的目录（当前讲稿索引已在内存 diskCacheIndex 中）
            if relativePath == currentLectureSubPath { continue }
            
            let indexURL = dirURL.appendingPathComponent("index.json")
            if let data = try? Data(contentsOf: indexURL),
               let decoded = try? JSONDecoder().decode([String: TTSCacheEntry].self, from: data),
               !decoded.isEmpty {
                result.append((relativePath, decoded))
            }
        }
        
        return result
    }
    
    // MARK: - 统计信息
    
    /// 磁盘缓存总大小（跨所有讲稿目录）
    func totalDiskCacheSize() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        // 当前讲稿索引
        var total = diskCacheIndex.values.reduce(0) { $0 + $1.fileSize }
        // 其他讲稿目录
        for (_, index) in allLectureCacheIndexes() {
            total += index.values.reduce(0) { $0 + $1.fileSize }
        }
        return total
    }
    
    /// 磁盘缓存条目数（跨所有讲稿目录）
    func diskCacheCount() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        var count = diskCacheIndex.count
        for (_, index) in allLectureCacheIndexes() {
            count += index.count
        }
        return count
    }
    
    /// 内存缓存条目数
    func memoryCacheCount() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        return memoryCache.count
    }
    
    /// 清除所有缓存（跨所有讲稿目录）
    func clearAllCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // 删除当前讲稿目录的磁盘文件（捕获目录，避免切换影响）
            let currentDir = self.cacheDirectory
            for (_, entry) in self.diskCacheIndex {
                let fileURL = currentDir.appendingPathComponent(entry.fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            
            // 删除所有讲稿缓存目录（递归查找，含当前讲稿目录）
            for dirURL in self.allLectureCacheDirectories() {
                try? FileManager.default.removeItem(at: dirURL)
            }
            
            // 清空索引和内存
            self.indexLock.lock()
            self.diskCacheIndex.removeAll()
            self.memoryCache.removeAll()
            self.memoryCacheOrder.removeAll()
            self.indexLock.unlock()
            
            self.saveCacheIndex()
            
            SyncLogger.shared.info("💾 TTSCacheManager 已清除所有缓存（跨所有讲稿目录）")
        }
    }
}
