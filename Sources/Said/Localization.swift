import Foundation

/// Localized UI text. The key *is* the English text (the fallback); translations live in
/// Resources/<lang>.lproj/Localizable.strings, picked by macOS from the system language.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string, e.g. L("Silent for %d min", 2).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: args)
}
