import SwiftUI

/// 豆仓的颜色：石墨底、暖白字，琥珀色是唯一的强调色；红色只留给「正在录音」。不用蓝和紫。
nonisolated enum Theme {
    #if os(macOS)
    static let amber = Color("AccentColor")
    #else
    /// 手机上直接写在代码里（和资源目录里的 AccentColor 同一组数），这样不依赖资源目录也能显示对。
    static let amber = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.0, green: 0.70, blue: 0.24, alpha: 1)
        : UIColor(red: 0.84, green: 0.52, blue: 0.08, alpha: 1) })
    #endif
    static let rec = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let graphite = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.87)
    /// 「没问题」的颜色：一种不扎眼的绿，只用在已连接、已就绪这类状态上。
    static let ok = Color(red: 0.42, green: 0.72, blue: 0.47)
    /// 区分说话人用的一组颜色：都在暖色和中性色里选。
    static let speakers: [Color] = [
        Color(red: 0.93, green: 0.62, blue: 0.16),   // 琥珀
        Color(red: 0.86, green: 0.38, blue: 0.30),   // 珊瑚
        Color(red: 0.42, green: 0.62, blue: 0.40),   // 鼠尾草绿
        Color(red: 0.66, green: 0.54, blue: 0.38),   // 沙
        Color(red: 0.70, green: 0.36, blue: 0.20),   // 赭
        Color(red: 0.52, green: 0.50, blue: 0.47),   // 暖灰
    ]
}

extension AppSettings.Appearance {
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}
