//  MARK: - 跨页面共享的辅助组件（ReviewHomeView / StatsView / 其他页面复用）
//
//  SharedViews.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

// MARK: - 通用类型扩展

/// 让 UUID 支持 SwiftUI sheet(item:) 的 Identifiable 约束
extension UUID: Identifiable {
    public var id: UUID { self }
}

// MARK: - 7 日复习柱状图

struct WeeklyChartView: View {
    let counts: [Int]
    
    var body: some View {
        let max = max(counts.max() ?? 0, 1)
        let labels = dayLabels()
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7) { idx in
                    VStack(spacing: 4) {
                        Text("\(counts[idx])")
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: counts[idx] > 0
                                        ? [.blue, .purple]
                                        : [.gray.opacity(0.3), .gray.opacity(0.3)],
                                    startPoint: .bottom, endPoint: .top)
                            )
                            .frame(height: geo.size.height * 0.65 * CGFloat(counts[idx]) / CGFloat(max))
                        Text(labels[idx])
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
    private func dayLabels() -> [String] {
        let cal = Calendar.current
        return (0..<7).map { offset in
            guard let d = cal.date(byAdding: .day, value: -(6 - offset), to: Date()) else { return "" }
            let symbols = cal.shortWeekdaySymbols
            let idx = cal.component(.weekday, from: d) - 1
            return symbols[idx]
        }
    }
}

// MARK: - 卡片状态分布（条形 + 图例）

struct StatusDistributionView: View {
    let stats: StatsSummary
    
    var body: some View {
        let total = max(stats.totalNotes, 1)
        let data: [(label: String, value: Int, color: Color)] = [
            ("新卡片", stats.newCount, .blue),
            ("学习中", stats.learningCount, .orange),
            ("已掌握", stats.masteredCount, .green),
            ("复习中", max(0, stats.totalNotes - stats.newCount - stats.learningCount - stats.masteredCount), .purple)
        ]
        VStack(spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(data, id: \.label) { d in
                        let width = CGFloat(d.value) / CGFloat(total) * geo.size.width
                        if d.value > 0 {
                            Rectangle()
                                .fill(d.color)
                                .frame(width: width)
                        }
                    }
                }
                .cornerRadius(6)
                .frame(height: 10)
            }
            HStack(spacing: 8) {
                ForEach(data, id: \.label) { d in
                    HStack(spacing: 4) {
                        Circle().fill(d.color).frame(width: 8, height: 8)
                        Text("\(d.label) \(d.value)")
                            .textStyle(.tertiaryText)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 大数值统计卡

struct BigStat: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                Spacer()
                Text(value)
                    .textStyle(.screenTitle)
            }
            Text(title)
                .textStyle(.secondaryText)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

// MARK: - 分布小卡片

struct DistributionCard: View {
    let title: String
    let value: Int
    let total: Int
    let color: Color
    let systemImage: String
    
    var body: some View {
        let ratio = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                    .textStyle(.subsectionTitle)
                Spacer()
                Text("\(value)")
                    .textStyle(.primaryText)
            }
            Text(title)
                .textStyle(.tertiaryText)
                .foregroundColor(.secondary)
            ProgressView(value: ratio)
                .tint(color)
                .scaleEffect(x: 1, y: 1.5)
            Text(String(format: "%.0f%%", ratio * 100))
                .textStyle(.tertiaryText)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.08))
        )
    }
}

// MARK: - 首页复习卡片统计小方块

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color
    var highlight: Bool = false
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(highlight ? 0.2 : 0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: systemImage)
                    .foregroundColor(color)
                    .textStyle(.subsectionTitle)
            }
            Text(value)
                .textStyle(.subsectionTitle)
            Text(title)
                .textStyle(.tertiaryText)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - 空状态视图（兼容 iOS 16）
/// 系统 ContentUnavailableView 仅 iOS 17+ 可用，这里做向后兼容包装：
/// - iOS 17+ → 直接调用原生 ContentUnavailableView（保留视差动画等效果）
/// - iOS 16   → 用 VStack + Image + Text 模拟相同外观
struct EmptyStateView: View {
    private let title: String
    private let systemImage: String
    private let description: Text?
    
    /// 空状态 + 描述文字（Text 类型，可自定义样式）
    init(_ title: String, systemImage: String, description: Text?) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }
    
    /// 仅有标题和图标的空状态
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
        self.description = nil
    }
    
    var body: some View {
        if #available(iOS 17.0, *) {
            if let description = description {
                ContentUnavailableView(
                    title,
                    systemImage: systemImage,
                    description: description
                )
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            // iOS 16 Fallback（视觉上尽量对齐 iOS 17 原生样式）
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .textStyle(.screenTitle)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .textStyle(.sectionTitle)
                    .multilineTextAlignment(.center)
                if let description = description {
                    description
                        .textStyle(.secondaryText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - 全局 TextStyle 语义字号系统（比 iOS 默认大 1-2 档，配合 AppState.textScale 全局缩放）

/// 统一的语义化文字大小（避免直接写 .font(.caption/.caption2) 导致整体偏小不协调）
/// 默认已比 iOS 同语义系统字号大 1-2pt；再通过 Environment(\.textScale) 实现 4 档全局放大缩小
enum TextStyle {
    case screenTitle        // 30 pt semibold → 主页面大数字（连续打卡天数等）
    case sectionTitle       // 20 pt semibold → Section 标题（"近7天复习"/"卡片预览"）
    case subsectionTitle    // 18 pt semibold → 子区块标题（正面/背面）
    case primaryText        // 17 pt semibold → 列表项大标题 / 重要数值
    case body               // 17 pt regular   → 正文
    case secondaryText      // 15 pt regular   → 辅助说明（原来的 caption/subheadline）
    case tertiaryText       // 13 pt regular   → 次要说明（原来的 caption2）
    case miniText           // 12 pt regular   → 日期/小标签/评分间隔

    /// 默认 size pt（不缩放时）
    var baseSize: CGFloat {
        switch self {
        case .screenTitle:     return 30
        case .sectionTitle:    return 20
        case .subsectionTitle: return 18
        case .primaryText, .body: return 17
        case .secondaryText:   return 15
        case .tertiaryText:    return 13
        case .miniText:        return 12
        }
    }

    /// 默认字重
    var weight: Font.Weight {
        switch self {
        case .screenTitle, .sectionTitle, .subsectionTitle, .primaryText: return .semibold
        case .body, .secondaryText, .tertiaryText, .miniText: return .regular
        }
    }
}

/// 缩放修饰器：读取 Environment 的 textScale（从 AppState 注入），对 size 线性缩放
struct TextStyleModifier: ViewModifier {
    let style: TextStyle
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let size = style.baseSize * CGFloat(scale)
        return content.font(.system(size: size, weight: style.weight, design: .rounded))
    }
}

/// 便捷用法：`.textStyle(.sectionTitle)`
extension View {
    func textStyle(_ style: TextStyle) -> some View {
        modifier(TextStyleModifier(style: style))
    }
}
