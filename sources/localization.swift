import Foundation

private final class LocalizationBundleToken: NSObject {}

enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments)
    }

    static func format(_ key: String, _ arguments: [CVarArg]) -> String {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}
