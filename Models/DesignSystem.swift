//
//  DesignSystem.swift
//  AnkiNotes
//
//  统一设计系统：颜色、字体、间距、圆角、阴影、透明度规范
//  所有 UI 组件应优先使用本文件定义的常量，避免硬编码
//

import SwiftUI

// MARK: - 颜色规范

extension Color {
    // MARK: 品牌主色
    /// 品牌主色 - 橙色
    static let brandPrimary = Color.orange
    /// 品牌主色 - 浅橙（用于背景）
    static let brandPrimaryLight = Color.orange.opacity(0.08)
    /// 品牌主色 - 中橙（用于选中背景）
    static let brandPrimaryMedium = Color.orange.opacity(0.15)
    
    // MARK: 语义色 - 状态反馈
    /// 成功状态
    static let semanticSuccess = Color.green
    /// 成功状态 - 浅背景
    static let semanticSuccessLight = Color.green.opacity(0.08)
    /// 错误状态
    static let semanticError = Color.red
    /// 错误状态 - 浅背景
    static let semanticErrorLight = Color.red.opacity(0.08)
    /// 警告状态
    static let semanticWarning = Color.yellow
    /// 警告状态 - 浅背景
    static let semanticWarningLight = Color.yellow.opacity(0.08)
    /// 信息状态
    static let semanticInfo = Color.blue
    /// 信息状态 - 浅背景
    static let semanticInfoLight = Color.blue.opacity(0.08)
    
    // MARK: 中性色 - 文字
    /// 主文字
    static let textPrimary = Color.primary
    /// 次文字
    static let textSecondary = Color.secondary
    /// 三级文字（占位符、时间戳）
    static let textTertiary = Color.secondary.opacity(0.7)
    
    // MARK: 中性色 - 背景
    /// 页面背景
    static let bgPage = Color(.systemGroupedBackground)
    /// 卡片背景
    static let bgCard = Color(.systemBackground)
    /// 输入框/搜索框背景
    static let bgInput = Color(.secondarySystemBackground)
    
    // MARK: 中性色 - 边框和分割线
    /// 边框
    static let border = Color.secondary.opacity(0.2)
    /// 分割线
    static let divider = Color.secondary.opacity(0.15)
    
    // MARK: 标准透明度层级
    /// 极浅背景（按钮、标签）
    static let opacityBg: Double = 0.08
    /// 浅背景（选中、高亮）
    static let opacitySelected: Double = 0.12
    /// 中背景（强调）
    static let opacityEmphasis: Double = 0.15
    /// 边框透明度
    static let opacityBorder: Double = 0.2
    /// 遮罩透明度
    static let opacityOverlay: Double = 0.4
}

// MARK: - 字体规范

extension Font {
    /// 大标题（页面标题）
    static let appTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    /// 一级标题（卡片标题）
    static let appHeading = Font.system(size: 20, weight: .semibold, design: .rounded)
    /// 二级标题（列表项标题）
    static let appSubheading = Font.system(size: 16, weight: .semibold, design: .rounded)
    /// 正文
    static let appBody = Font.system(size: 15, weight: .regular, design: .rounded)
    /// 辅助文字
    static let appCaption = Font.system(size: 13, weight: .regular, design: .rounded)
    /// 小字标签
    static let appTag = Font.system(size: 11, weight: .medium, design: .rounded)
    /// 极小文字
    static let appMicro = Font.system(size: 10, weight: .regular, design: .rounded)
}

// MARK: - 间距规范

enum AppSpacing {
    /// 极小间距 4pt
    static let xs: CGFloat = 4
    /// 小间距 8pt
    static let sm: CGFloat = 8
    /// 中间距 12pt
    static let md: CGFloat = 12
    /// 大间距 16pt
    static let lg: CGFloat = 16
    /// 超大间距 20pt
    static let xl: CGFloat = 20
    /// 特大间距 24pt
    static let xxl: CGFloat = 24
    /// 页面水平边距 16pt
    static let horizontal: CGFloat = 16
    /// 页面垂直边距 16pt
    static let vertical: CGFloat = 16
}

// MARK: - 圆角规范

enum AppCornerRadius {
    /// 极小圆角 4pt（标签、小按钮）
    static let xs: CGFloat = 4
    /// 小圆角 6pt（状态标签）
    static let sm: CGFloat = 6
    /// 中圆角 8pt（输入框、小卡片）
    static let md: CGFloat = 8
    /// 标准圆角 10pt（按钮、列表项）
    static let standard: CGFloat = 10
    /// 大圆角 12pt（卡片、弹窗）
    static let lg: CGFloat = 12
    /// 超大圆角 14pt（大按钮、大卡片）
    static let xl: CGFloat = 14
    /// 特大圆角 16pt（主卡片、底部弹窗）
    static let xxl: CGFloat = 16
    /// 巨大圆角 18pt（首页大卡片）
    static let huge: CGFloat = 18
}

// MARK: - 阴影规范

enum AppShadow {
    /// 轻微阴影（卡片悬浮）
    static let card = ShadowConfig(color: .black, opacity: 0.05, radius: 8, x: 0, y: 2)
    /// 中等阴影（弹窗、悬浮按钮）
    static let modal = ShadowConfig(color: .black, opacity: 0.1, radius: 16, x: 0, y: 4)
    /// 强调阴影（主操作按钮）
    static let emphasis = ShadowConfig(color: .black, opacity: 0.15, radius: 12, x: 0, y: 6)
}

struct ShadowConfig {
    let color: Color
    let opacity: Double
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    /// 应用标准卡片阴影
    func cardShadow() -> some View {
        self.shadow(color: AppShadow.card.color.opacity(AppShadow.card.opacity),
                    radius: AppShadow.card.radius,
                    x: AppShadow.card.x,
                    y: AppShadow.card.y)
    }
    
    /// 应用弹窗阴影
    func modalShadow() -> some View {
        self.shadow(color: AppShadow.modal.color.opacity(AppShadow.modal.opacity),
                    radius: AppShadow.modal.radius,
                    x: AppShadow.modal.x,
                    y: AppShadow.modal.y)
    }
}

// MARK: - 按钮高度规范（iOS HIG 标准）

enum AppButtonHeight {
    /// 标准按钮高度 44pt（iOS HIG 最小点击区域）
    static let standard: CGFloat = 44
    /// 小按钮高度 36pt（图标按钮、辅助操作）
    static let small: CGFloat = 36
    /// 大按钮高度 52pt（主操作按钮）
    static let large: CGFloat = 52
}

// MARK: - 统一按钮样式

struct AppButtonStyle: ButtonStyle {
    var isPrimary: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: AppButtonHeight.standard)
            .background(isPrimary ? Color.brandPrimary : Color.gray.opacity(AppSpacing.xs == 4 ? 0.08 : 0.08))
            .foregroundColor(isPrimary ? .white : .primary)
            .cornerRadius(AppCornerRadius.standard)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

// MARK: - 统一标签样式

struct AppTagStyle: ViewModifier {
    var color: Color = .secondary
    
    func body(content: Content) -> some View {
        content
            .font(.appTag)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(color.opacity(AppSpacing.xs == 4 ? 0.1 : 0.1))
            .foregroundColor(color)
            .cornerRadius(AppCornerRadius.sm)
    }
}

extension View {
    /// 应用标准标签样式
    func appTagStyle(color: Color = .secondary) -> some View {
        self.modifier(AppTagStyle(color: color))
    }
}

// MARK: - 统一卡片样式

struct AppCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.bgCard)
            .cornerRadius(AppCornerRadius.xl)
            .cardShadow()
    }
}

extension View {
    /// 应用标准卡片样式
    func appCardStyle() -> some View {
        self.modifier(AppCardStyle())
    }
}
