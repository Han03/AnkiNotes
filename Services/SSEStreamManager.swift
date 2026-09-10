//
//  SSEStreamManager.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/10.
//

import Foundation

/// SSE 流式管理器：共享 URLSession（连接池跨请求复用）+ delegate 逐段接收（真流式）
///
/// 解决的问题：`URLSession.shared.bytes(for:)` 的 AsyncBytes 在 iOS 上会把整个响应
/// 缓冲后一次性 yield（日志实证：首字节后 80ms 内 46 个 chunk 全量到达，非真流式）。
/// 而 delegate 模式的 `didReceive` 按网络数据包逐段回调（历史 delegate 版日志实证 chunk 逐段到达）。
///
/// 设计：
/// - 单例持有共享 URLSession（连接复用，避免每次新建 session 导致每次全新 TLS 握手、TTFT 劣化）
/// - delegate 按 `taskIdentifier` 分发到各自的 AsyncStream continuation，支持并发多个 SSE 流
/// - 流在 Task 取消时通过 `onTermination` 自动取消底层 dataTask
final class SSEStreamManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SSEStreamManager()
    
    private var session: URLSession!
    private var streams: [Int: AsyncStream<String>.Continuation] = [:]
    private var pendingBuffers: [Int: String] = [:]     // 跨 didReceive 的不完整行缓冲
    private var firstByteLogged: [Int: Bool] = [:]
    private let lock = NSLock()
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        // delegateQueue: nil → 系统创建串行队列，didReceive 按序处理
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    /// 发起 SSE 流式请求，返回逐段内容流
    /// - 网络数据到达即 yield（真流式，不缓冲整个响应）
    /// - 流完成/失败时 finish
    /// - 消费方 Task 取消时自动取消底层 dataTask
    func stream(for request: URLRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            streams[task.taskIdentifier] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.streams[task.taskIdentifier] = nil
                self?.pendingBuffers[task.taskIdentifier] = nil
                self?.firstByteLogged[task.taskIdentifier] = nil
                self?.lock.unlock()
                task.cancel()
            }
            task.resume()
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard let text = String(data: data, encoding: .utf8) else { return }
        
        lock.lock()
        if firstByteLogged[id] != true {
            firstByteLogged[id] = true
            SyncLogger.shared.info("📡 SSE 首字节到达: \(Date())")
        }
        var pending = pendingBuffers[id] ?? ""
        pending += text
        var chunks: [String] = []
        // 按行切分；最后不完整行留到下一段
        while let nl = pending.range(of: "\n") {
            let line = String(pending[..<nl.lowerBound])
            pending = String(pending[nl.upperBound...])
            if let chunk = Self.parseSSELine(line) {
                chunks.append(chunk)
            }
        }
        pendingBuffers[id] = pending
        let continuation = streams[id]
        lock.unlock()
        
        for chunk in chunks {
            continuation?.yield(chunk)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        // 处理最后残留的不完整行
        if let pending = pendingBuffers[id], !pending.isEmpty {
            if let chunk = Self.parseSSELine(pending) {
                let continuation = streams[id]
                lock.unlock()
                continuation?.yield(chunk)
                lock.lock()
            }
            pendingBuffers[id] = nil
        }
        let continuation = streams[id]
        streams[id] = nil
        pendingBuffers[id] = nil
        firstByteLogged[id] = nil
        lock.unlock()
        
        continuation?.finish()
    }
    
    /// 解析单行 SSE 事件（data: {content}），返回 content；空行/[DONE]/非 data 行返回 nil
    private static func parseSSELine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let content = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, content != "[DONE]" else { return nil }
        return content
    }
}
