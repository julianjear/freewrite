//
//  freewriteApp.swift
//  freewrite
//
//  Created by thorfinn on 2/14/25.
//

import SwiftUI

@main
struct freewriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemeString: String = "light"
    
    init() {
        // Register Lato font
        if let fontURL = Bundle.main.url(forResource: "Lato-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
     
    var body: some Scene {
        WindowGroup {
            ContentView()
                .toolbar(.hidden, for: .windowToolbar)
                .preferredColorScheme(colorSchemeString == "dark" ? .dark : .light)
                .task {
                    // Restore a previously saved Supabase session from the
                    // keychain so the user isn't forced to sign in every launch.
                    await SupabaseAuth.shared.restore()
                }
                // WindowGroup supports multiple macOS scenes. Without declaring
                // that an existing scene handles the OAuth callback, SwiftUI
                // creates a second Freewrite window for the incoming URL.
                .handlesExternalEvents(
                    preferring: ["*"],
                    allowing: ["*"]
                )
                .onOpenURL { url in
                    // Supabase Google OAuth redirect (freewrite://auth-callback)
                    Task { await SupabaseAuth.shared.handleCallback(url: url) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 600)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
    }
}

// Add AppDelegate to handle window configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            // Ensure window starts in windowed mode
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            
            // Center the window on the screen
            window.center()
        }

        // System-wide Command-Shift-P opens Freewrite and focuses the prompt
        // capture field, even when another app is active.
        GlobalHotkey.shared.registerDefault()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
    }
}
