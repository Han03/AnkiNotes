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
    private let lockTimeout: TimeInterval = 20  // 20秒
    
    /// 锁续期间隔（秒）
    private let lockRenewInterval: TimeInterval = 18  // 18秒（小于过期时间20秒，保证续期及时）
    
    /// 当前是否持有锁
    private(set) var isHoldingLock = false
    
    /// 当前持有的 fencing token（单调递增，用于验证锁的有效性）
    private(set) var currentFencingToken: Int64 = 0
    
    /// 锁续期定时器
    private var renewTimer: Timer?
    
    /// 设备唯一标识（持久化到 Keychain，App 重装后保持不变）
    private var deviceId: String {
        if let id = KeychainHelper.get(forAccount: "CloudLockDeviceId") {
            return id
        }
        let id = UUID().uuidString
        KeychainHelper.save(id, forAccount: "CloudLockDeviceId")
        return id
    }
    
    /// fencing token 计数器（持久化到 Keychain，保证单调递增，App 重装后不重置）
    private var nextFencingToken: Int64 {
        let current = Int64(KeychainHelper.get(forAccount: "CloudLockFencingToken") ?? "0") ?? 0
        let next = current + 1
        KeychainHelper.save("\(next)", forAccount: "CloudLockFencingToken")
        return next
    }
    
    private init() {}
    
    // MARK: - 锁文件路径
    
    private func lockFileURL(in cloudFS: CloudFileSystem) -> URL {
        // 锁文件放在根目录下
        // 注意：文件名不能以 . 开头，否则坚果云 WebDAV 无法正确访问隐藏文件
        // 之前使用 .ankinotes.alock（以.开头是隐藏文件），导致 fileExists 永远返回 false，获取锁死循环
        // 改为 ankinotes.alock（非隐藏文件），坚果云 WebDAV 可以正常访问
        return cloudFS.rootDirectory.appendingPathComponent("ankinotes.alock")
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
        // 注意：不使用 fileExists（PROPFIND），因为坚果云 WebDAV 的 PROPFIND 可能无法正确检测根目录文件
        // 直接尝试 readData（GET），读取成功说明文件存在，读取失败说明文件不存在
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                // 检查锁是否过期
                if lockData.expiresAt > now {
                    // 锁未过期
                    if lockData.deviceId == deviceId {
                        // 是自己持有的锁
                        if lockData.fencingToken == currentFencingToken && currentFencingToken > 0 {
                            // token 匹配，正常续期
                            return renewLock(cloudFS: cloudFS)
                        } else {
                            // token 不匹配，说明是之前未正确释放的锁（如续期失败导致 token 被重置）
                            // 强制删除旧锁，然后重新创建
                            print("⚠️ 发现自己的旧锁但 token 不匹配（云端: \(lockData.fencingToken), 本地: \(currentFencingToken)），强制删除后重新获取")
                            try? cloudFS.removeItem(at: lockURL)
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    } else {
                        // 被其他设备持有，获取失败
                        print("🔒 云端锁被设备 \(lockData.deviceId.prefix(8))... 持有，过期时间: \(Date(timeIntervalSince1970: lockData.expiresAt))")
                        return false
                    }
                } else {
                    // 锁已过期，可以强制获取
                    print("🔓 云端锁已过期（token: \(lockData.fencingToken)），强制获取")
                    // 删除过期的锁文件
                    try? cloudFS.removeItem(at: lockURL)
                    Thread.sleep(forTimeInterval: 0.1)
                }
            } else {
                // 锁文件无法解析，可能是损坏的，强制删除
                print("⚠️ 锁文件无法解析，强制删除")
                try? cloudFS.removeItem(at: lockURL)
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch {
            // 读取锁文件失败，说明文件不存在，继续创建
            print("📝 锁文件不存在（读取失败），准备创建新锁: \(error.localizedDescription)")
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
            
            // 先设置 currentFencingToken（必须在 verifyLockOwnership 之前）
            currentFencingToken = token
            isHoldingLock = true
            
            // 3. 二次确认：读取锁文件，确认是自己的
            Thread.sleep(forTimeInterval: 0.1)  // 短暂等待，确保写入完成
            if !verifyLockOwnership(cloudFS: cloudFS) {
                print("⚠️ 二次确认失败，锁可能被抢占")
                isHoldingLock = false
                currentFencingToken = 0
                return false
            }
            
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
        
        // 只验证 deviceId，不验证 fencingToken
        // 原因：fencingToken 可能因为续期失败等原因被重置为 0，导致验证失败，锁文件无法删除
        // 只要是自己设备创建的锁，就应该可以删除
        // 注意：不使用 fileExists（PROPFIND），因为坚果云 WebDAV 的 PROPFIND 可能无法正确检测根目录文件
        // 直接尝试 readData（GET），读取成功说明文件存在，读取失败说明文件不存在
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                if lockData.deviceId == deviceId {
                    // 确认是自己的锁，删除
                    try cloudFS.removeItem(at: lockURL)
                    
                    // 二次确认：尝试读取，如果读取失败说明删除成功
                    Thread.sleep(forTimeInterval: 0.1)
                    do {
                        _ = try cloudFS.readData(at: lockURL)
                        print("⚠️ 锁文件删除后仍然存在，可能有并发问题")
                    } catch {
                        print("🔓 释放云端锁成功 (token: \(currentFencingToken))")
                    }
                } else {
                    print("⚠️ 锁不是当前设备持有（deviceId 不匹配），不释放")
                }
            } else {
                // 锁文件无法解析，可能是损坏的，强制删除
                print("⚠️ 锁文件无法解析，强制删除")
                try? cloudFS.removeItem(at: lockURL)
            }
        } catch {
            // 读取失败，说明锁文件不存在，直接重置状态
            print("📝 释放锁时锁文件不存在（读取失败），直接重置状态: \(error.localizedDescription)")
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
        
        // 注意：不使用 fileExists（PROPFIND），因为坚果云 WebDAV 的 PROPFIND 可能无法正确检测根目录文件
        // 直接尝试 readData（GET），读取成功说明文件存在，读取失败说明文件不存在
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
            // 读取失败，说明锁文件不存在
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
        if !verifyLockOwnership(cloudFS: cloudFS) {
            // 验证失败，检查是否是自己的锁但 token 不匹配
            if cloudFS.fileExists(at: lockURL) {
                do {
                    let data = try cloudFS.readData(at: lockURL)
                    if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                        if lockData.deviceId == deviceId {
                            // 是自己的锁但 token 不匹配，强制删除旧锁后重新创建
                            print("⚠️ 续期时发现自己的锁但 token 不匹配（云端: \(lockData.fencingToken), 本地: \(currentFencingToken)），强制删除后重新获取")
                            try? cloudFS.removeItem(at: lockURL)
                            Thread.sleep(forTimeInterval: 0.1)
                            // 重新创建锁
                            return acquireLock(cloudFS: cloudFS)
                        }
                    }
                } catch {
                    print("⚠️ 续期时读取锁文件失败: \(error.localizedDescription)")
                }
            }
            print("⚠️ 锁续期失败：不再持有锁")
            isHoldingLock = false
            currentFencingToken = 0
            stopRenewTimer()  // 续期失败，停止续期定时器
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
            stopRenewTimer()  // 续期失败，停止续期定时器
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
        // 注意：不使用 fileExists（PROPFIND），直接尝试 readData（GET）
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                let now = Date().timeIntervalSince1970
                return lockData.deviceId != deviceId && lockData.expiresAt > now
            }
        } catch {
            // 读取失败，说明锁文件不存在
            return false
        }
        return false
    }
    
    /// 获取锁持有者信息（用于 UI 提示）
    func lockHolderInfo(cloudFS: CloudFileSystem) -> String? {
        let lockURL = lockFileURL(in: cloudFS)
        // 注意：不使用 fileExists（PROPFIND），直接尝试 readData（GET）
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
    
    /// 获取锁文件的详细信息（用于日志记录）
    func lockDebugInfo(cloudFS: CloudFileSystem) -> String {
        let lockURL = lockFileURL(in: cloudFS)
        var info = "当前状态: isHoldingLock=\(isHoldingLock), currentFencingToken=\(currentFencingToken), deviceId=\(deviceId.prefix(8))...; 锁文件URL: \(lockURL.absoluteString); "
        
        // 注意：不使用 fileExists（PROPFIND），直接尝试 readData（GET）
        do {
            let data = try cloudFS.readData(at: lockURL)
            if let lockData = try? JSONDecoder().decode(LockData.self, from: data) {
                let now = Date().timeIntervalSince1970
                let isExpired = lockData.expiresAt <= now
                let isOwn = lockData.deviceId == deviceId
                let tokenMatch = lockData.fencingToken == currentFencingToken
                info += "云端锁文件: deviceId=\(lockData.deviceId.prefix(8))..., fencingToken=\(lockData.fencingToken), expiresAt=\(lockData.expiresAt), 已过期=\(isExpired), 是自己的=\(isOwn), token匹配=\(tokenMatch)"
            } else {
                info += "云端锁文件: 无法解析"
            }
        } catch {
            info += "云端锁文件: 不存在或读取失败 - \(error.localizedDescription)"
        }
        return info
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
