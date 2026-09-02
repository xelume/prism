import Foundation

enum StatusBarUsageMode: String, CaseIterable {
    case off
    case brief
    case all

    var menuTitle: String {
        switch self {
        case .off: return "关闭"
        case .brief: return "简略"
        case .all: return "全部"
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
            if ["fiveHour", "week"].contains(value) { return .brief }
            if value == "both" { return .all }
            return StatusBarUsageMode(rawValue: value) ?? .off
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

struct StatusBarUsageTitle {
    static func make(mode: StatusBarUsageMode, usage: AccountUsage?) -> String? {
        guard mode != .off, let usage else { return nil }
        let parts = UsageWindowKind.allCases.compactMap { kind -> String? in
            guard let window = kind.window(in: usage) else { return nil }
            return "\(kind.label) \(window.remainingPercent)%"
        }
        guard !parts.isEmpty else { return nil }
        return mode == .brief ? parts.first : parts.joined(separator: " · ")
    }
}

enum UsageWindowKind: CaseIterable {
    case fiveHour
    case week
    case month

    var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .week: return "7d"
        case .month: return "1mo"
        }
    }

    func window(in usage: AccountUsage?) -> UsageWindow? {
        switch self {
        case .fiveHour: return usage?.fiveHour
        case .week: return usage?.week
        case .month: return usage?.month
        }
    }
}

struct UsageMenuTitle {
    static func make(kind: UsageWindowKind, window: UsageWindow, now: Date,
                     timeZone: TimeZone = .current) -> String {
        let reset = window.resetsAt.map {
            resetTitle(kind: kind, reset: $0, now: now, timeZone: timeZone)
        } ?? "--"
        return "\(kind.label) \(window.remainingPercent)% · \(reset)"
    }

    private static func resetTitle(kind: UsageWindowKind, reset: TimeInterval, now: Date,
                                   timeZone: TimeZone) -> String {
        if kind == .fiveHour {
            let seconds = reset - now.timeIntervalSince1970
            guard seconds > 0 else { return "--" }
            let minutes = Int(ceil(seconds / 60))
            guard minutes >= 60 else { return "\(minutes)m" }
            let hours = minutes / 60
            let remainder = minutes % 60
            return "\(hours)h" + (remainder == 0 ? "" : "\(remainder)m")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: reset))
    }
}
