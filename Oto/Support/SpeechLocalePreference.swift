//
//  SpeechLocalePreference.swift
//  Oto
//
//  User-selected dictation locale preference ("System" by default, or an
//  explicit BCP-47 identifier). Read by both the live dictation path
//  (`AppleSpeechService`) and Settings readiness/preparation
//  (`SpeechAssetPreparer`, `SettingsUIState`).
//

import Foundation

nonisolated enum SpeechLocalePreference: Sendable {
    nonisolated static let defaultsKey = "app.Oto.speechLocaleIdentifier"
    nonisolated static let systemTag = ""

    /// Canonicalizes a non-empty locale identifier to BCP-47 so stored tags
    /// (e.g. `"en_US"` vs `"en-US"`) always match Picker tags and menu state.
    nonisolated static func canonicalIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bcp47 = Locale(identifier: trimmed).identifier(.bcp47)
        return bcp47.isEmpty ? trimmed : bcp47
    }

    /// Returns the stored canonical BCP-47 locale identifier, or `nil` when
    /// unset or whitespace-only (meaning "follow the system locale").
    nonisolated static func selectedIdentifier(defaults: UserDefaults = .standard) -> String? {
        canonicalIdentifier(defaults.string(forKey: defaultsKey))
    }

    /// Persists `identifier` (canonicalized to BCP-47, or clears the override
    /// when `nil`/empty) and invalidates `cache` whenever the normalized
    /// selection actually changes.
    nonisolated static func setSelectedIdentifier(
        _ identifier: String?,
        defaults: UserDefaults = .standard,
        cache: LocaleSnapshotCache = .shared
    ) {
        let normalized = canonicalIdentifier(identifier)
        let previous = selectedIdentifier(defaults: defaults)

        if let normalized {
            defaults.set(normalized, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }

        if normalized != previous {
            cache.invalidate()
        }
    }

    /// Resolves the active dictation locale: the user's explicit selection if
    /// set, otherwise `system`.
    nonisolated static func effectiveLocale(
        system: Locale = .current,
        defaults: UserDefaults = .standard
    ) -> Locale {
        if let id = selectedIdentifier(defaults: defaults) {
            return Locale(identifier: id)
        }
        return system
    }

    /// Clean human-readable display name for `locale` in `displayLocale`,
    /// built strictly from `language.languageCode` and `language.region` so
    /// user country extensions (e.g. `-u-rg-etzzzz`) never leak into labels.
    nonisolated static func displayName(
        for locale: Locale,
        includeRegion: Bool = true,
        in displayLocale: Locale = .current
    ) -> String {
        guard let languageCode = locale.language.languageCode?.identifier, !languageCode.isEmpty else {
            return locale.identifier(.bcp47)
        }
        if languageCode.lowercased() == "mul" {
            return "Multilingual"
        }
        guard let rawLanguage = displayLocale.localizedString(forLanguageCode: languageCode),
              !rawLanguage.isEmpty
        else {
            return locale.identifier(.bcp47)
        }
        let languageName = String(rawLanguage.prefix(1)).uppercased(with: displayLocale) + rawLanguage.dropFirst()

        guard includeRegion,
              let regionCode = locale.language.region?.identifier,
              !regionCode.isEmpty
        else {
            return languageName
        }

        let regionLabel: String?
        switch regionCode.uppercased() {
        case "US":
            regionLabel = "US"
        case "GB":
            regionLabel = "UK"
        default:
            regionLabel = displayLocale.localizedString(forRegionCode: regionCode)
        }

        if let regionLabel, !regionLabel.isEmpty {
            return "\(languageName) (\(regionLabel))"
        }
        return languageName
    }

    /// Maps each unique locale's BCP-47 tag to a clean display label, including
    /// concise region tags only when multiple locales share the same language.
    nonisolated static func displayNames(
        for locales: [Locale],
        in displayLocale: Locale = .current
    ) -> [String: String] {
        var seen = Set<String>()
        var unique: [Locale] = []
        unique.reserveCapacity(locales.count)
        for locale in locales {
            let tag = locale.identifier(.bcp47)
            if seen.insert(tag).inserted {
                unique.append(locale)
            }
        }

        var languageCounts: [String: Int] = [:]
        for locale in unique {
            if let code = locale.language.languageCode?.identifier {
                languageCounts[code, default: 0] += 1
            }
        }

        var names: [String: String] = [:]
        names.reserveCapacity(unique.count)
        for locale in unique {
            let tag = locale.identifier(.bcp47)
            let code = locale.language.languageCode?.identifier
            let includeRegion = code.map { (languageCounts[$0] ?? 0) > 1 } ?? true
            names[tag] = displayName(for: locale, includeRegion: includeRegion, in: displayLocale)
        }
        return names
    }

    /// Deduplicates `locales` by BCP-47 identifier and sorts alphabetically by
    /// `displayNames(for:in:)` (case-insensitive) with a BCP-47 tie-breaker.
    nonisolated static func dedupedSortedLocales(
        _ locales: [Locale],
        in displayLocale: Locale = .current
    ) -> [Locale] {
        var seen = Set<String>()
        var unique: [Locale] = []
        unique.reserveCapacity(locales.count)
        for locale in locales {
            let tag = locale.identifier(.bcp47)
            if seen.insert(tag).inserted {
                unique.append(locale)
            }
        }
        let names = displayNames(for: unique, in: displayLocale)
        return unique.sorted { lhs, rhs in
            let lhsTag = lhs.identifier(.bcp47)
            let rhsTag = rhs.identifier(.bcp47)
            let lhsName = names[lhsTag] ?? displayName(for: lhs, in: displayLocale)
            let rhsName = names[rhsTag] ?? displayName(for: rhs, in: displayLocale)
            let order = lhsName.compare(rhsName, options: [.caseInsensitive], locale: displayLocale)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhsTag < rhsTag
        }
    }
}
