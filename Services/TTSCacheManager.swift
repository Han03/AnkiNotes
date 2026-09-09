//
//  TTSCacheManager.swift
//  AnkiNotes
//
//  TTS 音频缓存管理器：两级缓存（内存 + 磁盘），支持 LRU 淘汰
//

import Foundation
import CryptoKit

/// 缓存条目元数据
struct TTSCacheEntry: Codable {
    let fileName: String          // 磁盘文件名（{cacheKey}.mp3）
    let sentenceHash: String      // 句子文本哈希
    let voice: String             // 音色
    let speed: Double             // 语速
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
    
    // MARK: - 缓存目录
    private var cacheDirectory: URL {
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
    
    private var indexFileURL: URL {
        cacheDirectory.appendingPathComponent("cache_index.json")
    }
    
    // MARK: - 初始化
    private init() {
        loadCacheIndex()
        cleanupExpiredCache()
        SyncLogger.shared.info("💾 TTSCacheManager 初始化完成，磁盘缓存 \(diskCacheIndex.count) 条，总大小 \(totalDiskCacheSize() / 1024)KB")
    }
    
    // MARK: - 缓存 Key 计算
    
    /// 计算缓存 key（基于句子文本 + TTS 配置）
    func cacheKey(for sentence: String, voice: String, speed: Double, pitch: Int) -> String {
        let combined = "\(sentence)|\(voice)|\(speed)|\(pitch)"
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
        cacheQueue.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            self.indexLock.lock()
            guard let entry = self.diskCacheIndex[key] else {
                self.indexLock.unlock()
                completion(nil)
                return
            }
            self.indexLock.unlock()
            
            let fileURL = self.cacheDirectory.appendingPathComponent(entry.fileName)
            guard let data = try? Data(contentsOf: fileURL) else {
                // 文件不存在，清理索引
                self.removeCache(forKey: key)
                completion(nil)
                return
            }
            
            // 更新访问时间和访问次数
            self.updateAccessStats(forKey: key)
            
            // 写入内存缓存
            self.setMemoryCache(data, forKey: key)
            
            completion(data)
        }
    }
    
    /// 写入磁盘缓存（异步，不阻塞调用线程）
    func setDiskCache(_ data: Data, forKey key: String, sentence: String, voice: String, speed: Double, pitch: Int) {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let fileName = "\(key).mp3"
            let fileURL = self.cacheDirectory.appendingPathComponent(fileName)
            
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
                speed: speed,
                pitch: pitch,
                fileSize: data.count,
                createdAt: Date().timeIntervalSince1970,
                lastAccessedAt: Date().timeIntervalSince1970,
                accessCount: 1
            )
            
            self.indexLock.lock()
            self.diskCacheIndex[key] = entry
            self.indexLock.unlock()
            
            self.saveCacheIndex()
            
            // 检查缓存大小，必要时淘汰
            self.evictIfNeeded()
            
            SyncLogger.shared.info("💾 TTSCacheManager 写入磁盘缓存: key=\(key.prefix(8))..., size=\(data.count)字节, 总缓存=\(self.diskCacheIndex.count)条")
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
    func setCache(_ data: Data, forKey key: String, sentence: String, voice: String, speed: Double, pitch: Int) {
        setMemoryCache(data, forKey: key)
        setDiskCache(data, forKey: key, sentence: sentence, voice: voice, speed: speed, pitch: pitch)
    }
    
    // MARK: - 缓存淘汰
    
    /// 检查缓存大小，超过限制时按 LRU 淘汰
    private func evictIfNeeded() {
        let totalSize = totalDiskCacheSize()
        guard totalSize > maxDiskCacheSize else { return }
        
        SyncLogger.shared.info("💾 TTSCacheManager 缓存大小 \(totalSize / 1024)KB 超过限制 \(maxDiskCacheSize / 1024)KB，开始 LRU 淘汰")
        
        // 按 lastAccessedAt 升序排序（最久未使用的在前）
        let sortedEntries = diskCacheIndex.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        
        var currentSize = totalSize
        var evictedCount = 0
        
        for (key, entry) in sortedEntries {
            if currentSize <= maxDiskCacheSize * 8 / 10 { break }  // 淘汰到 80% 容量
            
            removeCache(forKey: key)
            currentSize -= entry.fileSize
            evictedCount += 1
        }
        
        SyncLogger.shared.info("💾 TTSCacheManager LRU 淘汰完成，淘汰 \(evictedCount) 条，剩余 \(diskCacheIndex.count) 条")
    }
    
    /// 清理过期缓存（超过 30 天未访问）
    private func cleanupExpiredCache() {
        let now = Date().timeIntervalSince1970
        let expirationInterval = TimeInterval(cacheExpirationDays * 24 * 60 * 60)
        
        var expiredCount = 0
        for (key, entry) in diskCacheIndex {
            if now - entry.lastAccessedAt > expirationInterval {
                removeCache(forKey: key)
                expiredCount += 1
            }
        }
        
        if expiredCount > 0 {
            SyncLogger.shared.info("💾 TTSCacheManager 清理过期缓存 \(expiredCount) 条")
            saveCacheIndex()
        }
    }
    
    /// 删除单个缓存
    private func removeCache(forKey key: String) {
        indexLock.lock()
        guard let entry = diskCacheIndex.removeValue(forKey: key) else {
            indexLock.unlock()
            return
        }
        indexLock.unlock()
        
        // 删除磁盘文件
        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        
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
        indexLock.lock()
        defer { indexLock.unlock() }
        
        guard var entry = diskCacheIndex[key] else { return }
        entry.lastAccessedAt = Date().timeIntervalSince1970
        entry.accessCount += 1
        diskCacheIndex[key] = entry
        
        // 异步保存索引（避免频繁写入）
        cacheQueue.async { [weak self] in
            self?.saveCacheIndex()
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
    
    // MARK: - 统计信息
    
    /// 磁盘缓存总大小
    func totalDiskCacheSize() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        return diskCacheIndex.values.reduce(0) { $0 + $1.fileSize }
    }
    
    /// 磁盘缓存条目数
    func diskCacheCount() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        return diskCacheIndex.count
    }
    
    /// 内存缓存条目数
    func memoryCacheCount() -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        return memoryCache.count
    }
    
    /// 清除所有缓存
    func clearAllCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // 删除所有磁盘文件
            for (_, entry) in self.diskCacheIndex {
                let fileURL = self.cacheDirectory.appendingPathComponent(entry.fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            
            // 清空索引和内存
            self.indexLock.lock()
            self.diskCacheIndex.removeAll()
            self.memoryCache.removeAll()
            self.memoryCacheOrder.removeAll()
            self.indexLock.unlock()
            
            self.saveCacheIndex()
            
            SyncLogger.shared.info("💾 TTSCacheManager 已清除所有缓存")
        }
    }
}
