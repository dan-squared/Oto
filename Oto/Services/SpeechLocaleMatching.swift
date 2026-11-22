//
//  SpeechLocaleMatching.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Maps the user's locale onto one a speech engine actually supports.
///
/// Technique adopted from the Yap reference (`SpeechLocale.swift` at
/// `/private/tmp/yap-reference`, MIT) as Oto-owned code: `Locale.current`
/// cannot be handed to a speech API verbatim. When system language and
/// region disagree, macOS represents that as `en_US@rg=eszzzz`, which
/// serializes to BCP-47 as `en-US-u-rg-eszzzz` — no engine lists that
/// string, so exact comparison wrongly concludes the language is
/// unsupported. Matching therefore widens in three steps: the exact tag,
/// then same language+region ignoring extensions, then same language in
/// any region.
enum SpeechLocaleMatching: Sendable {
    /// Pure widening match, no state: `nonisolated` for the background
    /// speech actor (Swift 6, default MainActor isolation).
    nonisolated static func bestMatch<Candidates: Sequence>(
        for locale: Locale,
        in candidates: Candidates
    ) -> Locale? where Candidates.Element == Locale {
        // `supportedLocales` is unordered, so sort to keep widened matches
        // stable from one launch to the next.
        let ordered = candidates.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }

        if let exact = ordered.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return exact
        }

        guard let language = locale.language.languageCode?.identifier else { return nil }

        // `locale.language.region`, not `locale.region`: the latter reports
        // the regional override rather than the region of the language.
        if let region = locale.language.region?.identifier,
           let regional = ordered.first(where: {
               $0.language.languageCode?.identifier == language
                   && $0.language.region?.identifier == region
           })
        {
            return regional
        }

        return ordered.first { $0.language.languageCode?.identifier == language }
    }
}
