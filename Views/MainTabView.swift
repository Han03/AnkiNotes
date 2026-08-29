//
//  MainTabView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 主标签页：浏览（文件夹+笔记）、复习、统计、设置
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
            NavigationStack {
                FolderBrowserView(currentFolderId: nil)
            }
            .tabItem {
                Image(systemName: "folder.fill")
                Text("笔记")
            }
            .tag(0)

            NavigationStack {
                ReviewHomeView()
            }
            .tabItem {
                // 固定图标：rectangle.stack.fill（可变 SF Symbol .badge.<N> 只有 0-9 有字形，count>=10 会找不到字形 → 空白图标）
                Image(systemName: "rectangle.stack.fill")
                Text("复习")
            }
            .tag(1)
            // 真正的数字徽标用系统 badge() API（iOS 15+ 支持，能显示任意数值 10/100/99+）
            .badge(appState.todayDueCount > 0 ? appState.todayDueCount : nil)

            NavigationStack {
                StatsView()
            }
            .tabItem {
                Image(systemName: "chart.bar.fill")
                Text("统计")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Image(systemName: "gearshape.fill")
                Text("设置")
            }
            .tag(3)
        }
        .onChange(of: appState.mainTabIndex) { _ in
            // 每次 tab 切换（无论用户点的，还是别的 View 通过 AppState 改的）都刷新统计
            appState.refreshStats()
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
