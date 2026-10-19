//
//  AXDump.swift
//  Oto
//
//  DEV DIAGNOSTIC, launch-argument only: `--ax-dump[=<bundle-id>|pid]`.
//  Prints the target's accessibility tree to stderr and exits before any
//  scene is built. It exists because the only AX-trusted binary on the
//  machine is this app: a shell or probe script answers kAXErrorAPIDisabled
//  (-25211) for everything.
//
//  Read-only. Never runs unless the argument is present, never touches
//  Oto state, and exits in `init` so no menu-bar item, hotkey or window is
//  ever created. Modelled on CleanSlate's explicit-opt-in launch argument.
//

import ApplicationServices
import AppKit
import Foundation

enum AXDump {
    nonisolated static let launchArgument = "--ax-dump"
    nonisolated static let maxNodes = 400
    nonisolated static let maxDepth = 12
    nonisolated static let maxChildrenPerNode = 30

    /// Dumps and exits when requested; returns immediately otherwise.
    nonisolated static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let arg = arguments.first(where: {
            $0 == launchArgument || $0.hasPrefix(launchArgument + "=")
        }) else { return }
        let spec = arg.contains("=") ? String(arg.split(separator: "=", maxSplits: 1)[1]) : ""
        let pid = resolvePID(spec)
        emit("axdump trusted=\(AXIsProcessTrusted()) target=\(spec.isEmpty ? "frontmost" : spec) pid=\(pid)")
        if pid > 0 { dump(pid: pid) }
        emit("axdump end")
        exit(0)
    }

    nonisolated private static func resolvePID(_ spec: String) -> pid_t {
        if let pid = pid_t(spec), pid > 0 { return pid }
        if spec.isEmpty {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: spec)
            .first?.processIdentifier ?? -1
    }

    nonisolated private static func dump(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        emit("app role=\(stringAttr(app, kAXRoleAttribute) ?? "nil")")
        if let focused = elementAttr(app, kAXFocusedUIElementAttribute) {
            emit("focusedElement \(describe(focused))")
            emit("focused editableAncestor=\(elementAttr(focused, kAXEditableAncestorAttribute).map { describe($0) } ?? "nil")")
            emit("focused focusableAncestor=\(elementAttr(focused, kAXFocusableAncestorAttribute).map { describe($0) } ?? "nil")")
            emit("focused parent=\(elementAttr(focused, kAXParentAttribute).map { describe($0) } ?? "nil")")
            emit("focused webContent=\(EditableFocus.webContentHidesEditable(element: focused))")

            var chain: [String] = []
            var cursor: AXUIElement? = focused
            var hops = 0
            while let node = cursor, hops < 8 {
                chain.append(stringAttr(node, kAXRoleAttribute) ?? "nil")
                cursor = elementAttr(node, kAXParentAttribute)
                hops += 1
            }
            emit("ancestors \(chain.joined(separator: " < "))")
        } else {
            // Expected while the app is inactive: the focused element only
            // exists for the active app. The window tree below still shows
            // whether an editable surface exists at all.
            emit("focusedElement=nil (app likely inactive)")
        }

        guard let window = elementAttr(app, kAXFocusedWindowAttribute)
            ?? elementAttr(app, kAXMainWindowAttribute)
        else {
            emit("window=nil (tree not dumped)")
            return
        }
        emit("window \(describe(window))")
        var visited = 0
        walk(window, depth: 0, visited: &visited)
    }

    nonisolated private static func walk(_ node: AXUIElement, depth: Int, visited: inout Int) {
        guard visited < maxNodes, depth <= maxDepth else { return }
        visited += 1
        let indent = String(repeating: "  ", count: depth)
        emit("\(indent)\(describe(node))")
        // Which elements publish a verifiable caret? Text roles always do
        // (the attribute is required); anything else that answers here is a
        // web host exposing a range on a non-text role — exactly the case a
        // false "not landed" would come from, so it must be visible.
        let sample = LiveDeliveryCheck.sample(node)
        if sample != nil || EditableFocus.textCapableRoles.contains(
            stringAttr(node, kAXRoleAttribute) ?? ""
        ) {
            emit("\(indent)  ▸ delivery sample=\(String(describing: sample))")
        }
        guard depth < maxDepth else { return }
        let kids = childrenOf(node)
        for kid in kids.prefix(maxChildrenPerNode) {
            walk(kid, depth: depth + 1, visited: &visited)
        }
        if kids.count > maxChildrenPerNode {
            emit("\(indent)  … \(kids.count - maxChildrenPerNode) more children")
        }
    }

    /// One compact line per element: the fields that discriminate a caret
    /// host from a plain control.
    nonisolated private static func describe(_ node: AXUIElement) -> String {
        var parts: [String] = []
        parts.append("role=\(stringAttr(node, kAXRoleAttribute) ?? "nil")")
        if let subrole = stringAttr(node, kAXSubroleAttribute) { parts.append("sub=\(subrole)") }
        if let title = stringAttr(node, kAXTitleAttribute), !title.isEmpty {
            parts.append("title=\"\(title.prefix(40))\"")
        }
        if let desc = stringAttr(node, kAXDescriptionAttribute), !desc.isEmpty {
            parts.append("desc=\"\(desc.prefix(40))\"")
        }
        if let dom = stringAttr(node, kAXDOMIdentifierAttribute), !dom.isEmpty {
            parts.append("dom=\(dom.prefix(30))")
        }
        if let editable = boolAttr(node, kAXIsEditableAttribute) { parts.append("editable=\(editable)") }
        if let focused = boolAttr(node, kAXFocusedAttribute) { parts.append("focused=\(focused)") }
        parts.append("selRange=\(elementAttr(node, kAXSelectedTextRangeAttribute) != nil)")
        parts.append("kids=\(childrenOf(node).count)")
        return parts.joined(separator: " ")
    }

    nonisolated private static func stringAttr(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    nonisolated private static func boolAttr(_ node: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    nonisolated private static func elementAttr(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    nonisolated private static func childrenOf(_ node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return [] }
        return list
    }

    nonisolated private static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
