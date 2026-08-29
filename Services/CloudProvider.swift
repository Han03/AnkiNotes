//
//  CloudProvider.swift
//  AnkiNotes
//
//  云盘 Provider 抽象层：统一协议 → 本地 / iCloud / WebDAV 三种实现
//  未来扩展百度网盘 / 阿里云盘只需新增一个 CloudFileSystem 实现即可。
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - 1. Provider 类型

/// 用户可选的存储/同步后端
enum CloudProviderType: String, Codable, CaseIterable, Identifiable, Hashable {
    case local      // 📁 本机 Documents（默认，离线无依赖）
    case iCloud     // ☁️ 苹果 iCloud Drive（系统级，需 ¥688 Dev + entitlements）
    case webDAV     // 🥇 WebDAV 通用协议（兼容：坚果云 / 群晖 NAS / Nextcloud / Alist 桥接）

    var id: String { rawValue }

    /// 显示名称（设置 UI）
    var displayName: String {
        switch self {
        case .local:  return "📁 本机存储"
        case .iCloud: return "☁️ iCloud Drive"
        case .webDAV: return "🥇 WebDAV（坚果云 / NAS）"
        }
    }

    /// SF Symbol 图标
    var systemIcon: String {
        switch self {
        case .local:  return "internaldrive"
        case .iCloud: return "icloud"
        case .webDAV: return "network"
        }
    }

    /// 是否需要额外配置表单（UI 决定显示什么）
    var needsConfig: Bool {
        switch self {
        case .local:  return false
        case .iCloud: return false   // iCloud 由系统账号控制，不需要用户填账号
        case .webDAV: return true    // WebDAV 要填服务器/用户名/密码/根路径
        }
    }
}

// MARK: - 2. WebDAV 配置

/// WebDAV 连接配置（密码存 Keychain，其余字段存 UserDefaults）
struct WebDAVConfig: Codable, Hashable {
    var serverURL: String   // 例：https://dav.jianguoyun.com/dav/
    var username: String    // 例：you@example.com
    // password 不在此结构体里明文保存；通过 KeychainHelper.webDAVPassword 存取
    var rootPath: String    // 例：/AnkiNotes（默认）
    var trustSelfSigned: Bool // 自建 NAS 自签名证书场景（默认 false）

    enum CodingKeys: CodingKey { case serverURL, username, rootPath, trustSelfSigned }

    init(serverURL: String = "", username: String = "", rootPath: String = "/AnkiNotes", trustSelfSigned: Bool = false) {
        self.serverURL = serverURL
        self.username = username
        self.rootPath = rootPath
        self.trustSelfSigned = trustSelfSigned
    }

    /// 快速校验：字段基本非空
    var isComplete: Bool {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.lowercased().hasPrefix("http") else { return false }
        return !username.isEmpty && !rootPath.isEmpty
    }

    /// 规范化 baseURL（保证以 / 结尾），拼接子路径时正确
    var normalizedBaseURL: URL? {
        var str = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.hasSuffix("/") { str.append("/") }
        return URL(string: str)
    }
}

// MARK: - 3. 统一文件系统协议（本地 / iCloud / WebDAV 都要实现）

protocol CloudFileSystem: AnyObject {
    /// Provider 类型
    var providerType: CloudProviderType { get }

    /// 根目录（相当于本地的 Documents）
    var rootDirectory: URL { get }

    /// 这个 Provider 是否可用（例如 iCloud 容器没 entitlements 就返回 false）
    var isAvailable: Bool { get }

    /// UI 显示用：例如「iCloud Drive ▸ AnkiNotes」或「WebDAV: https://xxx/AnkiNotes」
    var displayLocation: String { get }

    // MARK: 基础操作
    /// 判断文件/目录是否存在
    func fileExists(at url: URL) -> Bool
    /// 创建目录（withIntermediateDirectories: true）
    func createDirectoryIfNeeded(at url: URL) throws
    /// 列出目录中的直接子项 URL（用于 WebDAV 扫描，本地用 FileManager）
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// 读取数据
    func readData(at url: URL) throws -> Data
    /// 写入数据（atomic）
    func writeData(_ data: Data, to url: URL) throws
    /// 删除
    func removeItem(at url: URL) throws
    /// 复制（用于 Provider 切换时迁移数据）
    func copyItem(at srcURL: URL, to dstURL: URL) throws
}

// MARK: - 4. Keychain 工具（仅存 WebDAV 密码；免费版 Security 可用）

enum KeychainHelper {
    private static let service = "AnkiNotes.Keychain"
    private static let webDAVPasswordAccount = "webDAV.password"

    // MARK: - WebDAV Password

    static func setWebDAVPassword(_ password: String) throws {
        guard !password.isEmpty else {
            try deleteWebDAVPassword()
            return
        }
        let data = Data(password.utf8)
        // 1) 先查是否已有，有就 update，没有就 add
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: webDAVPasswordAccount
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            // update
            let update: [CFString: Any] = [kSecValueData: data]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else if status == errSecItemNotFound {
            // add
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain 保存密码失败（错误码 \(status)）"])
        }
    }

    static func webDAVPassword() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: webDAVPasswordAccount,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteWebDAVPassword() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: webDAVPasswordAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "KeychainHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain 删除密码失败（错误码 \(status)）"])
        }
    }
}

// MARK: - 5. 实现 1：本机存储（FileManager）

final class LocalFS: CloudFileSystem {
    let providerType: CloudProviderType = .local
    private let fm = FileManager.default

    var rootDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var isAvailable: Bool { true }

    var displayLocation: String {
        "📁 本机：…/AppData/Documents"
    }

    func fileExists(at url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func createDirectoryIfNeeded(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }

    func writeData(_ data: Data, to url: URL) throws {
        try createDirectoryIfNeeded(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    func removeItem(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try createDirectoryIfNeeded(at: dstURL.deletingLastPathComponent())
        if fm.fileExists(atPath: dstURL.path) {
            try fm.removeItem(at: dstURL)
        }
        try fm.copyItem(at: srcURL, to: dstURL)
    }
}

// MARK: - 6. 实现 2：iCloud Drive

final class ICloudFS: CloudFileSystem {
    let providerType: CloudProviderType = .iCloud
    private let fm = FileManager.default
    private let containerID: String? = nil // nil = 用 entitlements 声明的第一个 container

    var isAvailable: Bool {
        fm.url(forUbiquityContainerIdentifier: containerID) != nil
    }

    var rootDirectory: URL {
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            // 统一子路径：<Container>/Documents/AnkiNotes  →  在文件 App 显示为 iCloud ▸ AnkiNotes
            let dir = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("AnkiNotes", isDirectory: true)
            try? createDirectoryIfNeeded(at: dir)
            return dir
        }
        // iCloud 不可用：fallback 到本地（上一层会提示用户）
        return LocalFS().rootDirectory
    }

    var displayLocation: String {
        isAvailable ? "☁️ iCloud Drive ▸ AnkiNotes" : "☁️ iCloud（容器不可用，已回退本地）"
    }

    // iCloud 文件操作大部分跟本地一样（系统在后台自动同步上传/下载）
    func fileExists(at url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func createDirectoryIfNeeded(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    func readData(at url: URL) throws -> Data {
        // iCloud 上可能还没下载：先强制 startDownloadingUbiquitousItem
        if fm.isUbiquitousItem(at: url) {
            try fm.startDownloadingUbiquitousItem(at: url)
            // 简单轮询最多 5 秒等它下载完成（文本文件很小）
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   values.ubiquitousItemDownloadingStatus == .current {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try createDirectoryIfNeeded(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    func removeItem(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try createDirectoryIfNeeded(at: dstURL.deletingLastPathComponent())
        if fm.fileExists(atPath: dstURL.path) { try fm.removeItem(at: dstURL) }
        try fm.copyItem(at: srcURL, to: dstURL)
    }
}

// MARK: - 7. 实现 3：WebDAV（URLSession + 自定义 XMLParser 解析 PROPFIND）

final class WebDAVFS: CloudFileSystem {
    let providerType: CloudProviderType = .webDAV
    let config: WebDAVConfig
    private let session: URLSession

    // MARK: 初始化

    init(config: WebDAVConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = WebDAVFS.makeAuthHeaders(config: config)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        // 自建 NAS 自签名证书场景
        let delegate = WebDAVTLSDelegate(allowSelfSigned: config.trustSelfSigned)
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - 协议属性

    var isAvailable: Bool { config.isComplete }

    var rootDirectory: URL {
        // 返回伪 URL：webdav://host/<rootPath>/，仅用于内部拼接和 StorageService 的路径派生
        guard let base = config.normalizedBaseURL else {
            // 配置还没完成的 fallback：用本地临时占位
            return LocalFS().rootDirectory
        }
        let path = config.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? base : base.appendingPathComponent(path, isDirectory: true)
    }

    var displayLocation: String {
        guard let host = config.normalizedBaseURL?.host ?? URL(string: config.serverURL)?.host else {
            return "🥇 WebDAV（未配置）"
        }
        return "🥇 WebDAV ▸ \(host) \(config.rootPath)"
    }

    // MARK: - 协议方法

    func fileExists(at url: URL) -> Bool {
        let sema = DispatchSemaphore(value: 0)
        var exists = false
        let req = request(url: url, method: "PROPFIND", headers: ["Depth": "0"])
        session.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                exists = true
            }
            sema.signal()
        }.resume()
        sema.wait()
        return exists
    }

    func createDirectoryIfNeeded(at url: URL) throws {
        guard !fileExists(at: url) else { return }
        // 递归向上建：先建父，再建自己
        let parent = url.deletingLastPathComponent()
        if parent.pathComponents.count > 2, !fileExists(at: parent) {
            try createDirectoryIfNeeded(at: parent)
        }
        let req = request(url: url, method: "MKCOL")
        try sendBlockingRequest(req, allowedStatus: [201, 301, 405])
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let req = request(url: url, method: "PROPFIND", headers: ["Depth": "1"])
        let data = try sendBlockingRequest(req, allowedStatus: [200, 207])
        let delegate = DAVPropfindParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let base = config.normalizedBaseURL else { return [] }
        // 当前目录规范化路径（确保以 / 结尾）
        let selfPath = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return delegate.items.compactMap { item in
            // 用原始编码的 href 构造 URL（中文路径不会被静默丢弃）
            guard let fullURL = URL(string: item.href, relativeTo: base)?.absoluteURL else { return nil }
            // 跳过目录自身
            guard fullURL.path != url.path else { return nil }
            // ✅ 正确的直接子项判断：子项的父路径 == 当前目录路径
            //    （旧代码用 hasSuffix(url.path)，子文件路径以文件名结尾，永远匹配不上）
            let parentPath = (fullURL.path as NSString).deletingLastPathComponent + "/"
            guard parentPath == selfPath else { return nil }
            return fullURL
        }
    }

    func readData(at url: URL) throws -> Data {
        let req = request(url: url, method: "GET")
        return try sendBlockingRequest(req, allowedStatus: [200])
    }

    func writeData(_ data: Data, to url: URL) throws {
        try createDirectoryIfNeeded(at: url.deletingLastPathComponent())
        var req = request(url: url, method: "PUT")
        req.httpBody = data
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        _ = try sendBlockingRequest(req, allowedStatus: [200, 201, 204])
    }

    func removeItem(at url: URL) throws {
        guard fileExists(at: url) else { return }
        let req = request(url: url, method: "DELETE")
        _ = try sendBlockingRequest(req, allowedStatus: [200, 204, 404])
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try createDirectoryIfNeeded(at: dstURL.deletingLastPathComponent())
        guard let destAbsolute = dstURL.absoluteString.removingPercentEncoding else {
            throw WebDAVError.invalidDestinationURL
        }
        var req = request(url: srcURL, method: "COPY")
        req.setValue(destAbsolute, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        _ = try sendBlockingRequest(req, allowedStatus: [200, 201, 204, 207])
    }

    // MARK: - 辅助工具

    enum WebDAVError: LocalizedError {
        case httpError(Int, String)
        case invalidDestinationURL
        case incompleteConfig

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                let preview = body.count > 300 ? String(body.prefix(300)) : body
                return "WebDAV HTTP 错误 \(code)：\(preview)"
            case .invalidDestinationURL: return "WebDAV 目标 URL 编码失败"
            case .incompleteConfig: return "WebDAV 配置不完整（地址/用户名/密码必填）"
            }
        }
    }

    private func request(url: URL, method: String, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    @discardableResult
    private func sendBlockingRequest(_ request: URLRequest, allowedStatus: Set<Int>) throws -> Data {
        guard config.isComplete else { throw WebDAVError.incompleteConfig }
        let sema = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResp: URLResponse?
        var outError: Error?
        session.dataTask(with: request) { d, r, e in
            outData = d; outResp = r; outError = e
            sema.signal()
        }.resume()
        sema.wait()
        if let e = outError { throw e }
        guard let http = outResp as? HTTPURLResponse else {
            throw WebDAVError.httpError(0, "No HTTP response")
        }
        if !allowedStatus.contains(http.statusCode) {
            let body = outData.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
            throw WebDAVError.httpError(http.statusCode, body)
        }
        return outData ?? Data()
    }

    // MARK: - Basic Authorization Header

    private static func makeAuthHeaders(config: WebDAVConfig) -> [String: String] {
        var headers = ["User-Agent": "AnkiNotes-WebDAV-Client/1.0"]
        guard !config.username.isEmpty,
              let pwd = KeychainHelper.webDAVPassword(), !pwd.isEmpty else {
            return headers
        }
        if let raw = "\(config.username):\(pwd)".data(using: .utf8) {
            let base64 = raw.base64EncodedString()
            headers["Authorization"] = "Basic \(base64)"
        }
        return headers
    }

    // MARK: - TLS Delegate（支持自签名证书，用于自建 NAS）

    private final class WebDAVTLSDelegate: NSObject, URLSessionDelegate {
        let allowSelfSigned: Bool
        init(allowSelfSigned: Bool) { self.allowSelfSigned = allowSelfSigned }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if allowSelfSigned, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    // MARK: - PROPFIND XML 解析器（取 href + 区分 collection 文件夹）
    private final class DAVPropfindParser: NSObject, XMLParserDelegate {
        struct Item { let href: String; let isCollection: Bool }
        var items: [Item] = []
        private var inHref = false
        private var currentHref = ""
        private var currentIsCollection = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let lower = elementName.lowercased()
            if lower.hasSuffix("href") {
                inHref = true
                currentHref = ""
            }
            // 每个 <d:response> 开始时重置 collection 标记
            if lower.hasSuffix("response") {
                currentIsCollection = false
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inHref { currentHref.append(string) }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let lower = elementName.lowercased()
            if lower.hasSuffix("href") {
                inHref = false
            }
            // <d:collection/> 出现在 resourcetype 内 → 是文件夹
            if lower.hasSuffix("collection") {
                currentIsCollection = true
            }
            // 每个 <d:response> 结束时收集一条
            if lower.hasSuffix("response") {
                if !currentHref.isEmpty {
                    // ❗ 保留原始百分号编码，不解码（避免中文路径 URL(string:) 返回 nil）
                    items.append(Item(href: currentHref, isCollection: currentIsCollection))
                }
                currentHref = ""
                currentIsCollection = false
            }
        }
    }

    /// 列出目录子项，同时返回哪些是文件夹（供 StorageService 递归扫描用，避免靠 hack 判断）
    func contentsOfDirectoryWithTypes(at url: URL) throws -> [(url: URL, isDirectory: Bool)] {
        let req = request(url: url, method: "PROPFIND", headers: ["Depth": "1"])
        let data = try sendBlockingRequest(req, allowedStatus: [200, 207])
        let delegate = DAVPropfindParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let base = config.normalizedBaseURL else { return [] }
        // 当前目录规范化路径（确保以 / 结尾）
        let selfPath = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return delegate.items.compactMap { item in
            // 用原始编码的 href 构造 URL（中文路径不会被静默丢弃）
            guard let fullURL = URL(string: item.href, relativeTo: base)?.absoluteURL else { return nil }
            // 跳过目录自身
            guard fullURL.path != url.path else { return nil }
            // ✅ 正确的直接子项判断：子项的父路径 == 当前目录路径
            let parentPath = (fullURL.path as NSString).deletingLastPathComponent + "/"
            guard parentPath == selfPath else { return nil }
            return (fullURL, item.isCollection)
        }
    }
}

// MARK: - 8. Provider Factory（根据类型 + 配置创建 CloudFileSystem 实例）

enum CloudProviderFactory {
    static func makeFileSystem(for type: CloudProviderType, webDAVConfig: WebDAVConfig? = nil) -> CloudFileSystem {
        switch type {
        case .local:  return LocalFS()
        case .iCloud: return ICloudFS()
        case .webDAV: return WebDAVFS(config: webDAVConfig ?? WebDAVConfig())
        }
    }
}
