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
                .onAppear { Task { await appState.bootstrap() } }
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

    private(set) var activeFS: CloudFileSystem!    // 当前生效的 Provider 后端
    private(set) var fileSystem: FileSystemService!
    @Published var storage: StorageService!
    @Published var scheduler: SchedulerService!
    @Published var isBootstrapped = false

    // MARK: - 统计
    @Published var todayDueCount: Int = 0
    @Published var totalNotes:   Int = 0
    @Published var totalFolders: Int = 0

    // MARK: - Provider 选择 & 配置（持久化）

    @Published var selectedProvider: CloudProviderType = .local {
        didSet {
            guard isBootstrapped else { return }
            guard oldValue != selectedProvider else { return }
            // 切换时：把当前配置用起来，执行迁移
            Task { @MainActor in
                await applyCurrentProviderSelection()
            }
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

    func bootstrap() async {
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

    /// UI 点击「保存并切换 Provider」时调用：选择 + （可选）迁移 + 重建索引
    func applyCurrentProviderSelection() async {
        let type = selectedProvider
        // 保存选择
        UserDefaults.standard.set(type.rawValue, forKey: Self.keyProviderType)

        switch type {
        case .local, .iCloud:
            applyFileSystem(type: type, webDAVConfig: webDAVConfig, migrateFromScratch: true)

        case .webDAV:
            // 先保存密码到 Keychain（如果 pending 有值就写）
            if !pendingWebDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try KeychainHelper.setWebDAVPassword(pendingWebDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    providerStatus = "❌ WebDAV 密码保存到 Keychain 失败：\(error.localizedDescription)"
                    return
                }
            }
            // 如果配置不完整，就不能切
            guard webDAVConfig.isComplete,
                  !(KeychainHelper.webDAVPassword()?.isEmpty ?? true) else {
                providerStatus = "⚠️ WebDAV 配置不完整（地址/用户名/密码缺一不可），已回退选择。"
                // 弹回去（防止 didSet 再次循环调用）
                if selectedProvider == .webDAV { selectedProvider = activeFS.providerType }
                return
            }
            // 保存配置
            Self.saveWebDAVConfigToDefaults(webDAVConfig)
            applyFileSystem(type: .webDAV, webDAVConfig: webDAVConfig, migrateFromScratch: true)
        }
        iCloudContainerAvailable = (activeFS as? ICloudFS)?.isAvailable ?? false
        providerStatus = summarizeStatus()
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
        // 临时写入 Keychain 以便 WebDAVFS 取 Authorization 头
        do { try KeychainHelper.setWebDAVPassword(usePassword) }
        catch { return (false, "Keychain 临时密码失败：\(error.localizedDescription)") }

        let fs = CloudProviderFactory.makeFileSystem(for: .webDAV, webDAVConfig: cfg)
        let root = fs.rootDirectory
        do {
            _ = try await Task.detached { @Sendable in fs.fileExists(at: root) }.value
            return (true, "✅ 连接成功，根目录可访问：\(fs.displayLocation)")
        } catch {
            return (false, "❌ 连接失败：\(error.localizedDescription)")
        }
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
        let newFileSvc = FileSystemService(cloudFS: newFS)
        fileSystem = newFileSvc
        storage    = StorageService(fileSystem: newFileSvc)
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
        if fs is ICloudFS, !(fs is ICloudFS).unsafelyUnwrapped.isAvailable {
            return "⚠️ iCloud 容器不可用（需要 ¥688 开发者账号 + entitlements + Portal 配置 iCloud Container，已回退到本地 Documents）"
        }
        if fs is WebDAVFS {
            return "🥇 WebDAV 已启用：\(fs.displayLocation)（后台按文件粒度同步，关闭前会自动完成写入）"
        }
        return "📁 使用本机 Documents 存储（App 更新/覆盖安装不会丢失 Documents 中的数据，删除 App 会删除）"
    }
}

// 小工具：让 ICloudFS 的 isAvailable 取值在 summarizeStatus 里更安全（避免过度强制解包）
private extension ICloudFS {
    var unsafelyUnwrapped: ICloudFS { self }
}
