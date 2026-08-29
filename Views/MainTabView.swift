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
            // 真正的数字徽标用 badge() API 的 String 重载（iOS 15+）。
            // 注：iOS SDK 里 badge(Int?) 存在重载歧义：nil/false 分支会触发 "'nil' cannot be used in context expecting type 'Int'" 或
            //     "value of optional type 'Int?' must be unwrapped to a value of type 'Int'"。因此这里用 String? 作为返回类型最稳健：
            //     0 条不传，非 0 条直接转字符串显示（iOS 会在 Tab 右上角绘制红色数字角标）
            .badge(appState.todayDueCount > 0 ? String(appState.todayDueCount) : nil)

            NavigationStack {
                QuizHomeView()
            }
            .tabItem {
                Image(systemName: "square.stack.3d.up.fill")
                Text("刷题")
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
