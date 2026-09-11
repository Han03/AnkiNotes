//
//  MainTabView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 主标签页：笔记、复习、刷题、设置
/// 所有菜单下拉刷新都触发云端同步，同步模态框在最顶层显示
struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    // 双向绑定：UI 操作写入 selectedTab，同时观察 appState.mainTabIndex（其他 View 想切 Tab 时通过改这个实现）
    private var tabSelection: Binding<Int> {
        Binding(
            get: { appState.mainTabIndex },
            set: { appState.mainTabIndex = $0 }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            // 笔记菜单
            NavigationStack {
                FolderBrowserView(currentFolderPath: nil)
                    .refreshable { await triggerSync() }
            }
            .tabItem {
                Image(systemName: "folder.fill")
                Text("笔记")
            }
            .tag(0)

            // 复习菜单（取消下拉刷新，避免误触发全局同步）
            NavigationStack {
                ReviewHomeView()
            }
            .tabItem {
                Image(systemName: "rectangle.stack.fill")
                Text("复习")
            }
            .tag(1)
            .badge(appState.todayDueCount > 0 ? String(appState.todayDueCount) : nil)

            // 刷题菜单
            NavigationStack {
                QuizHomeView()
                    .refreshable { await triggerSync() }
            }
            .tabItem {
                Image(systemName: "square.stack.3d.up.fill")
                Text("刷题")
            }
            .tag(2)

            // 设置菜单
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Image(systemName: "gearshape.fill")
                Text("设置")
            }
            .tag(3)
        }
        // 主菜单选中颜色统一为橙色，与全局主题保持一致
        .tint(.brandPrimary)
        // 最顶层同步模态框（在所有菜单之上）
        .overlay {
            if appState.isSyncing || appState.isSilentSyncing {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: AppSpacing.lg) {
                        // 图标 + 标题
                        HStack(spacing: AppSpacing.md) {
                            if appState.syncProgress > 0 && appState.syncProgress < 100 {
                                // 显示进度环
                                ZStack {
                                    Circle()
                                        .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                    Circle()
                                        .trim(from: 0, to: CGFloat(appState.syncProgress / 100.0))
                                        .stroke(Color.brandPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Text("\(Int(appState.syncProgress))%")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                                .frame(width: 50, height: 50)
                            } else {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .tint(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.isSilentSyncing ? "后台同步中" : "正在同步")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                if !appState.syncStep.isEmpty {
                                    Text(appState.syncStep)
                                        .font(.appBody)
                                        .foregroundColor(.brandPrimary)
                                }
                            }
                        }
                        
                        // 进度条
                        if appState.syncProgress > 0 {
                            ProgressView(value: appState.syncProgress / 100.0)
                                .tint(.brandPrimary)
                                .frame(maxWidth: 280)
                        }
                        
                        // 详情
                        if !appState.syncDetail.isEmpty {
                            Text(appState.syncDetail)
                                .font(.appCaption)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                                .lineLimit(2)
                        } else if let status = appState.providerStatus, !status.isEmpty {
                            Text(status)
                                .font(.appCaption)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                                .lineLimit(3)
                        }
                        
                        // 取消同步按钮
                        Button(action: {
                            appState.requestCancelSync()
                        }) {
                            Text("取消同步")
                                .font(.appBody)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: AppCornerRadius.md)
                                        .fill(Color.red.opacity(0.8))
                                )
                        }
                        .padding(.top, AppSpacing.xs)
                    }
                    .padding(AppSpacing.xxl)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.xxl).fill(Color(.systemGray6).opacity(0.95)))
                }
                .transition(.opacity)
            }
        }
        .onChange(of: appState.mainTabIndex) { _ in
            // 每次 tab 切换时刷新统计
            appState.refreshStats()
        }
    }

    /// 触发同步（合并同步与刷新操作）
    private func triggerSync() async {
        await withCheckedContinuation { continuation in
            appState.syncFromCloud { _ in
                continuation.resume()
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject({
            let s = AppState()
            s.bootstrap()
            return s
        }())
}
