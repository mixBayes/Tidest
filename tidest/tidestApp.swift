//
//  tidestApp.swift
//  tidest
//
//

import SwiftUI

@main
struct tidestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra("Tidest", image: "MenuBarIcon") {
            Button(settings.text("设置")) { delegate.showSettings() }
                .keyboardShortcut(",")
            Divider()
            Text(settings.text("%@ · %@", settings.text("窗口切换"), settings.shortcut.symbolDisplayName))
                .accessibilityLabel(settings.text("%@ · %@", settings.text("窗口切换"), settings.shortcut.displayName))
            Text(settings.text("%@ · %@", settings.text("快速布局"), settings.layoutShortcut.symbolDisplayName))
                .accessibilityLabel(settings.text("%@ · %@", settings.text("快速布局"), settings.layoutShortcut.displayName))
            if settings.pinningEnabled {
                Text(settings.text("%@ · %@", settings.text("拾取窗口"), settings.pinShortcut.symbolDisplayName))
                    .accessibilityLabel(settings.text("%@ · %@", settings.text("拾取窗口"), settings.pinShortcut.displayName))
            }
            Button(settings.text("使用说明")) { delegate.showUsageGuide() }
                .accessibilityIdentifier("showUsageGuide")
            Divider()
            Button(aboutMenuTitle) { delegate.showAbout() }
            Divider()
            Button(settings.text("退出")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var aboutMenuTitle: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return settings.text("关于 Tidest %@", version)
        }
        return settings.text("关于 Tidest")
    }
}
