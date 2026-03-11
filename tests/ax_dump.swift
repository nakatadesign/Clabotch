#!/usr/bin/env swift
// AX 属性ダンプスクリプト — Warp の tentativeBundles 昇格判断用
// 使い方: swift tests/ax_dump.swift <PID>
// Warp を起動した状態で: swift tests/ax_dump.swift $(pgrep -x Warp)

import AppKit

guard CommandLine.arguments.count > 1,
      let pid = pid_t(CommandLine.arguments[1]) else {
    print("Usage: swift ax_dump.swift <PID>")
    exit(1)
}

// AX 権限チェック
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("ERROR: AX 権限が付与されていません。システム設定 → プライバシーとセキュリティ → アクセシビリティ で許可してください")
    exit(1)
}

// アプリ情報
if let app = NSRunningApplication(processIdentifier: pid) {
    print("BundleIdentifier: \(app.bundleIdentifier ?? "N/A")")
    if let url = app.bundleURL,
       let bundle = Bundle(url: url),
       let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
        print("Version: \(version)")
    }
    print("LocalizedName: \(app.localizedName ?? "N/A")")
} else {
    print("WARNING: PID \(pid) の NSRunningApplication が見つかりません")
}

let axApp = AXUIElementCreateApplication(pid)

// アプリケーション属性一覧
var attrNames: CFArray?
let attrResult = AXUIElementCopyAttributeNames(axApp, &attrNames)
print("\n=== Application attributes (result: \(attrResult.rawValue)) ===")
if let names = attrNames as? [String] {
    for name in names.sorted() {
        print("  \(name)")
    }
}

// kAXWindows
var windowsRef: CFTypeRef?
let windowsResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
print("\n=== kAXWindows (result: \(windowsResult.rawValue)) ===")

guard windowsResult == .success,
      let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
    print("ERROR: kAXWindows 取得失敗")
    exit(1)
}
print("Window count: \(windows.count)")

for (i, window) in windows.prefix(3).enumerated() {
    print("\n--- Window[\(i)] ---")

    // Window 属性一覧
    var winAttrNames: CFArray?
    AXUIElementCopyAttributeNames(window, &winAttrNames)
    if let names = winAttrNames as? [String] {
        print("  Attributes: \(names.sorted().joined(separator: ", "))")
    }

    // kAXRole
    var roleRef: CFTypeRef?
    let roleResult = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
    if roleResult == .success, let role = roleRef as? String {
        print("  Role: \(role)")
    } else {
        print("  Role: FAILED (result: \(roleResult.rawValue))")
    }

    // kAXSubrole
    var subroleRef: CFTypeRef?
    let subroleResult = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
    if subroleResult == .success, let subrole = subroleRef as? String {
        print("  Subrole: \(subrole)")
    } else {
        print("  Subrole: N/A (result: \(subroleResult.rawValue))")
    }

    // kAXPosition
    var posRef: CFTypeRef?
    let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    if posResult == .success, let val = posRef {
        var pos = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &pos)
        print("  Position: (\(pos.x), \(pos.y))")
    } else {
        print("  Position: FAILED (result: \(posResult.rawValue))")
    }

    // kAXSize
    var sizeRef: CFTypeRef?
    let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    if sizeResult == .success, let val = sizeRef {
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        print("  Size: \(size.width) x \(size.height)")
    } else {
        print("  Size: FAILED (result: \(sizeResult.rawValue))")
    }

    // kAXTitle
    var titleRef: CFTypeRef?
    let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
    if titleResult == .success, let title = titleRef as? String {
        print("  Title: \(title)")
    } else {
        print("  Title: FAILED (result: \(titleResult.rawValue))")
    }

    // kAXFocused
    var focusedRef: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(window, kAXFocusedAttribute as CFString, &focusedRef)
    if focusedResult == .success, let focused = focusedRef as? Bool {
        print("  Focused: \(focused)")
    } else {
        print("  Focused: N/A (result: \(focusedResult.rawValue))")
    }

    // kAXMinimized
    var minRef: CFTypeRef?
    let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
    if minResult == .success, let minimized = minRef as? Bool {
        print("  Minimized: \(minimized)")
    } else {
        print("  Minimized: N/A (result: \(minResult.rawValue))")
    }
}

// === Summary ===
print("\n=== Summary ===")
print("findTerminalCenter compatibility: ", terminator: "")

var posCheck: CFTypeRef?
var sizeCheck: CFTypeRef?
let posOk = AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posCheck) == .success
let sizeOk = AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeCheck) == .success

if posOk && sizeOk {
    print("COMPATIBLE — supportedBundles 昇格可能")
} else {
    print("INCOMPATIBLE — tentativeBundles 維持")
    if !posOk { print("  - kAXPosition 取得不可") }
    if !sizeOk { print("  - kAXSize 取得不可") }
}
