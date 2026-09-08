//
//  AppLogger.swift
//  AnkiNotes
//
//  全局日志管理器 - 统一管理所有模块的日志记录
//  支持多级别、多模块、文件输出、控制台输出、性能监控、崩溃记录
//

import Foundation
import UIKit

// MARK: - 日志级别

/// 日志级别，从低到高排列
enum LogLevel: Int, Comparable, Codable, CaseIterable {
    case verbose = 0  // 最详细的调试信息
    case debug = 1    // 调试信息
    case info = 2     // 一般信息
    case warning = 3  // 警告信息
    case error = 4    // 错误信息
    case fatal = 5    // 致命错误
    
    var shortName: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
    
    var emoji: String {
        switch self {
        case .verbose: return "🔍"
        case .debug: return "🐛"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .fatal: return "💀"
        }
    }
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 日志模块标识

/// 日志模块标识，用于区分日志来源
enum LogModule: String, Codable, CaseIterable {
    case app = "APP"           // 应用程序
    case sync = "SYNC"         // 同步模块
    case tts = "TTS"           // 语音合成
    case quiz = "QUIZ"         // 题库
    case knowledge = "KNOW"    // 知识点
    case cloud = "CLOUD"       // 云端存储
    case lock = "LOCK"         // 分布式锁
    case ui = "UI"             // 界面
    case storage = "STORAGE"   // 本地存储
    case network = "NET"       // 网络请求
    case performance = "PERF"  // 性能监控
    case crash = "CRASH"       // 崩溃记录
    case other = "OTHER"       // 其他
}

// MARK: - 日志消息

/// 日志消息结构体
struct LogMessage {
    let timestamp: Date
    let level: LogLevel
    let module: LogModule
    let message: String
    let fileName: String
    let line: Int
    let function: String
    let thread: String
    let extra: [String: Any]?
    
    var shortFileName: String {
        (fileName as NSString).lastPathComponent
    }
    
    var shortFunction: String {
        function.components(separatedBy: "(").first ?? function
    }
}

// MARK: - 日志格式化器

/// 日志格式化器
struct LogFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    /// 格式化为文件日志格式
    static func formatForFile(_ message: LogMessage) -> String {
        let timestamp = dateFormatter.string(from: message.timestamp)
        var line = "[\(timestamp)] [\(message.level.shortName)] [\(message.module.rawValue)] [\(message.shortFileName):\(message.line)] \(message.message)"
        
        if let extra = message.extra, !extra.isEmpty {
            let extraStr = extra.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            line += " | \(extraStr)"
        }
        
        return line + "\n"
    }
    
    /// 格式化为控制台日志格式
    static func formatForConsole(_ message: LogMessage) -> String {
        "\(message.level.emoji) [\(message.module.rawValue)] \(message.message)"
    }
}

// MARK: - 日志输出目标协议

/// 日志输出目标协议
protocol LogDestination {
    func write(_ message: LogMessage)
    func flush()
}

// MARK: - 控制台输出目标

/// 控制台输出目标
final class ConsoleDestination: LogDestination {
    private let minLevel: LogLevel
    
    init(minLevel: LogLevel = .debug) {
        self.minLevel = minLevel
    }
    
    func write(_ message: LogMessage) {
        guard message.level >= minLevel else { return }
        print(LogFormatter.formatForConsole(message))
    }
    
    func flush() {}
}

// MARK: - 文件输出目标

/// 文件输出目标
final class FileDestination: LogDestination {
    private let minLevel: LogLevel
    private let maxFileSize: Int64  // 单个文件最大大小（字节）
    private let maxFileCount: Int   // 最大文件数量
    private let queue = DispatchQueue(label: "com.ankinotes.logger.file", qos: .utility)
    
    private var fileHandle: FileHandle?
    private var currentFilePath: String?
    private var currentFileSize: Int64 = 0
    
    init(minLevel: LogLevel = .verbose, maxFileSize: Int64 = 10 * 1024 * 1024, maxFileCount: Int = 30) {
        self.minLevel = minLevel
        self.maxFileSize = maxFileSize
        self.maxFileCount = maxFileCount
    }
    
    var currentPath: String? { currentFilePath }
    
    func write(_ message: LogMessage) {
        guard message.level >= minLevel else { return }
        queue.async { [weak self] in
            self?.writeInternal(message)
        }
    }
    
    func flush() {
        queue.sync { [weak self] in
            self?.fileHandle?.synchronizeFile()
        }
    }
    
    private func writeInternal(_ message: LogMessage) {
        ensureFileHandle()
        
        guard let handle = fileHandle else { return }
        
        let line = LogFormatter.formatForFile(message)
        guard let data = line.data(using: .utf8) else { return }
        
        do {
            if #available(iOS 13.4, *) {
                try handle.write(contentsOf: data)
            } else {
                handle.write(data)
            }
            handle.synchronizeFile()
            currentFileSize += Int64(data.count)
            
            // 检查是否需要轮转文件
            if currentFileSize >= maxFileSize {
                rotateFile()
            }
        } catch {
            print("⚠️ AppLogger: 写入日志文件失败: \(error)")
        }
    }
    
    private func ensureFileHandle() {
        guard fileHandle == nil else { return }
        
        cleanupOldLogs()
        createNewFile()
    }
    
    private func createNewFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "app_\(timestamp).log"
        
        let logDir = Self.logDirectory()
        let filePath = (logDir as NSString).appendingPathComponent(fileName)
        
        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        
        do {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            fileHandle?.seekToEndOfFile()
            currentFilePath = filePath
            currentFileSize = 0
            
            // 写入文件头
            let header = """
            \(String(repeating: "=", count: 70))
            AnkiNotes 应用日志
            时间: \(Date().description)
            设备: \(UIDevice.current.model) \(UIDevice.current.systemVersion)
            应用版本: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "未知")
            日志文件: \(filePath)
            \(String(repeating: "=", count: 70))
            
            """
            if let data = header.data(using: .utf8) {
                if #available(iOS 13.4, *) {
                    try fileHandle?.write(contentsOf: data)
                } else {
                    fileHandle?.write(data)
                }
                fileHandle?.synchronizeFile()
                currentFileSize += Int64(data.count)
            }
        } catch {
            print("⚠️ AppLogger: 创建日志文件失败: \(error)")
        }
    }
    
    private func rotateFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentFilePath = nil
        currentFileSize = 0
        createNewFile()
    }
    
    private func cleanupOldLogs() {
        let logDir = Self.logDirectory()
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: logDir)
            let logFiles = files.filter { $0.hasPrefix("app_") && $0.hasSuffix(".log") }
                .sorted(by: >)  // 降序，最新的在前
            
            if logFiles.count > maxFileCount {
                let toDelete = Array(logFiles.suffix(logFiles.count - maxFileCount))
                for fileName in toDelete {
                    let filePath = (logDir as NSString).appendingPathComponent(fileName)
                    try? fileManager.removeItem(atPath: filePath)
                }
                print("🧹 AppLogger: 日志文件数量 \(logFiles.count) > \(maxFileCount)，清理了 \(toDelete.count) 个旧日志")
            }
        } catch {
            print("⚠️ AppLogger: 清理旧日志失败: \(error)")
        }
    }
    
    /// 日志目录（Documents/Logs）
    static func logDirectory() -> String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let logDir = (docs as NSString).appendingPathComponent("Logs")
        
        if !FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }
        
        return logDir
    }
    
    /// 获取所有日志文件路径
    static func getAllLogFiles() -> [String] {
        let logDir = logDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: logDir)
            return files.filter { $0.hasPrefix("app_") && $0.hasSuffix(".log") }
                .sorted(by: >)
                .map { (logDir as NSString).appendingPathComponent($0) }
        } catch {
            return []
        }
    }
}

// MARK: - 全局日志管理器

/// 全局日志管理器
final class AppLogger {
    static let shared = AppLogger()
    
    private var destinations: [LogDestination] = []
    private let queue = DispatchQueue(label: "com.ankinotes.logger", qos: .utility)
    
    /// 最低日志级别（低于此级别的日志不会被记录）
    var minLevel: LogLevel = .verbose
    
    /// 是否启用崩溃日志记录
    var crashLoggingEnabled = true
    
    private init() {
        setupDefaultDestinations()
        setupCrashHandlers()
    }
    
    // MARK: - 配置
    
    private func setupDefaultDestinations() {
        // 控制台输出（DEBUG 及以上）
        destinations.append(ConsoleDestination(minLevel: .debug))
        
        // 文件输出（VERBOSE 及以上，全部记录）
        destinations.append(FileDestination(minLevel: .verbose))
    }
    
    /// 添加输出目标
    func addDestination(_ destination: LogDestination) {
        queue.async { [weak self] in
            self?.destinations.append(destination)
        }
    }
    
    /// 移除所有输出目标
    func removeAllDestinations() {
        queue.async { [weak self] in
            self?.destinations.removeAll()
        }
    }
    
    // MARK: - 日志记录方法
    
    /// 记录 VERBOSE 级别日志
    static func verbose(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .verbose, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 记录 DEBUG 级别日志
    static func debug(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .debug, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 记录 INFO 级别日志
    static func info(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .info, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 记录 WARNING 级别日志
    static func warning(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .warning, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 记录 ERROR 级别日志
    static func error(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .error, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 记录 FATAL 级别日志
    static func fatal(_ module: LogModule = .other, _ message: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function) {
        shared.log(level: .fatal, module: module, message: message, extra: extra, file: file, line: line, function: function)
    }
    
    /// 性能监控：记录方法执行时间
    @discardableResult
    static func measure<T>(_ module: LogModule = .performance, _ label: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function, _ block: () throws -> T) rethrows -> T {
        let startTime = Date()
        let result = try block()
        let duration = Date().timeIntervalSince(startTime)
        shared.log(level: .debug, module: module, message: "⏱️ \(label) 耗时 \(String(format: "%.3f", duration))s", extra: extra, file: file, line: line, function: function)
        return result
    }
    
    /// 异步性能监控
    static func measureAsync(_ module: LogModule = .performance, _ label: String, extra: [String: Any]? = nil, file: String = #file, line: Int = #line, function: String = #function, _ block: @escaping () -> Void) {
        let startTime = Date()
        block()
        let duration = Date().timeIntervalSince(startTime)
        shared.log(level: .debug, module: module, message: "⏱️ \(label) 耗时 \(String(format: "%.3f", duration))s", extra: extra, file: file, line: line, function: function)
    }
    
    // MARK: - 内部实现
    
    private func log(level: LogLevel, module: LogModule, message: String, extra: [String: Any]?, file: String, line: Int, function: String) {
        guard level >= minLevel else { return }
        
        let thread = Thread.isMainThread ? "main" : "background"
        let logMessage = LogMessage(
            timestamp: Date(),
            level: level,
            module: module,
            message: message,
            fileName: file,
            line: line,
            function: function,
            thread: thread,
            extra: extra
        )
        
        queue.async { [weak self] in
            guard let self = self else { return }
            for destination in self.destinations {
                destination.write(logMessage)
            }
        }
    }
    
    /// 立即刷新所有输出目标
    static func flush() {
        shared.queue.sync {
            for destination in shared.destinations {
                destination.flush()
            }
        }
    }
    
    // MARK: - 崩溃日志记录
    
    private func setupCrashHandlers() {
        guard crashLoggingEnabled else { return }
        
        // 记录 Objective-C 异常
        NSSetUncaughtExceptionHandler { exception in
            AppLogger.fatal(.crash, "💀 未捕获的 Objective-C 异常: \(exception.name.rawValue) - \(exception.reason ?? "未知")", extra: [
                "callStackSymbols": exception.callStackSymbols.joined(separator: "\n"),
                "userInfo": exception.userInfo ?? [:]
            ])
            AppLogger.flush()
        }
        
        // 记录 Unix 信号
        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP]
        for sigNum in signals {
            Darwin.signal(sigNum) { sig in
                AppLogger.fatal(.crash, "💀 收到致命信号: \(sig)", extra: [
                    "signalName": String(cString: strsignal(sig))
                ])
                AppLogger.flush()
                // 重新抛出信号，让系统正常终止
                Darwin.signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
    
    // MARK: - 日志导出
    
    /// 导出日志（iOS 上没有 Process 类，无法创建 zip，直接返回最新的日志文件路径）
    static func exportLogs() -> URL? {
        flush()
        
        let logFiles = FileDestination.getAllLogFiles()
        guard !logFiles.isEmpty else { return nil }
        
        // 返回最新的日志文件路径
        return URL(fileURLWithPath: logFiles[0])
    }
    
    /// 获取所有日志文件路径（用于分享多个文件）
    static func exportAllLogs() -> [URL] {
        flush()
        
        let logFiles = FileDestination.getAllLogFiles()
        return logFiles.map { URL(fileURLWithPath: $0) }
    }
    
    /// 获取当前日志文件路径
    static var currentLogPath: String? {
        for destination in shared.destinations {
            if let fileDest = destination as? FileDestination {
                return fileDest.currentPath
            }
        }
        return nil
    }
    
    /// 获取所有日志文件路径
    static var allLogFiles: [String] {
        FileDestination.getAllLogFiles()
    }
}

// MARK: - 便捷扩展

/// 同步模块专用日志（兼容旧代码）
extension AppLogger {
    static func syncInfo(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        info(.sync, message, file: file, line: line, function: function)
    }
    
    static func syncDebug(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        debug(.sync, message, file: file, line: line, function: function)
    }
    
    static func syncWarning(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        warning(.sync, message, file: file, line: line, function: function)
    }
    
    static func syncError(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        error(.sync, message, file: file, line: line, function: function)
    }
}
