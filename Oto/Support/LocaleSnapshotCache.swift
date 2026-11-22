//
//  LocaleSnapshotCache.swift
//  Oto
//
//  P3 (plan/p3-locale-cache.md): cached locale resolution for the press path.
//
//  `AppleSpeechService.prepare()` awaited `supportedLocales` and
//  `installedLocales` on every key press. Those sets change at human speed
//  (OS updates, Settings language prepare), not per-dictation speed, so the
//  press path resolves from a fresh-enough snapshot and re-queries only when
//  the snapshot is provably stale.
//
//  Correctness is never traded: snapshot nil, expired, or unresolvable all
//  mean `.requery` (today's slow path, which produces the honest
//  `unsupportedLocale` readiness). P3.1 caches resolution ONLY — the
//  installed/asset probe stays per-session; P3.2 (probe skip) is data-gated.
//
//  Threading: lock-disciplined final class (`AudioFeedBox` precedent —
//  `nonisolated` everything, `NSLock` guards the one mutable slot). The fast
//  path performs ZERO awaits: no actor hop on the press path, ever.
//

import Foundation

/// Fresh-enough snapshot of the system's speech locale sets.
struct LocaleSnapshot: Equatable, Sendable {
    var supported: [Locale]
    var installed: [Locale]
    var takenAt: ContinuousClock.Instant
}

/// The pure press-path decision: resolve from snapshot or pay the awaits.
enum LocaleCacheDecision: Equatable {
    case use(Locale)
    case requery
}

/// Hidden A/B seam (P3 flag): `defaults write app.Oto.localeCache -bool YES`
/// + relaunch flips the press path onto the snapshot; default false means
/// this whole file is inert until the matrix proves `localeResolve ≈ 0ms`.
/// Shape copied from `InsertionExperiment.current()`.
struct LocaleCacheExperiment: Sendable, Equatable {
    var enabled: Bool

    nonisolated static let enabledKey = "app.Oto.localeCache"

    nonisolated static func current(defaults: UserDefaults = .standard) -> LocaleCacheExperiment {
        LocaleCacheExperiment(enabled: defaults.bool(forKey: enabledKey))
    }
}

extension Notification.Name {
    /// Posted by `LocaleSnapshotCache.invalidate()` (any cause: system locale
    /// change, Settings prepare, expiry is lazy). P2 observes this to drop
    /// its warm analyzer — the cross-plan invalidation contract. Posted on
    /// the invalidating thread; observers must not do UI work inline.
    nonisolated static let otoSpeechLocaleInvalidated = Notification.Name("app.Oto.speechLocaleInvalidated")
}

final class LocaleSnapshotCache: @unchecked Sendable {
    /// Product singleton: one snapshot for the process. Tests use fresh
    /// instances (`LocaleSnapshotCache()`) so no test can poison another.
    nonisolated(unsafe) static let shared = LocaleSnapshotCache()

    /// Starting cap: a missed invalidation can only lie for minutes, never
    /// for a launch lifetime. Tuned by P1 session-spacing data.
    nonisolated static let maxAgeLimit: Duration = .seconds(600)

    private let lock = NSLock()
    private nonisolated(unsafe) var snapshot: LocaleSnapshot? = nil
    private nonisolated(unsafe) var observer: NSObjectProtocol? = nil

    nonisolated init(notificationCenter: NotificationCenter = .default) {
        observer = notificationCenter.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Pure decision — exhaustively unit-tested, no system calls.
    /// Matching ALWAYS goes through `SpeechLocaleMatching.bestMatch`
    /// (never re-implemented here).
    nonisolated static func decide(
        current: Locale,
        snapshot: LocaleSnapshot?,
        now: ContinuousClock.Instant
    ) -> LocaleCacheDecision {
        guard let snapshot else { return .requery }
        guard snapshot.takenAt.duration(to: now) <= maxAgeLimit else { return .requery }
        guard let match = SpeechLocaleMatching.bestMatch(for: current, in: snapshot.supported) else {
            // Slow path produces the honest `unsupportedLocale` readiness.
            return .requery
        }
        return .use(match)
    }

    /// Press-path read: zero awaits on either outcome.
    nonisolated func resolve(
        current: Locale = .current,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> LocaleCacheDecision {
        lock.lock()
        let snap = snapshot
        lock.unlock()
        return Self.decide(current: current, snapshot: snap, now: now)
    }

    nonisolated func store(supported: [Locale], installed: [Locale], takenAt: ContinuousClock.Instant = ContinuousClock.now) {
        lock.lock()
        snapshot = LocaleSnapshot(supported: supported, installed: installed, takenAt: takenAt)
        lock.unlock()
    }

    /// Any cause → snapshot = nil (next press requeries) + post the P2
    /// contract notification. Idempotent.
    nonisolated func invalidate() {
        lock.lock()
        snapshot = nil
        lock.unlock()
        NotificationCenter.default.post(name: .otoSpeechLocaleInvalidated, object: nil)
    }
}
