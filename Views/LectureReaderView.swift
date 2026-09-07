//
//  LectureReaderView.swift
//  AnkiNotes
//
//  课堂讲稿阅读页面
//

import SwiftUI

/// 课堂讲稿阅读视图
struct LectureReaderView: View {
    @Environment(\.dismiss) private var dismiss
    
    let note: Note
    let lectureContent: String
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 笔记信息
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(.headline)
                        if let folderPath = note.folderPath {
                            Text(folderPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    Divider()
                    
                    // 讲稿内容
                    Text(lectureContent)
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle("课堂讲稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
