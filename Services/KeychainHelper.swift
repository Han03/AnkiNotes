//
//  KeychainHelper.swift
//  AnkiNotes
//
//  Keychain 工具类，用于存储需要在 App 重装后保持不变的数据
//

import Foundation
import Security

/// Keychain 工具类
final class KeychainHelper {
    static let shared = KeychainHelper()
    
    private init() {}
    
    /// 保存字符串到 Keychain
    func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // 先删除旧值
        delete(forKey: key)
        
        // 添加新值
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain 保存失败 key=\(key), status=\(status)")
        }
    }
    
    /// 从 Keychain 读取字符串
    func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
    
    /// 从 Keychain 删除
    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
