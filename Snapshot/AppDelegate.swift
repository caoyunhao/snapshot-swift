//
//  AppDelegate.swift
//  Snapshot
//
//  Created by Yunhao on 2019/11/15.
//  Copyright © 2019 Yunhao. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet weak var menu: NSMenu!
    
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    
    var captureHotkey: HotKey! = nil

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        
        if let button = statusItem.button {
            button.image = NSImage(named: "statusIcon")
        }
        statusItem.menu = menu
        
        captureHotkey = HotKey(key: .a, modifiers: [.command, .control])
        captureHotkey.keyDownHandler = {
            SnipManager.shared.startCapture()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    @IBAction func clearSystem(_ sender: Any) {
        NSPasteboard.general.clearContents()
    }
    
    @IBAction func quitApp(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }
}

