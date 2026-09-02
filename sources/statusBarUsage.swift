import Foundation

enum StatusBarUsageMode: String, CaseIterable {
    case off
    case fiveHour
    case week
    case both

    var menuTitle: String {
        switch self {
        case .off: return "关闭"
        case .fiveHour: return "5 小时额度"
        case .week: return "周额度"
        case .both: return "5 小时 + 周额度"
        }
    }
}

struct StatusBarUsagePreference {
    static let key = "statusBarUsageMode"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var mode: StatusBarUsageMode {
        get {
            guard let value = defaults.string(forKey: Self.key) else { return .off }
            return StatusBarUsageMode(rawValue: value) ?? .off
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

struct StatusBarUsageTitle {
    static func make(mode: StatusBarUsageMode, usage: AccountUsage?) -> String? {
        guard mode != .off, let usage else { return nil }
        var parts: [String] = []
        if mode == .fiveHour || mode == .both, let window = usage.fiveHour {
            parts.append("5h \(window.remainingPercent)%")
        }
        if mode == .week || mode == .both, let window = usage.week {
            parts.append("7d \(window.remainingPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
