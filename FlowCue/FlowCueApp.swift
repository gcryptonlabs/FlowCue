//
//  FlowCueApp.swift
//  FlowCue
//
//  Created by FlowCue Team.
//

import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            FlowCueService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = FlowCueService.shared
        NSUpdateDynamicServices()

        if FlowCueService.shared.launchedExternally {
            FlowCueService.shared.hideMainWindow()
        }

        // Silent update check on launch
        UpdateChecker.shared.checkForUpdates(silent: true)

        // Start browser server if enabled
        FlowCueService.shared.updateBrowserServer()

        // Start global hotkeys
        HotkeyManager.shared.start()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if FlowCueService.shared.launchedExternally {
            FlowCueService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "flowcue" {
                FlowCueService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = FlowCueService.shared.launchedExternally
                FlowCueService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                FlowCueService.shared.hideMainWindow()
                FlowCueService.shared.handleURL(url)
            }
        }
    }
}

@main
struct FlowCueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if url.pathExtension == "flowcue" {
                        FlowCueService.shared.openFileAtURL(url)
                    } else {
                        FlowCueService.shared.handleURL(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FlowCue") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    FlowCueService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Import from URL…") {
                    FlowCueService.shared.importFromURL()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("Save") {
                    FlowCueService.shared.saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    FlowCueService.shared.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("FlowCue Help") {
                    if let url = URL(string: "https://github.com/gcryptonlabs/FlowCue") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
