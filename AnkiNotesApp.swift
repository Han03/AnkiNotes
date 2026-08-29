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
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                // 注入全局文字缩放倍率 → 所有 .textStyle() modifier 自动生效
                .environment(\.textScale, appState.textScale)
                .onAppear { appState.bootstrap() }
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

    @Published var providerStatus: String? = nil
    @Published var iCloudContainerAvailable: Bool = false
    @Published var isSyncing: Bool = false  // ✅ 正在同步/导入中（UI 显示加载提示）

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
        // 3) 恢复文字大小
        let storedScale = UserDefaults.standard.double(forKey: Self.keyTextScale)
        textScale = (storedScale > 0.1 && storedScale < 5) ? storedScale : 1.0
        // 4) 创建当前 Provider 对应 CloudFileSystem，并组装 FileSystem + Storage + Scheduler
        applyFileSystem(type: selectedProvider, webDAVConfig: webDAVConfig, migrateFromScratch: false)
        // 5) 状态初值
        iCloudContainerAvailable = (activeFS as? ICloudFS)?.isAvailable ?? false
        providerStatus = summarizeStatus()
        refreshStats()
        isBootstrapped = true
    }

    func refreshStats() {
        todayDueCount = scheduler.getTodayDueCount()
        totalNotes   = storage.getAllNotes().count
        totalFolders = storage.getAllFolders().count
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

    /// 从云端同步笔记到本地（下拉刷新触发，全局唯一同步入口）
    /// - 加锁防止重复执行
    /// - 后台线程扫描云端 Notes 目录，下载新笔记到本地
    /// - 去重：同文件夹+同标题跳过
    func syncFromCloud(completion: ((StorageService.ImportReport) -> Void)? = nil) {
        guard webDAVFS != nil else {
            providerStatus = "⚠️ 未配置 WebDAV，无法同步。请到设置页配置 WebDAV。"
            completion?(StorageService.ImportReport())
            return
        }
        // 加锁：同步操作进行中时拒绝重复执行
        guard syncLock.try() else {
            print("⚠️ 同步正在进行中，跳过重复请求")
            return
        }
        isSyncing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                self.syncLock.unlock()
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.refreshStats()
                    self.storage.triggerRefresh()
                }
            }
            // 从云端扫描并导入到本地
            let report = self.storage.importFromCloud()
            DispatchQueue.main.async {
                if report.scannedMarkdownFiles == 0 {
                    self.providerStatus = "⚠️ 云端 Notes 目录没有发现 .md 文件。请确认笔记放在了坚果云的 Notes/ 目录下。"
                } else {
                    self.providerStatus = "✅ 同步完成：新增 \(report.importedCount)，跳过 \(report.skippedCount)，失败 \(report.failedCount)，扫描到 \(report.scannedMarkdownFiles) 个 .md 文件"
                }
                completion?(report)
            }
        }
    }

    /// 异步导入 Markdown（保留兼容，内部调用 syncFromCloud）
    func importMarkdownAsync(completion: ((StorageService.ImportReport) -> Void)? = nil) {
        syncFromCloud(completion: completion)
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
