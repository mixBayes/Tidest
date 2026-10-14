//
//  tidestApp.swift
//  tidest
//
//

import SwiftUI

@main
struct tidestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
