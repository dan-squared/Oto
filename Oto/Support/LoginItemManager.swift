//
//  LoginItemManager.swift
//  Oto
//

import Foundation
import ServiceManagement

/// Launch-at-login behind a protocol: `SMAppService` is final, so Settings
/// and tests program to `LoginItemManaging` (fake in tests). No entitlement
/// is needed for the main app; device matrix confirms register/unregister.
/// Four states, never two: `.requiresApproval` (user revoked consent) and
/// `.notFound` (service lookup failed — seen in non-app hosts) must render
/// guidance, never a lying spinner.
protocol LoginItemManaging: Sendable {
    func status() -> SMAppService.Status
    func setEnabled(_ enabled: Bool) throws
}

struct LiveLoginItemManager: LoginItemManaging {
    private let service = SMAppService.mainApp

    func status() -> SMAppService.Status {
        service.status
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
