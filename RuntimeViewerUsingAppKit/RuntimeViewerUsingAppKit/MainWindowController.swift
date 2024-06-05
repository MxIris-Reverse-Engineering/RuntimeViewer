//
//  MainWindowController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class MainWindow: NSWindow {
    init() {
        super.init(contentRect: .init(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }
}

class MainWindowController: XiblessWindowController<MainWindow> {
    
    let toolbar = NSToolbar()
    
    init() {
        super.init(windowGenerator: .init())
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.toolbar = toolbar
        window?.box.positionCenter()
    }
}
