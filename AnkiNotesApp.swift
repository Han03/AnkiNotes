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
                .onAppear { appState.bootstrap() }
        }
    }
}

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {

    // MARK: - 核心服务

    /// 文件系统（持有引用以便切换 iCloud / 本地模式）
    private(set) var fileSystem: FileSystemService!
    @Published var storage: StorageService!
    @Published var scheduler: SchedulerService!
    @Published var isBootstrapped = false

    // MARK: - 统计

    @Published var todayDueCount: Int = 0
    @Published var totalNotes:   Int = 0
    @Published var totalFolders: Int = 0

    // MARK: - 同步开关 & 状态

    /// 绑定 Toggle：true = iCloud 模式，false = 本地模式
    @Published var useICloud: Bool = false {
        didSet {
            // 防止初始化时设置触发迁移
            guard isBootstrapped else { return }
            guard oldValue != useICloud else { return }
            Task { @MainActor in await applyStorageToggle() }
        }
    }

    /// 同步 / 迁移状态描述（nil 表示处于默认状态）
    @Published var syncStatusMessage: String? = nil
    /// iCloud 真实可用（Dev entitlements + Apple ID 均满足）
    @Published var isICloudContainerAvailable: Bool = false
    /// 当前存储模式对应的 UI 显示名
    var storageModeDisplayName: String { fileSystem?.storageMode.displayName ?? StorageMode.local.displayName }
    /// 当前存储根目录（UI 提示用）
    var storageLocationDescription: String {
        if let path = fileSystem?.iCloudDisplayPath, (fileSystem?.storageMode ?? .local) == .iCloud {
            return path
        }
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? "Documents"
        // 简化显示（避免把超长的 App 沙盒 UUID 路径全显示出来）
        return "📁 本机：…/Documents" + (docs.contains("/Documents/") ? "" : "")
    }

    // MARK: - 启动

    func bootstrap() {
        let fs = FileSystemService()
        self.fileSystem = fs
        self.storage    = StorageService(fileSystem: fs)
        self.scheduler  = SchedulerService(storage: storage)
        self.isICloudContainerAvailable = fs.iCloudContainerAvailable
        self.useICloud = fs.storageMode == .iCloud
        refreshStats()
        isBootstrapped = true
        if useICloud {
            syncStatusMessage = isICloudContainerAvailable ? "已启用 iCloud 同步" : "已请求 iCloud 但容器不可用（已回退本地存储）"
        }
    }

    func refreshStats() {
        todayDueCount = scheduler.getTodayDueCount()
        totalNotes   = storage.getAllNotes().count
        totalFolders = storage.getAllFolders().count
    }

    // MARK: - 模式切换（迁移 + 重建索引）

    /// 用户从 Toggle 切开关时调用：处理迁移、错误提示、重建 Storage/Scheduler（因为索引文件路径变了）
    func applyStorageToggle() async {
        let targetMode: StorageMode = useICloud ? .iCloud : .local
        do {
            syncStatusMessage = "正在切换（迁移数据中…）"
            try fileSystem.setStorageMode(targetMode, migrate: true)
            // 重建 StorageService + SchedulerService → 从新根目录加载索引
            let newStorage = StorageService(fileSystem: fileSystem)
            let newScheduler = SchedulerService(storage: newStorage)
            self.storage = newStorage
            self.scheduler = newScheduler
            refreshStats()
            isICloudContainerAvailable = fileSystem.iCloudContainerAvailable
            switch targetMode {
            case .local:
                syncStatusMessage = "已切换到本机存储（✅ 同步成功）"
            case .iCloud:
                syncStatusMessage = isICloudContainerAvailable
                    ? "已切换到 ☁️ iCloud 同步（数据迁移完成，等待系统后台上传）"
                    : "切换失败：iCloud 容器不可用（需要付费 Apple Developer 账号 + 配置 iCloud Container，已回退本地）"
                // 不可用则把 Toggle 弹回去
                if !isICloudContainerAvailable { useICloud = false }
            }
        } catch {
            // 失败：把 Toggle 弹回去，显示错误
            syncStatusMessage = "切换失败：\(error.localizedDescription)"
            useICloud.toggle()
        }
    }
}
