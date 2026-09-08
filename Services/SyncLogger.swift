import Foundation
import UIKit

/// 同步日志记录器 - 将同步过程的详细日志写入 tmp 目录
/// 用于排查同步卡住或报错的问题
final class SyncLogger {
    static let shared = SyncLogger()
    
    private var fileHandle: FileHandle?
    private var logFilePath: String?
    private let queue = DispatchQueue(label: "com.ankinotes.synclogger", qos: .utility)
    
    /// 当前日志文件路径
    var currentLogPath: String? { logFilePath }
    
    private init() {}
    
    /// 开始新的同步日志会话
    func startSession() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // 清理旧日志（超过20个时清理最早的10个）
            self.cleanupOldLogs()
            
            // 关闭之前的文件句柄
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            
            // 创建日志文件名：sync_YYYYMMDD_HHMMSS.log
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let fileName = "sync_\(timestamp).log"
            
            // tmp 目录
            let tmpDir = NSTemporaryDirectory()
            let filePath = (tmpDir as NSString).appendingPathComponent(fileName)
            
            // 创建空文件
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
            
            do {
                self.fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                self.fileHandle?.seekToEndOfFile()
                self.logFilePath = filePath
                
                self.writeLine(String(repeating: "=", count: 60))
                self.writeLine("同步日志会话开始")
                self.writeLine("时间: \(Date().description)")
                self.writeLine("日志文件: \(filePath)")
                self.writeLine("设备: \(UIDevice.current.model) \(UIDevice.current.systemVersion)")
                self.writeLine(String(repeating: "=", count: 60))
            } catch {
                print("⚠️ SyncLogger: 创建日志文件失败: \(error)")
            }
        }
    }
    
    /// 结束日志会话
    func endSession() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.writeLine(String(repeating: "=", count: 60))
            self.writeLine("同步日志会话结束: \(Date().description)")
            self.writeLine(String(repeating: "=", count: 60))
            self.fileHandle?.closeFile()
            self.fileHandle = nil
        }
    }
    
    /// 记录 INFO 级别日志
    func info(_ message: String, function: String = #function, line: Int = #line) {
        log(level: "INFO", message: message, function: function, line: line)
    }
    
    /// 记录 DEBUG 级别日志
    func debug(_ message: String, function: String = #function, line: Int = #line) {
        log(level: "DEBUG", message: message, function: function, line: line)
    }
    
    /// 记录 ERROR 级别日志
    func error(_ message: String, function: String = #function, line: Int = #line) {
        log(level: "ERROR", message: message, function: function, line: line)
    }
    
    /// 记录 WARNING 级别日志
    func warning(_ message: String, function: String = #function, line: Int = #line) {
        log(level: "WARN", message: message, function: function, line: line)
    }
    
    /// 记录步骤开始
    func stepStart(_ stepName: String, function: String = #function, line: Int = #line) {
        log(level: "STEP", message: "▶ 开始: \(stepName)", function: function, line: line)
    }
    
    /// 记录步骤完成
    func stepDone(_ stepName: String, duration: TimeInterval? = nil, function: String = #function, line: Int = #line) {
        let durationStr = duration != nil ? String(format: " (耗时 %.2fs)", duration!) : ""
        log(level: "STEP", message: "✓ 完成: \(stepName)\(durationStr)", function: function, line: line)
    }
    
    /// 记录步骤失败
    func stepFail(_ stepName: String, error: Error, function: String = #function, line: Int = #line) {
        log(level: "STEP", message: "✗ 失败: \(stepName) - \(error.localizedDescription)", function: function, line: line)
    }
    
    // MARK: - 内部实现
    
    private func log(level: String, message: String, function: String, line: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            
            let shortFunction = function.components(separatedBy: "(").first ?? function
            let logLine = "[\(timestamp)] [\(level)] [\(shortFunction):\(line)] \(message)\n"
            
            self.writeLine(logLine)
            
            // 同时输出到控制台，便于 Xcode 调试
            print("[\(level)] \(message)")
        }
    }
    
    private func writeLine(_ line: String) {
        // 确保文件句柄存在（同步结束后可能被关闭，自动创建新文件）
        ensureFileHandle()
        
        guard let handle = fileHandle, let data = line.data(using: .utf8) else { return }
        
        do {
            if #available(iOS 13.4, *) {
                try handle.write(contentsOf: data)
            } else {
                handle.write(data)
            }
            // 立即刷新到磁盘，确保即使 App 崩溃或卡住也能看到日志
            handle.synchronizeFile()
        } catch {
            print("⚠️ SyncLogger: 写入日志失败: \(error)")
        }
    }
    
    /// 确保文件句柄存在，如果不存在则创建新的日志文件
    private func ensureFileHandle() {
        guard fileHandle == nil else { return }
        
        // 清理旧日志（超过20个时清理最早的10个）
        cleanupOldLogs()
        
        // 创建日志文件名：sync_YYYYMMDD_HHMMSS.log
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "sync_\(timestamp).log"
        
        // tmp 目录
        let tmpDir = NSTemporaryDirectory()
        let filePath = (tmpDir as NSString).appendingPathComponent(fileName)
        
        // 创建空文件（如果不存在）
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        }
        
        do {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            fileHandle?.seekToEndOfFile()
            logFilePath = filePath
            
            // 写入会话开始标记
            let header = String(repeating: "=", count: 60) + "\n" +
                         "日志会话自动创建（非同步期间）\n" +
                         "时间: \(Date().description)\n" +
                         "日志文件: \(filePath)\n" +
                         String(repeating: "=", count: 60) + "\n"
            if let data = header.data(using: .utf8) {
                if #available(iOS 13.4, *) {
                    try fileHandle?.write(contentsOf: data)
                } else {
                    fileHandle?.write(data)
                }
                fileHandle?.synchronizeFile()
            }
            
            print("📝 SyncLogger: 自动创建日志文件: \(filePath)")
        } catch {
            print("⚠️ SyncLogger: 自动创建日志文件失败: \(error)")
        }
    }
    
    /// 清理旧的日志文件（超过20个时，清理最早的10个）
    func cleanupOldLogs() {
        queue.async {
            let tmpDir = NSTemporaryDirectory()
            let fileManager = FileManager.default
            
            do {
                let files = try fileManager.contentsOfDirectory(atPath: tmpDir)
                let logFiles = files.filter { $0.hasPrefix("sync_") && $0.hasSuffix(".log") }
                    .sorted(by: >) // 降序，最新的在前
                
                // 超过20个时，清理最早的10个（即保留最新的，删除最旧的10个）
                if logFiles.count > 20 {
                    let toDelete = Array(logFiles.suffix(10)) // 最早的10个
                    for fileName in toDelete {
                        let filePath = (tmpDir as NSString).appendingPathComponent(fileName)
                        try? fileManager.removeItem(atPath: filePath)
                    }
                    print("🧹 SyncLogger: 日志文件数量 \(logFiles.count) > 20，清理了最早的 10 个旧日志文件")
                }
            } catch {
                print("⚠️ SyncLogger: 清理旧日志失败: \(error)")
            }
        }
    }
    
    /// 获取所有日志文件路径
    func getAllLogFiles() -> [String] {
        let tmpDir = NSTemporaryDirectory()
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: tmpDir)
            return files.filter { $0.hasPrefix("sync_") && $0.hasSuffix(".log") }
                .sorted(by: >)
                .map { (tmpDir as NSString).appendingPathComponent($0) }
        } catch {
            return []
        }
    }
}
