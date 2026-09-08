//
//  CloudLockService.swift
//  AnkiNotes
//
//  云端存储读写锁服务
//  通过云端 .lock 文件实现多端互斥，避免数据冲突
//

import Foundation

/// 云端锁服务
/// 使用云端 .metadata/.lock 文件实现分布式互斥锁
/// - 锁有过期时间，防止设备异常退出导致死锁
/// - 只有锁持有者才能释放锁
/// - 长时间操作可续期
final class CloudLockService {
    static let shared = CloudLockService()
    
    /// 锁过期时间（秒）
    private let lockTimeout: TimeInterval = 300  // 5 分钟
    
    /// 锁续期间隔（秒）
    private let lockRenewInterval: TimeInterval = 120  // 2 分钟
    
    /// 当前是否持有锁
    private(set) var isHoldingLock = false
    
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
        let acquiredAt: TimeInterval
        let expiresAt: TimeInterval
    }
    
    // MARK: - 获取锁
    
    /// 尝试获取云端锁
    /// - Parameter cloudFS: 云端文件系统
    /// - Returns: 是否成功获取锁
    @discardableResult
    func acquireLock(cloudFS: CloudFileSystem) -> Bool {
        // 如果已经持有锁，直接返回
        if isHoldingLock {
            return true
        }
        
        let lockURL = lockFileURL(in: cloudFS)
        let now = Date().timeIntervalSince1970
        
        // 1. 检查锁是否存在
        if cloudFS.fileExists(at: lockURL) {
            do {
                let data = try cloudFS.readData(at: lockURL)
                if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                    // 检查锁是否过期
                    if lockData.expiresAt > now {
                        // 锁未过期，且不是自己持有的，获取失败
                        if lockData.deviceId != deviceId {
                            print("🔒 云端锁被其他设备持有: \(lockData.deviceId.prefix(8))...，过期时间: \(Date(timeIntervalSince1970: lockData.expiresAt))")
                            return false
                        }
                        // 是自己持有的锁，续期
                        return renewLock(cloudFS: cloudFS)
                    }
                    // 锁已过期，可以强制获取
                    print("🔓 云端锁已过期，强制获取")
                }
            } catch {
                print("⚠️ 读取锁文件失败，尝试强制获取: \(error.localizedDescription)")
            }
        }
        
        // 2. 创建锁文件
        let lockData = LockData(
            deviceId: deviceId,
            acquiredAt: now,
            expiresAt: now + lockTimeout
        )
        
        do {
            let data = try JSONEncoder().encode(lockData)
            try cloudFS.writeData(data, to: lockURL)
            isHoldingLock = true
            startRenewTimer(cloudFS: cloudFS)
            print("✅ 获取云端锁成功: \(deviceId.prefix(8))...")
            return true
        } catch {
            print("❌ 获取云端锁失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 释放锁
    
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
                if let lockData = try? JSONDecoder().decode(LockData.self, from: data),
                   lockData.deviceId == deviceId {
                    try cloudFS.removeItem(at: lockURL)
                    print("🔓 释放云端锁成功")
                } else {
                    print("⚠️ 锁不是当前设备持有，不释放")
                }
            } catch {
                print("⚠️ 释放锁失败: \(error.localizedDescription)")
            }
        }
        
        isHoldingLock = false
    }
    
    // MARK: - 锁续期
    
    /// 续期锁（延长过期时间）
    @discardableResult
    private func renewLock(cloudFS: CloudFileSystem) -> Bool {
        let lockURL = lockFileURL(in: cloudFS)
        let now = Date().timeIntervalSince1970
        
        let lockData = LockData(
            deviceId: deviceId,
            acquiredAt: now,
            expiresAt: now + lockTimeout
        )
        
        do {
            let data = try JSONEncoder().encode(lockData)
            try cloudFS.writeData(data, to: lockURL)
            isHoldingLock = true
            return true
        } catch {
            print("⚠️ 锁续期失败: \(error.localizedDescription)")
            isHoldingLock = false
            return false
        }
    }
    
    /// 启动续期定时器
    private func startRenewTimer(cloudFS: CloudFileSystem) {
        stopRenewTimer()
        renewTimer = Timer.scheduledTimer(withTimeInterval: lockRenewInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isHoldingLock else { return }
            self.renewLock(cloudFS: cloudFS)
        }
    }
    
    /// 停止续期定时器
    private func stopRenewTimer() {
        renewTimer?.invalidate()
        renewTimer = nil
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
    }
}
