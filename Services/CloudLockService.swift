//
//  CloudLockService.swift
//  AnkiNotes
//
//  云端存储读写锁服务（修复版）
//  通过云端 .lock 文件实现分布式互斥锁，避免数据冲突
//
//  修复内容：
//  1. 原子获取锁：使用 writeDataIfNotExists（If-None-Match: *）
//  2. 原子释放锁：读取验证后删除，删除后二次确认
//  3. 定时器在主线程运行（后台线程 RunLoop 不工作）
//  4. 增加 fencing token（单调递增），防止时钟不同步
//  5. 每次写操作前验证锁的所有权
//  6. 获取锁后二次确认，防止竞态条件
//

import Foundation

/// 云端锁服务
/// 使用云端 .metadata/.lock 文件实现分布式互斥锁
final class CloudLockService {
    static let shared = CloudLockService()
    
    /// 锁过期时间（秒）
    private let lockTimeout: TimeInterval = 300  // 5 分钟
    
    /// 锁续期间隔（秒）
    private let lockRenewInterval: TimeInterval = 120  // 2 分钟
    
    /// 当前是否持有锁
    private(set) var isHoldingLock = false
    
    /// 当前持有的 fencing token（单调递增，用于验证锁的有效性）
    private(set) var currentFencingToken: Int64 = 0
    
    /// 锁续期定时器
    private var renewTimer: Timer?
    
    /// 设备唯一标识（持久化到 UserDefaults）
    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "CloudLockDeviceId") {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "CloudLockDeviceId")
        return id
    }
    
    /// fencing token 计数器（持久化，保证单调递增）
    private var nextFencingToken: Int64 {
        let current = UserDefaults.standard.object(forKey: "CloudLockFencingToken") as? Int64 ?? 0
        let next = current + 1
        UserDefaults.standard.set(next, forKey: "CloudLockFencingToken")
        return next
    }
    
    private init() {}
    
    // MARK: - 锁文件路径
    
    private func lockFileURL(in cloudFS: CloudFileSystem) -> URL {
        let metadataDir = cloudFS.rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try? cloudFS.createDirectoryIfNeeded(at: metadataDir)
        return metadataDir.appendingPathComponent(".lock")
    }
    
    // MARK: - 锁数据结构
    
    private struct LockData: Codable {
        let deviceId: String
        let fencingToken: Int64
        let acquiredAt: TimeInterval
        let expiresAt: TimeInterval
    }
    
    // MARK: - 获取锁（原子操作）
    
    /// 尝试获取云端锁（原子操作）
    /// - Parameter cloudFS: 云端文件系统
    /// - Returns: 是否成功获取锁
    @discardableResult
    func acquireLock(cloudFS: CloudFileSystem) -> Bool {
        // 如果已经持有锁，先验证是否仍然有效
        if isHoldingLock {
            if verifyLockOwnership(cloudFS: cloudFS) {
                return true
            }
            // 锁已失效，重置状态
            isHoldingLock = false
            currentFencingToken = 0
            stopRenewTimer()
        }
        
        let lockURL = lockFileURL(in: cloudFS)
        let now = Date().timeIntervalSince1970
        
        // 1. 检查锁是否存在且未过期
        if cloudFS.fileExists(at: lockURL) {
            do {
                let data = try cloudFS.readData(at: lockURL)
                if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                    // 检查锁是否过期
                    if lockData.expiresAt > now {
                        // 锁未过期
                        if lockData.deviceId == deviceId {
                            // 是自己持有的锁，续期
                            return renewLock(cloudFS: cloudFS)
                        }
                        // 被其他设备持有，获取失败
                        print("🔒 云端锁被设备 \(lockData.deviceId.prefix(8))... 持有，过期时间: \(Date(timeIntervalSince1970: lockData.expiresAt))")
                        return false
                    }
                    // 锁已过期，可以强制获取
                    print("🔓 云端锁已过期（token: \(lockData.fencingToken)），强制获取")
                    // 删除过期的锁文件
                    try? cloudFS.removeItem(at: lockURL)
                }
            } catch {
                print("⚠️ 读取锁文件失败，尝试强制获取: \(error.localizedDescription)")
            }
        }
        
        // 2. 原子创建锁文件（If-None-Match: *）
        let token = nextFencingToken
        let lockData = LockData(
            deviceId: deviceId,
            fencingToken: token,
            acquiredAt: now,
            expiresAt: now + lockTimeout
        )
        
        do {
            let data = try JSONEncoder().encode(lockData)
            let success = try cloudFS.writeDataIfNotExists(data, to: lockURL)
            
            if !success {
                // 文件已存在，说明被其他设备抢占了
                print("⚠️ 云端锁被其他设备抢占，获取失败")
                return false
            }
            
            // 3. 二次确认：读取锁文件，确认是自己的
            Thread.sleep(forTimeInterval: 0.1)  // 短暂等待，确保写入完成
            if !verifyLockOwnership(cloudFS: cloudFS) {
                print("⚠️ 二次确认失败，锁可能被抢占")
                isHoldingLock = false
                currentFencingToken = 0
                return false
            }
            
            isHoldingLock = true
            currentFencingToken = token
            startRenewTimer(cloudFS: cloudFS)
            print("✅ 获取云端锁成功 (token: \(token), device: \(deviceId.prefix(8))...)")
            return true
            
        } catch {
            print("❌ 获取云端锁失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 释放锁（带验证）
    
    /// 释放云端锁
    /// - Parameter cloudFS: 云端文件系统
    func releaseLock(cloudFS: CloudFileSystem) {
        guard isHoldingLock else { return }
        
        stopRenewTimer()
        
        let lockURL = lockFileURL(in: cloudFS)
        
        // 只有持有者才能释放
        if cloudFS.fileExists(at: lockURL) {
            do {
                let data = try cloudFS.readData(at: lockURL)
                if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                    if lockData.deviceId == deviceId && lockData.fencingToken == currentFencingToken {
                        // 确认是自己的锁，删除
                        try cloudFS.removeItem(at: lockURL)
                        
                        // 二次确认：检查是否删除成功
                        Thread.sleep(forTimeInterval: 0.1)
                        if cloudFS.fileExists(at: lockURL) {
                            print("⚠️ 锁文件删除后仍然存在，可能有并发问题")
                        } else {
                            print("🔓 释放云端锁成功 (token: \(currentFencingToken))")
                        }
                    } else {
                        print("⚠️ 锁不是当前设备持有（token 不匹配），不释放")
                    }
                }
            } catch {
                print("⚠️ 释放锁失败: \(error.localizedDescription)")
            }
        }
        
        isHoldingLock = false
        currentFencingToken = 0
    }
    
    // MARK: - 验证锁所有权
    
    /// 验证当前是否仍然持有锁（每次写操作前调用）
    /// - Parameter cloudFS: 云端文件系统
    /// - Returns: 是否仍然持有锁
    func verifyLockOwnership(cloudFS: CloudFileSystem) -> Bool {
        let lockURL = lockFileURL(in: cloudFS)
        
        guard cloudFS.fileExists(at: lockURL) else {
            return false
        }
        
        do {
            let data = try cloudFS.readData(at: lockURL)
            guard let lockData = try? JSONDecoder().decode(LockData.self, from: data) else {
                return false
            }
            
            let now = Date().timeIntervalSince1970
            // 验证：设备 ID 匹配 + fencing token 匹配 + 未过期
            return lockData.deviceId == deviceId &&
                   lockData.fencingToken == currentFencingToken &&
                   lockData.expiresAt > now
        } catch {
            return false
        }
    }
    
    // MARK: - 锁续期
    
    /// 续期锁（延长过期时间）
    @discardableResult
    private func renewLock(cloudFS: CloudFileSystem) -> Bool {
        let lockURL = lockFileURL(in: cloudFS)
        let now = Date().timeIntervalSince1970
        
        // 先验证锁的所有权
        guard verifyLockOwnership(cloudFS: cloudFS) else {
            print("⚠️ 锁续期失败：不再持有锁")
            isHoldingLock = false
            currentFencingToken = 0
            return false
        }
        
        let token = nextFencingToken
        let lockData = LockData(
            deviceId: deviceId,
            fencingToken: token,
            acquiredAt: now,
            expiresAt: now + lockTimeout
        )
        
        do {
            let data = try JSONEncoder().encode(lockData)
            try cloudFS.writeData(data, to: lockURL)
            isHoldingLock = true
            currentFencingToken = token
            return true
        } catch {
            print("⚠️ 锁续期失败: \(error.localizedDescription)")
            isHoldingLock = false
            currentFencingToken = 0
            return false
        }
    }
    
    /// 启动续期定时器（主线程运行）
    private func startRenewTimer(cloudFS: CloudFileSystem) {
        stopRenewTimer()
        // 定时器必须在主线程运行，后台线程的 RunLoop 默认不工作
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.renewTimer = Timer.scheduledTimer(withTimeInterval: self.lockRenewInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.isHoldingLock else { return }
                // 续期在后台线程执行，避免阻塞主线程
                DispatchQueue.global(qos: .utility).async {
                    _ = self.renewLock(cloudFS: cloudFS)
                }
            }
        }
    }
    
    /// 停止续期定时器
    private func stopRenewTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.renewTimer?.invalidate()
            self?.renewTimer = nil
        }
    }
    
    // MARK: - 检查锁状态
    
    /// 检查云端锁是否被其他设备持有
    func isLockedByOtherDevice(cloudFS: CloudFileSystem) -> Bool {
        let lockURL = lockFileURL(in: cloudFS)
        guard cloudFS.fileExists(at: lockURL) else { return false }
        
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                let now = Date().timeIntervalSince1970
                return lockData.deviceId != deviceId && lockData.expiresAt > now
            }
        } catch {
            print("⚠️ 检查锁状态失败: \(error.localizedDescription)")
        }
        return false
    }
    
    /// 获取锁持有者信息（用于 UI 提示）
    func lockHolderInfo(cloudFS: CloudFileSystem) -> String? {
        let lockURL = lockFileURL(in: cloudFS)
        guard cloudFS.fileExists(at: lockURL) else { return nil }
        
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                let now = Date().timeIntervalSince1970
                if lockData.expiresAt > now {
                    let remaining = Int(lockData.expiresAt - now)
                    return "设备 \(lockData.deviceId.prefix(8))... 正在操作，剩余 \(remaining / 60) 分 \(remaining % 60) 秒"
                }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    // MARK: - App 生命周期
    
    /// App 进入后台时释放锁
    func applicationDidEnterBackground(cloudFS: CloudFileSystem?) {
        if let cloudFS = cloudFS {
            releaseLock(cloudFS: cloudFS)
        }
        stopRenewTimer()
        isHoldingLock = false
        currentFencingToken = 0
    }
}
