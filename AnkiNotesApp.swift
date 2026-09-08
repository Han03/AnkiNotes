//
//  AnkiNotesApp.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

@main
struct AnkiNotesApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                // 注入全局文字缩放倍率 → 所有 .textStyle() modifier 自动生效
                .environment(\.textScale, appState.textScale)
                .onAppear {
                    appState.bootstrap()
                    // 应用启动时后台静默同步
                    appState.performSilentSyncOnLaunch()
                }
                .onChange(of: scenePhase) { newPhase in
                    // App 进入后台时释放云端锁，防止死锁
                    if newPhase == .background {
                        if let fs = appState.activeFS {
                            CloudLockService.shared.applicationDidEnterBackground(cloudFS: fs)
                        }
                    }
                }
        }
    }
}

// MARK: - 环境键：全局文字缩放（由 .textStyle() 读取）
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}
extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

// MARK: - 全局应用状态
@MainActor
final class AppState: ObservableObject {

    // MARK: - 核心服务

    private(set) var activeFS: CloudFileSystem!    // 当前生效的 Provider 后端（用于显示位置）
    private(set) var webDAVFS: WebDAVFS?          // WebDAV 同步实例（仅用于云端同步）
    private let syncLock = NSLock()                 // 同步锁，防止重复执行同步操作
    private(set) var fileSystem: FileSystemService!
    @Published var storage: StorageService!
    @Published var scheduler: SchedulerService!
    @Published var isBootstrapped = false

    // MARK: - 统计
    @Published var todayDueCount: Int = 0
    @Published var totalNotes:   Int = 0
    @Published var totalFolders: Int = 0

    /// 主 Tabs 的选中索引（0 笔记 / 1 复习 / 2 统计 / 3 设置），方便 StatsView 页面内部「前往设置」按钮直接切 Tab
    @Published var mainTabIndex: Int = 0

    // MARK: - Provider 选择 & 配置（持久化）

    /// 内部回退保护标志：当同步修改 selectedProvider 但不代表"切换 Provider" 时（如仅占位选中
    /// WebDAV 以便显示表单），阻止 didSet 再次触发切换逻辑。
    private var suppressProviderDidSet = false

    @Published var selectedProvider: CloudProviderType = .local {
        didSet {
            // 先判"保护性切换"：占位选 WebDAV（为显示表单）/ UI 手动撤回时不切实际后端
            guard !suppressProviderDidSet else { return }
            guard isBootstrapped else { return }
            guard oldValue != selectedProvider else { return }
            // 切换同步：Local/iCloud 立即生效；WebDAV 只占位 + 警示，等填好表单点 💾保存再真生效
            applyCurrentProviderSelection(allowWebDAVIncomplete: true)
        }
    }

    @Published var webDAVConfig: WebDAVConfig = WebDAVConfig() {
        didSet {
            Self.saveWebDAVConfigToDefaults(webDAVConfig)
        }
    }

    /// 用户设置的 WebDAV 「临时密码」（未保存前 UI 编辑用，保存时通过 KeychainHelper 写入 Keychain）
    @Published var pendingWebDAVPassword: String = ""

    // MARK: - 百炼平台配置
    @Published var bailianConfig: BailianConfig = BailianConfig() {
        didSet {
            if let data = try? JSONEncoder().encode(bailianConfig) {
                UserDefaults.standard.set(data, forKey: Self.keyBailianConfig)
            }
        }
    }
    private static let keyBailianConfig = "bailian_config"

    // MARK: - TTS 语音合成配置
    @Published var ttsConfig: TTSConfig = TTSConfig() {
        didSet {
            if let data = try? JSONEncoder().encode(ttsConfig) {
                UserDefaults.standard.set(data, forKey: Self.keyTTSConfig)
            }
            TTSService.shared.updateConfig(ttsConfig)
        }
    }
    private static let keyTTSConfig = "tts_config"

    // MARK: - 题库
    private(set) var quizService: QuizService!
    private(set) var syncSnapshotService: SyncSnapshotService!
    @Published var isGeneratingQuestions = false
    @Published var generationProgress: (current: Int, total: Int, noteTitle: String)?
    @Published var quizError: String? = nil  // 生成题目报错信息

    @Published var providerStatus: String? = nil
    @Published var iCloudContainerAvailable: Bool = false
    @Published var isSyncing: Bool = false  // ✅ 正在同步/导入中（UI 显示加载提示）
    @Published var isSilentSyncing: Bool = false  // 后台静默同步中（不显示 UI 提示）
    @Published var syncProgress: Double = 0  // 同步进度 0-100
    @Published var syncStep: String = ""  // 当前同步步骤
    @Published var syncDetail: String = ""  // 同步详情

    // MARK: - 全局文字缩放倍率

    static let textScaleOptions: [Double] = [0.85, 1.0, 1.15, 1.3]
    static let textScaleLabels: [String] = ["较小", "标准", "较大", "超大"]

    @Published var textScale: Double = 1.0 {
        didSet {
            guard isBootstrapped else { return }
            UserDefaults.standard.set(textScale, forKey: Self.keyTextScale)
            // 写环境值虽然通过 StateObject 触发，但我们确保 Observable 发布
            objectWillChange.send()
        }
    }

    var textScaleLabel: String {
        if let idx = Self.textScaleOptions.firstIndex(of: textScale) {
            return Self.textScaleLabels[idx]
        }
        return String(format: "%.0f%%", textScale * 100)
    }

    // MARK: - 持久化 Keys

    private static let keyProviderType = "AnkiNotes.ProviderType"
    private static let keyWebDAVConfig = "AnkiNotes.WebDAVConfig"
    private static let keyTextScale     = "AnkiNotes.TextScale"

    // MARK: - 启动
    // 注意：bootstrap 是同步方法，确保 MainTabView Preview 与 App.init 里都能直接调用，
    // 避免 Swift 宏展开为 @__swiftmacro…PreviewfMf_.swift 时报出 "'async' call in a function that does not support concurrency"。
    // WebDAV 测试连接这类真正需要 async 的场景已独立为 testCurrentWebDAVConnection() async。
    func bootstrap() {
        // 1) 恢复上次选择的 Provider
        if let raw = UserDefaults.standard.string(forKey: Self.keyProviderType),
           let t = CloudProviderType(rawValue: raw) {
            selectedProvider = t
        } else {
            selectedProvider = .local
        }
        // 2) 恢复 WebDAV 配置 & 密码
        webDAVConfig = Self.loadWebDAVConfigFromDefaults()
        pendingWebDAVPassword = KeychainHelper.webDAVPassword() ?? ""
        // 加载百炼配置
        if let data = UserDefaults.standard.data(forKey: Self.keyBailianConfig),
           let cfg = try? JSONDecoder().decode(BailianConfig.self, from: data) {
            bailianConfig = cfg
        }
        // 加载 TTS 配置
        if let data = UserDefaults.standard.data(forKey: Self.keyTTSConfig),
           let cfg = try? JSONDecoder().decode(TTSConfig.self, from: data) {
            ttsConfig = cfg
        }
        TTSService.shared.updateConfig(ttsConfig)
        // 3) 恢复文字大小
        let storedScale = UserDefaults.standard.double(forKey: Self.keyTextScale)
        textScale = (storedScale > 0.1 && storedScale < 5) ? storedScale : 1.0
        // 4) 创建当前 Provider 对应 CloudFileSystem，并组装 FileSystem + Storage + Scheduler
        applyFileSystem(type: selectedProvider, webDAVConfig: webDAVConfig, migrateFromScratch: false)
        // 5) 状态初值
        iCloudContainerAvailable = (activeFS as? ICloudFS)?.isAvailable ?? false
        providerStatus = summarizeStatus()
        refreshStats()
        // 6) 后台异步从云端拉取元数据和知识点缓存到本地
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let fs = self.activeFS else { return }
            let pulled = MetadataSyncService.shared.pullFromCloud(cloudFS: fs)
            if pulled > 0 {
                print("📥 启动时元数据同步: 拉取 \(pulled) 个文件")
                DispatchQueue.main.async {
                    self.storage.reloadFromCache()
                    self.quizService.reloadFromCache()
                    self.refreshStats()
                }
            }
            // 拉取知识点缓存
            let knowledgePulled = MetadataSyncService.shared.pullKnowledgeCache(cloudFS: fs)
            if knowledgePulled > 0 {
                print("📥 启动时知识点缓存同步: 拉取 \(knowledgePulled) 个文件")
            }
        }
        isBootstrapped = true
    }

    func refreshStats() {
        todayDueCount = scheduler.getTodayDueCount()
        let allNotes = storage.getAllNotes()
        let allFolders = storage.getAllFolders()
        totalNotes   = allNotes.count
        totalFolders = allFolders.count
        // 更新 quizService 的笔记和文件夹列表（用于按文件夹结构存储题目）
        quizService?.updateNotes(allNotes, folders: allFolders)
    }

    // MARK: - Provider 切换（UI 交互主入口）

    /// UI 通过 Picker 选择 / 或者 💾保存按钮点下时调用。
    /// - 参数 allowWebDAVIncomplete：
    ///   * true = 用户刚从 Picker 选到 WebDAV（只是占位显示表单），密码/地址不完整也允许
    ///            "选中" WebDAV，只是 providerStatus 给红字警示，不真正重写 activeFS 与索引服务；
    ///            这样就能做到"先切 Picker → 立刻显示配置表单 → 再填密码 → 最后点保存应用"的 UX。
    ///   * false= 来自「💾保存并应用 WebDAV 配置」按钮点下，此时要求地址/用户名/密码齐全；
    ///            任何缺失都直接返回 false，给 UI 红字。
    /// - 返回：应用是否真正成功把 activeFS 写为用户选择的后端（Local/iCloud 直接 true；
    ///          WebDAV 只有 allowWebDAVIncomplete=false 且通过校验时才 true）。
    @discardableResult
    func applyCurrentProviderSelection(allowWebDAVIncomplete: Bool) -> Bool {
        let type = selectedProvider
        // 保存选择（始终持久化，用户下次打开就知道选的是什么）
        UserDefaults.standard.set(type.rawValue, forKey: Self.keyProviderType)

        switch type {
        case .local, .iCloud:
            applyFileSystem(type: type, webDAVConfig: webDAVConfig, migrateFromScratch: true)
            iCloudContainerAvailable = (activeFS as? ICloudFS)?.isAvailable ?? false
            providerStatus = summarizeStatus()
            return true

        case .webDAV:
            // 1) 如果 pending 有密码就写 Keychain（允许用户填完后直接点保存 / 也可以先写密码再保存）
            let pendingPwd = pendingWebDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingPwd.isEmpty {
                do {
                    try KeychainHelper.setWebDAVPassword(pendingPwd)
                } catch {
                    providerStatus = "❌ WebDAV 密码保存到 Keychain 失败：\(error.localizedDescription)"
                    return false
                }
            }

            // 2) 判断配置 & 密码是否齐全
            let finalPwd = (pendingPwd.isEmpty ? KeychainHelper.webDAVPassword() : pendingPwd) ?? ""
            let complete = webDAVConfig.isComplete && !finalPwd.isEmpty

            guard complete else {
                // 选先占位：让 Picker 留在 WebDAV，显示表单 + 红警示文字，提醒用户填完点 💾保存。
                // 重要：绝对不要把 selectedProvider 改回旧值！
                //        也不要重写 activeFS（storage/scheduler 仍指向旧后端，直到用户真正保存为止）。
                let missing: [String] = [
                    webDAVConfig.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "服务器地址" : nil,
                    webDAVConfig.username.isEmpty ? "用户名" : nil,
                    finalPwd.isEmpty ? "密码（应用专用密码）" : nil
                ].compactMap { $0 }
                if allowWebDAVIncomplete {
                    // Picker 占位模式：只给警示，返回 false（没真正切到 WebDAV 后端）
                    providerStatus = """
                    ⚠️ WebDAV 配置还没写完（缺：\(missing.joined(separator: "、"))）。
                    🆕 先把 Picker 留在 WebDAV → 请在下方把缺少的项填好 → 再点「💾保存并应用 WebDAV 配置」按钮即可生效并开始迁移。
                    提示：密码推荐点「🔗测试连接」先确认能连通，通过后再点保存，万无一失。
                    """
                    // **不做任何回退**：保持 selectedProvider==.webDAV，让表单显示出来。
                    return false
                } else {
                    // 用户强制点了 💾保存：明确缺失项
                    providerStatus = "❌ 还不能保存：缺少 \(missing.joined(separator: "、"))，请补齐后重试。"
                    return false
                }
            }

            // 3) 齐全 → 持久化配置 + 真正做后端迁移 + 重建 Storage/Scheduler 服务
            Self.saveWebDAVConfigToDefaults(webDAVConfig)
            applyFileSystem(type: .webDAV, webDAVConfig: webDAVConfig, migrateFromScratch: true)
            iCloudContainerAvailable = false
            providerStatus = summarizeStatus()
            return true
        }
    }

    /// UI 快速入口：用户在 Settings 表单下方点「💾保存并应用 WebDAV 配置」时调用。
    /// 等同于 allowWebDAVIncomplete=false，且要求一定是用户在 UI 侧已经把 Picker 选到了 WebDAV。
    @discardableResult
    func saveAndApplyWebDAV() -> Bool {
        if selectedProvider != .webDAV {
            suppressProviderDidSet = true
            selectedProvider = .webDAV
            suppressProviderDidSet = false
        }
        let ok = applyCurrentProviderSelection(allowWebDAVIncomplete: false)
        // 保存配置后不自动同步，用户在笔记页下拉才触发同步
        if ok {
            providerStatus = "✅ WebDAV 配置已保存。请到笔记页下拉同步，从云端拉取笔记。"
        }
        return ok
    }

    /// UI 点「🔗 测试连接」按钮（WebDAV）
    func testCurrentWebDAVConnection() async -> (success: Bool, message: String) {
        let cfg = webDAVConfig
        var usePassword = pendingWebDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if usePassword.isEmpty { usePassword = KeychainHelper.webDAVPassword() ?? "" }
        guard !cfg.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cfg.username.isEmpty, !usePassword.isEmpty else {
            return (false, "地址/用户名/密码不能为空")
        }
        do { try KeychainHelper.setWebDAVPassword(usePassword) }
        catch { return (false, "Keychain 临时密码失败：\(error.localizedDescription)") }

        let fs = CloudProviderFactory.makeFileSystem(for: .webDAV, webDAVConfig: cfg)
        let root = fs.rootDirectory
        do {
            let exists: Bool = try fs.fileExists(at: root)
            if exists {
                return (true, "✅ 连接成功，根目录可访问：\(fs.displayLocation)")
            } else {
                do {
                    try fs.createDirectoryIfNeeded(at: root)
                    return (true, "✅ 连接成功，根目录不存在已自动创建：\(fs.displayLocation)")
                } catch {
                    return (false, "❌ 连接成功但根目录创建失败：\(error.localizedDescription)。请检查路径是否有写入权限，或手动在坚果云创建对应目录")
                }
            }
        } catch {
            return (false, "❌ 连接失败：\(error.localizedDescription)")
        }
    }

    /// 从云端同步笔记到本地（下拉刷新触发，全局唯一同步入口）
    /// - 加锁防止重复执行
    /// - 后台线程扫描云端 Notes 目录，下载新笔记到本地
    /// - 去重：同文件夹+同标题跳过
    func syncFromCloud(silent: Bool = false, completion: ((StorageService.ImportReport) -> Void)? = nil) {
        guard webDAVFS != nil else {
            if !silent {
                providerStatus = "⚠️ 未配置 WebDAV，无法同步。请到设置页配置 WebDAV。"
            }
            completion?(StorageService.ImportReport())
            return
        }
        // 加锁：同步操作进行中时拒绝重复执行
        guard syncLock.try() else {
            print("⚠️ 同步正在进行中，跳过重复请求")
            return
        }
        // 静默同步和非静默同步都显示相同的 UI 内容
        if silent {
            isSilentSyncing = true
        } else {
            isSyncing = true
        }
        // 立即显示准备同步状态（静默同步也显示）
        syncStep = "准备同步"
        syncProgress = 0
        syncDetail = "正在初始化同步..."
        
        // 启动同步日志会话
        SyncLogger.shared.startSession()
        SyncLogger.shared.info("同步开始，silent=\(silent)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let syncStartTime = Date()
            defer {
                let syncDuration = Date().timeIntervalSince(syncStartTime)
                SyncLogger.shared.info("同步结束，总耗时 \(String(format: "%.2f", syncDuration))秒")
                SyncLogger.shared.endSession()
                
                self.syncLock.unlock()
                // 释放云端锁（如果还持有锁的话）
                if let fs = self.activeFS, CloudLockService.shared.isHoldingLock {
                    SyncLogger.shared.warning("同步结束时仍持有云端锁，强制释放")
                    CloudLockService.shared.releaseLock(cloudFS: fs)
                }
                // 清除进度回调
                self.storage.syncProgressCallback = nil
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.isSilentSyncing = false
                    self.syncProgress = 0
                    self.syncStep = ""
                    self.syncDetail = ""
                    self.refreshStats()
                    self.storage.triggerRefresh()
                }
            }
            // 获取云端锁（防止多端同时同步），若被占用则每隔5秒重试直到成功
            guard let fs = self.activeFS else {
                completion?(StorageService.ImportReport())
                return
            }
            // 显示正在获取云端锁（静默同步也显示）
            DispatchQueue.main.async {
                self.syncStep = "获取云端锁"
                self.syncProgress = 1
                self.syncDetail = "正在获取云端分布式锁..."
            }
            SyncLogger.shared.stepStart("获取云端锁")
            let lockStartTime = Date()
            var lockAcquired = false
            var retryCount = 0
            while !lockAcquired {
                SyncLogger.shared.debug("尝试获取云端锁，第 \(retryCount + 1) 次")
                lockAcquired = CloudLockService.shared.acquireLock(cloudFS: fs)
                if !lockAcquired {
                    retryCount += 1
                    let holderInfo = CloudLockService.shared.lockHolderInfo(cloudFS: fs)
                    let debugInfo = CloudLockService.shared.lockDebugInfo(cloudFS: fs)
                    SyncLogger.shared.warning("获取云端锁失败，第 \(retryCount) 次重试，holderInfo=\(holderInfo ?? "无")。\(debugInfo)")
                    // 更新提示信息，保持同步窗口打开（静默同步也显示）
                    if let holderInfo = holderInfo {
                        DispatchQueue.main.async {
                            self.providerStatus = "⏳ 其他设备正在同步，等待中...（已等待 \(retryCount * 5)秒）\n\(holderInfo)\n\n将自动重试，无需关闭窗口"
                            self.syncStep = "等待云端锁"
                            self.syncProgress = 1
                            self.syncDetail = "其他设备正在同步，已等待 \(retryCount * 5)秒"
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.providerStatus = "⏳ 等待云端锁释放...（已等待 \(retryCount * 5)秒）\n\n将自动重试，无需关闭窗口"
                            self.syncStep = "等待云端锁"
                            self.syncProgress = 1
                            self.syncDetail = "等待云端锁释放，已等待 \(retryCount * 5)秒"
                        }
                    }
                    // 等待5秒后重试
                    Thread.sleep(forTimeInterval: 5)
                }
            }
            let lockDuration = Date().timeIntervalSince(lockStartTime)
            SyncLogger.shared.stepDone("获取云端锁", duration: lockDuration)
            SyncLogger.shared.info("获取云端锁成功，重试 \(retryCount) 次，耗时 \(String(format: "%.2f", lockDuration))秒")
            DispatchQueue.main.async {
                self.providerStatus = "✅ 获取云端锁成功，开始同步..."
                self.syncStep = "获取云端锁"
                self.syncProgress = 2
                self.syncDetail = "锁获取成功，开始同步"
            }
            // 设置同步进度回调
            self.storage.syncProgressCallback = { [weak self] step, progress, detail in
                DispatchQueue.main.async {
                    self?.syncStep = step
                    self?.syncProgress = progress
                    self?.syncDetail = detail
                }
            }
            
            // 【第1级：根目录级跳过】检查根目录修改时间，如果无更新，直接跳过整个同步
            SyncLogger.shared.stepStart("检查根目录更新状态")
            if self.syncSnapshotService.hasSnapshot {
                do {
                    let rootMeta = try fs.getItemMetadata(at: fs.rootDirectory)
                    SyncLogger.shared.debug("根目录元数据: lastModified=\(rootMeta.lastModified)")
                    if !self.syncSnapshotService.isRootDirectoryUpdated(lastModified: rootMeta.lastModified) {
                        SyncLogger.shared.info("根目录无更新，跳过整个同步")
                        DispatchQueue.main.async {
                            self.providerStatus = "✅ 云端无更新，跳过同步"
                            self.syncStep = "同步完成"
                            self.syncProgress = 100
                            self.syncDetail = "根目录无更新，无需同步"
                        }
                        completion?(StorageService.ImportReport())
                        return
                    } else {
                        SyncLogger.shared.info("根目录有更新，开始同步")
                    }
                } catch {
                    SyncLogger.shared.error("无法获取根目录元数据，执行全量同步：\(error.localizedDescription)")
                }
            } else {
                SyncLogger.shared.info("无同步快照，执行全量同步")
            }
            SyncLogger.shared.stepDone("检查根目录更新状态")
            // 同步前：先备份本地 noteMetas（包含未同步的 SRS 复习记录）
            let localNoteMetasBackup = MetadataSyncService.shared.readLocalNoteMetas()
            SyncLogger.shared.info("备份本地 noteMetas: \(localNoteMetasBackup.count) 条")
            // 同步前：从云端拉取元数据和知识点缓存到本地缓存（不加载到内存）
            // 注意：不调用 reloadFromCache，避免云端索引提前加载导致 importFromCloud 全部判定为重复跳过
            DispatchQueue.main.async {
                self.syncStep = "拉取云端元数据"
                self.syncProgress = 3
                self.syncDetail = "正在从云端下载 .metadata..."
            }
            SyncLogger.shared.stepStart("拉取云端元数据")
            let metaPullStartTime = Date()
            let pulled = MetadataSyncService.shared.pullFromCloud(cloudFS: fs)
            let metaPullDuration = Date().timeIntervalSince(metaPullStartTime)
            SyncLogger.shared.stepDone("拉取云端元数据", duration: metaPullDuration)
            SyncLogger.shared.info("拉取云端元数据: \(pulled) 个文件，耗时 \(String(format: "%.2f", metaPullDuration))秒")
            // 智能合并 SRS 数据：基于 updatedAt 合并本地备份和云端数据，避免多端复习时覆盖
            if !localNoteMetasBackup.isEmpty {
                SyncLogger.shared.stepStart("智能合并 SRS 数据")
                let cloudNoteMetas = MetadataSyncService.shared.readLocalNoteMetas()
                SyncLogger.shared.debug("云端 noteMetas: \(cloudNoteMetas.count) 条")
                let mergedNoteMetas = MetadataSyncService.shared.mergeNoteMetas(local: localNoteMetasBackup, cloud: cloudNoteMetas)
                MetadataSyncService.shared.writeLocalNoteMetas(mergedNoteMetas)
                SyncLogger.shared.stepDone("智能合并 SRS 数据")
                SyncLogger.shared.info("SRS 数据合并完成: 本地 \(localNoteMetasBackup.count) 条，云端 \(cloudNoteMetas.count) 条，合并后 \(mergedNoteMetas.count) 条")
            } else {
                SyncLogger.shared.info("本地无 SRS 数据备份，跳过合并")
            }
            // 拉取知识点缓存
            DispatchQueue.main.async {
                self.syncStep = "拉取知识点缓存"
                self.syncProgress = 4
                self.syncDetail = "正在从云端下载 .knowledge_cache..."
            }
            SyncLogger.shared.stepStart("拉取知识点缓存")
            let knowledgePullStartTime = Date()
            let knowledgePulled = MetadataSyncService.shared.pullKnowledgeCache(cloudFS: fs)
            let knowledgePullDuration = Date().timeIntervalSince(knowledgePullStartTime)
            SyncLogger.shared.stepDone("拉取知识点缓存", duration: knowledgePullDuration)
            SyncLogger.shared.info("拉取知识点缓存: \(knowledgePulled) 个文件，耗时 \(String(format: "%.2f", knowledgePullDuration))秒")
            // 从云端扫描并导入到本地（此时内存中的索引为空，会创建所有笔记）
            SyncLogger.shared.stepStart("从云端导入数据（笔记/讲稿/题目）")
            let importStartTime = Date()
            let report = self.storage.importFromCloud()
            let importDuration = Date().timeIntervalSince(importStartTime)
            SyncLogger.shared.stepDone("从云端导入数据", duration: importDuration)
            SyncLogger.shared.info("导入完成: 扫描 \(report.scannedMarkdownFiles) 个笔记文件，新增 \(report.importedCount)，跳过 \(report.skippedCount)，失败 \(report.failedCount)，讲稿 \(report.lectureImportedCount) 个，耗时 \(String(format: "%.2f", importDuration))秒")
            // 云端读写完成，释放锁（本地处理不需要锁，缩短锁占用时间）
            CloudLockService.shared.releaseLock(cloudFS: fs)
            SyncLogger.shared.info("云端读写完成，释放锁，开始本地处理")
            DispatchQueue.main.async {
                self.syncStep = "本地处理"
                self.syncProgress = 90
                self.syncDetail = "正在更新本地索引..."
            }
            SyncLogger.shared.stepStart("本地处理 - 重新加载存储索引")
            let localProcessStartTime = Date()
            // 导入完成后，再从本地缓存加载元数据（合并本地和云端的索引）
            let reloadStart = Date()
            self.storage.reloadFromCache()
            SyncLogger.shared.debug("storage.reloadFromCache 完成，耗时 \(String(format: "%.2f", Date().timeIntervalSince(reloadStart)))秒")
            // 先更新 quizService 的笔记和文件夹列表，否则 reloadFromCache 时遍历空数组读不到题目
            let notes = self.storage.getAllNotes()
            let folders = self.storage.getAllFolders()
            SyncLogger.shared.debug("获取到 \(notes.count) 篇笔记，\(folders.count) 个文件夹")
            self.quizService.updateNotes(notes, folders: folders)
            // 重新加载题库缓存（这一步可能很耗时，记录详细日志）
            SyncLogger.shared.stepStart("本地处理 - 重新加载题库缓存（可能耗时较长）")
            let quizReloadStart = Date()
            self.quizService.reloadFromCache()
            let quizReloadDuration = Date().timeIntervalSince(quizReloadStart)
            SyncLogger.shared.stepDone("本地处理 - 重新加载题库缓存", duration: quizReloadDuration)
            SyncLogger.shared.info("题库缓存重新加载完成，耗时 \(String(format: "%.2f", quizReloadDuration))秒，题目总数: \(self.quizService.questions.count)")
            let localProcessDuration = Date().timeIntervalSince(localProcessStartTime)
            SyncLogger.shared.stepDone("本地处理", duration: localProcessDuration)
            SyncLogger.shared.info("本地处理完成，总耗时 \(String(format: "%.2f", localProcessDuration))秒")
            // 本地处理完成，重新获取锁用于推送云端
            SyncLogger.shared.stepStart("重新获取云端锁（用于推送数据）")
            var pushLockAcquired = false
            var pushRetryCount = 0
            while !pushLockAcquired {
                pushLockAcquired = CloudLockService.shared.acquireLock(cloudFS: fs)
                if !pushLockAcquired {
                    pushRetryCount += 1
                    let debugInfo = CloudLockService.shared.lockDebugInfo(cloudFS: fs)
                    SyncLogger.shared.warning("推送数据获取锁失败，第 \(pushRetryCount) 次重试。\(debugInfo)")
                    DispatchQueue.main.async {
                        self.providerStatus = "⏳ 等待云端锁释放以推送数据...（已等待 \(pushRetryCount * 5)秒）"
                        self.syncStep = "等待云端锁"
                        self.syncDetail = "正在等待其他设备完成同步..."
                    }
                    Thread.sleep(forTimeInterval: 5)
                }
            }
            SyncLogger.shared.stepDone("重新获取云端锁（用于推送数据）")
            SyncLogger.shared.info("重新获取云端锁成功，重试 \(pushRetryCount) 次，开始推送数据")
            // 同步后：推送本地元数据和知识点缓存到云端
            DispatchQueue.main.async {
                self.syncStep = "推送元数据到云端"
                self.syncProgress = 96
                self.syncDetail = "正在上传 .metadata 到云端..."
            }
            SyncLogger.shared.stepStart("推送元数据到云端")
            let metaPushStartTime = Date()
            let pushed = MetadataSyncService.shared.pushToCloud(cloudFS: fs)
            let metaPushDuration = Date().timeIntervalSince(metaPushStartTime)
            SyncLogger.shared.stepDone("推送元数据到云端", duration: metaPushDuration)
            SyncLogger.shared.info("推送元数据到云端: \(pushed) 个文件，耗时 \(String(format: "%.2f", metaPushDuration))秒")
            // 推送知识点缓存
            DispatchQueue.main.async {
                self.syncStep = "推送知识点缓存"
                self.syncProgress = 98
                self.syncDetail = "正在上传 .knowledge_cache 到云端..."
            }
            SyncLogger.shared.stepStart("推送知识点缓存到云端")
            let knowledgePushStartTime = Date()
            let knowledgePushed = MetadataSyncService.shared.pushKnowledgeCache(cloudFS: fs)
            let knowledgePushDuration = Date().timeIntervalSince(knowledgePushStartTime)
            SyncLogger.shared.stepDone("推送知识点缓存到云端", duration: knowledgePushDuration)
            SyncLogger.shared.info("推送知识点缓存到云端: \(knowledgePushed) 个文件，耗时 \(String(format: "%.2f", knowledgePushDuration))秒")
            // 同步完成后保存快照
            SyncLogger.shared.stepStart("保存同步快照")
            self.syncSnapshotService.save()
            SyncLogger.shared.stepDone("保存同步快照")
            SyncLogger.shared.info("同步快照已保存")
            
            DispatchQueue.main.async {
                // 静默同步也显示完成状态
                if report.scannedMarkdownFiles == 0 {
                    self.providerStatus = "⚠️ 云端 Notes 目录没有发现 .md 文件。请确认笔记放在了坚果云的 Notes/ 目录下。"
                } else {
                    var status = "✅ 同步完成：新增 \(report.importedCount)，跳过 \(report.skippedCount)，失败 \(report.failedCount)，扫描到 \(report.scannedMarkdownFiles) 个 .md 文件"
                    if report.scannedLectureFiles > 0 {
                        status += "，讲稿 \(report.lectureImportedCount) 个"
                    }
                    self.providerStatus = status
                }
                self.syncStep = "同步完成"
                self.syncProgress = 100
                self.syncDetail = "同步已完成"
                self.refreshStats()
                completion?(report)
            }
            SyncLogger.shared.info("同步流程全部完成")
        }
    }

    /// 异步导入 Markdown（保留兼容，内部调用 syncFromCloud）
    func importMarkdownAsync(completion: ((StorageService.ImportReport) -> Void)? = nil) {
        syncFromCloud(completion: completion)
    }

    /// 从云端同步单个笔记（打开编辑前调用，减少冲突）
    func syncSingleNote(noteId: UUID, completion: ((Bool) -> Void)? = nil) {
        guard webDAVFS != nil else {
            completion?(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.storage.syncSingleNoteFromCloud(noteId: noteId)
            DispatchQueue.main.async {
                if success {
                    self.storage.triggerRefresh()
                }
                completion?(success)
            }
        }
    }

    /// 上传单个笔记到云端（保存后调用）
    func uploadSingleNote(noteId: UUID, completion: ((Bool) -> Void)? = nil) {
        guard webDAVFS != nil else {
            completion?(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.storage.uploadSingleNoteToCloud(noteId: noteId)
            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }

    /// 应用启动时后台静默同步（延迟 2 秒执行，不阻塞 UI）
    func performSilentSyncOnLaunch() {
        guard webDAVFS != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            // 如果已经在同步，不重复执行
            guard !self.isSyncing && !self.isSilentSyncing else { return }
            self.syncFromCloud(silent: true)
        }
    }

    // MARK: - 题库生成

    /// 为所有未生成题目的笔记生成题目（后台异步，每完成一个笔记立即保存）
    func generateQuestionsForAllNotes(completion: ((Int, Int, Bool) -> Void)? = nil) {
        guard bailianConfig.isConfigured else {
            print("⚠️ 百炼平台未配置，无法生成题目")
            completion?(0, 0, false)
            return
        }
        guard let storage = storage, let quiz = quizService else {
            completion?(0, 0, false)
            return
        }
        // 获取云端锁（防止多端同时生成题目导致冲突）
        guard let fs = activeFS,
              CloudLockService.shared.acquireLock(cloudFS: fs) else {
            if let fs = activeFS,
               let holderInfo = CloudLockService.shared.lockHolderInfo(cloudFS: fs) {
                quizError = "其他设备正在操作云端数据，请稍后再试。\n\(holderInfo)"
            } else {
                quizError = "获取云端锁失败，请稍后再试"
            }
            completion?(0, 0, false)
            return
        }
        let allNotes = storage.getAllNotes()
        isGeneratingQuestions = true
        quizError = nil
        quiz.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.quizError = error
            }
        }
        quiz.generateQuestionsForAllNotes(
            notes: allNotes,
            config: bailianConfig,
            onProgress: { [weak self] current, total, title in
                self?.generationProgress = (current, total, title)
                // 每处理完一篇笔记都刷新题库统计
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            },
            completion: { [weak self] newCount, processedCount, wasCancelled in
                // 释放云端锁
                if let fs = self?.activeFS {
                    CloudLockService.shared.releaseLock(cloudFS: fs)
                }
                self?.isGeneratingQuestions = false
                self?.generationProgress = nil
                // 生成完成后刷新统计
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
                completion?(newCount, processedCount, wasCancelled)
            }
        )
    }
    
    /// 取消正在进行的题目生成
    func cancelQuestionGeneration() {
        quizService?.cancelGeneration()
    }

    // MARK: - 内部：创建 CloudFileSystem + 迁移 + 重建 Storage/Scheduler

    private func applyFileSystem(type: CloudProviderType, webDAVConfig: WebDAVConfig, migrateFromScratch: Bool) {
        let newFS = CloudProviderFactory.makeFileSystem(for: type, webDAVConfig: webDAVConfig)

        // 迁移：旧 FS → 新 FS（Notes + .metadata）
        if migrateFromScratch, let oldFS = activeFS, oldFS.providerType != type {
            providerStatus = "⏳ 正在迁移数据（从 \(oldFS.providerType.displayName) → \(type.displayName)…）"
            do {
                try migrate(from: oldFS, to: newFS)
            } catch {
                providerStatus = "❌ 迁移失败，不切换：\(error.localizedDescription)"
                return
            }
        }
        activeFS = newFS
        // 本地优先：StorageService 始终用 LocalFS（快速访问、离线可用）
        // WebDAV 仅作为同步目标（增删改后台双写、下拉同步从云端拉取）
        let localFS = LocalFS()
        let localFileSvc = FileSystemService(cloudFS: localFS)
        fileSystem = localFileSvc
        storage    = StorageService(fileSystem: localFileSvc)
        // 如果选择了 WebDAV，保存实例用于同步；StorageService 持有引用用于双写
        webDAVFS = (type == .webDAV) ? (newFS as? WebDAVFS) : nil
        storage.cloudSyncFS = webDAVFS
        scheduler  = SchedulerService(storage: storage)
        quizService = QuizService(fileSystem: localFileSvc)
        storage.quizService = quizService  // 让删除笔记时能联动删除相关题目
        // 初始化同步快照服务（用于增量同步）
        syncSnapshotService = SyncSnapshotService(fileSystem: localFileSvc)
        syncSnapshotService.load()
        storage.syncSnapshotService = syncSnapshotService
        // 设置云端文件系统（用于锁验证）
        quizService.cloudFS = webDAVFS ?? localFS
        // 更新 quizService 的笔记和文件夹列表（用于按文件夹结构存储题目）
        quizService.updateNotes(storage.getAllNotes(), folders: storage.getAllFolders())
        refreshStats()
    }

    /// 通用迁移：src → dst，复制 Notes/ + .metadata/ 两个目录；冲突时 dst 目录先备份为 _backup_时间戳
    private func migrate(from srcFS: CloudFileSystem, to dstFS: CloudFileSystem) throws {
        guard srcFS.providerType != dstFS.providerType else { return }
        // 由于我们的 FileSystemService 总是把 Notes/ 放在 cloudFS.rootDirectory 的 Notes 下，
        // 这里直接拼接两个子目录 URL
        let srcRoot = srcFS.rootDirectory
        let dstRoot = dstFS.rootDirectory

        // 先确保 dstRoot 存在（WebDAV 场景需要创建目录）
        try dstFS.createDirectoryIfNeeded(at: dstRoot)

        let dirs = ["Notes", ".metadata"]
        let ts = Int(Date().timeIntervalSince1970)
        for d in dirs {
            let src = srcRoot.appendingPathComponent(d, isDirectory: true)
            let dst = dstRoot.appendingPathComponent(d, isDirectory: true)
            guard srcFS.fileExists(at: src) else { continue }
            if dstFS.fileExists(at: dst) {
                let backup = dstRoot.appendingPathComponent("\(d)_backup_\(ts)", isDirectory: true)
                try deepCopy(at: src, to: backup, from: srcFS, to: dstFS, allowMerge: false) // 直接备份
            }
            try deepCopy(at: src, to: dst, from: srcFS, to: dstFS, allowMerge: false)
        }
    }

    /// 递归复制：把 at 的整个子树（from srcFS）复制到 to（在 dstFS）；
    /// 如果目标已存在，allowMerge=true 就递归合并文件，否则先删再复制
    private func deepCopy(at src: URL, to dst: URL, from srcFS: CloudFileSystem, to dstFS: CloudFileSystem, allowMerge: Bool) throws {
        var isDir: ObjCBool = false
        // WebDAV 场景下不能用 FileManager.fileExists + isDirectory，统一通过 contentsOfDirectory 判断
        if srcFS is LocalFS || srcFS is ICloudFS {
            if !FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir) { return }
        }
        // 如果源是目录：列举再递归
        let children: [URL]
        do {
            children = try srcFS.contentsOfDirectory(at: src)
        } catch {
            // 列目录失败 → 可能不是目录或 WebDAV 权限问题，尝试按文件读
            isDir = false
            children = []
        }
        if children.isEmpty && !isDir.boolValue {
            // 源是文件：直接读 srcFS → 写 dstFS
            let data = try srcFS.readData(at: src)
            try dstFS.writeData(data, to: dst)
            return
        }
        // 源是目录：先在 dst 建目录，然后递归每个子项
        try dstFS.createDirectoryIfNeeded(at: dst)
        for child in children {
            let name = child.lastPathComponent
            let dstChild = dst.appendingPathComponent(name, isDirectory: false)
            // 如果子项 URL 可能是目录（WebDAV 以 / 结尾或路径不带扩展名则可能是目录，但这里直接交给递归处理）
            try deepCopy(at: child, to: dstChild, from: srcFS, to: dstFS, allowMerge: allowMerge)
        }
    }

    // MARK: - 配置持久化（WebDAV）

    private static func saveWebDAVConfigToDefaults(_ cfg: WebDAVConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: keyWebDAVConfig)
        }
    }

    private static func loadWebDAVConfigFromDefaults() -> WebDAVConfig {
        guard let data = UserDefaults.standard.data(forKey: keyWebDAVConfig),
              let cfg = try? JSONDecoder().decode(WebDAVConfig.self, from: data) else {
            return WebDAVConfig()
        }
        return cfg
    }

    // MARK: - 状态摘要

    private func summarizeStatus() -> String {
        let fs = activeFS!
        if let icloud = fs as? ICloudFS, !icloud.isAvailable {
            return "⚠️ iCloud 容器不可用（需要 ¥688 开发者账号 + entitlements + Portal 配置 iCloud Container，已回退到本地 Documents）"
        }
        if fs is WebDAVFS {
            return "🥇 WebDAV 已启用：\(fs.displayLocation)（后台按文件粒度同步，关闭前会自动完成写入）"
        }
        return "📁 使用本机 Documents 存储（App 更新/覆盖安装不会丢失 Documents 中的数据，删除 App 会删除）"
    }
}
