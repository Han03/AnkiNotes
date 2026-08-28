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
                .onAppear {
                    appState.bootstrap()
                }
        }
    }
}

/// 全局应用状态
final class AppState: ObservableObject {
    @Published var storage: StorageService!
    @Published var scheduler: SchedulerService!
    @Published var isBootstrapped = false
    @Published var todayDueCount: Int = 0
    @Published var totalNotes: Int = 0
    @Published var totalFolders: Int = 0
    
    func bootstrap() {
        let fileSystem = FileSystemService()
        storage = StorageService(fileSystem: fileSystem)
        scheduler = SchedulerService(storage: storage)
        refreshStats()
        isBootstrapped = true
    }
    
    func refreshStats() {
        todayDueCount = scheduler.getTodayDueCount()
        totalNotes = storage.getAllNotes().count
        totalFolders = storage.getAllFolders().count
    }
}
