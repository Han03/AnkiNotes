//
//  MainTabView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 主标签页：浏览（文件夹+笔记）、复习、统计
struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
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
                let count = appState.todayDueCount
                if count > 0 {
                    Image(systemName: "rectangle.stack.fill.badge.\(min(count, 99))")
                } else {
                    Image(systemName: "rectangle.stack.fill")
                }
                Text("复习")
            }
            .tag(1)
            .badge(appState.todayDueCount > 0 ? String(appState.todayDueCount) : nil)
            
            NavigationStack {
                StatsView()
            }
            .tabItem {
                Image(systemName: "chart.bar.fill")
                Text("统计")
            }
            .tag(2)
        }
        .onChange(of: selectedTab) { _, _ in
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
