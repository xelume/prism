import Foundation

private final class LocalizationBundleToken: NSObject {}

/// Resolves literal catalog keys from the app or test bundle, preserving printf-style arguments.
/// LocalizedStringResource lets Xcode extract references at each literal call site.
enum L10n {
    static func text(_ key: LocalizedStringResource, _ arguments: CVarArg...) -> String {
        format(key, arguments)
    }

    static func format(_ key: LocalizedStringResource, _ arguments: [CVarArg]) -> String {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let value = bundle.localizedString(forKey: key.key, value: nil, table: "Localizable")
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}
