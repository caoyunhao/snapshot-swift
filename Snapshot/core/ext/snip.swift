//
//  snip-manager.swift
//  MyMacApp
//
//  Created by Yunhao on 2019/10/28.
//  Copyright © 2019 Yunhao. All rights reserved.
//

import Cocoa

enum CaptureState {
    case idle
    case hilight
    case mouseFirstDown
    case appSelected
    case selecting
    case waiting
    case edit
    case done
}

class SnipManager {
    static let shared = SnipManager()
    
    var isWorking = false
    fileprivate var windowInfoes: [NSDictionary]!
    fileprivate var controllers: [SnipWindowController]!
    fileprivate var lastRect: NSRect!
    fileprivate var captureState: CaptureState = .idle
    
    private var escHotKey: HotKey!
    
    init() {
        escHotKey = HotKey(key: .escape, modifiers: [])
        escHotKey.keyDownHandler = {
            self.endCapture()
        }
    }
    
    func startCapture() {
        if (self.isWorking) {
            return
        }
        self.isWorking = true
        self.escHotKey.isPaused = false
        self.windowInfoes = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [NSDictionary]
        controllers = []
        DLog("screen count \(NSScreen.screens.count)")
        for screen in NSScreen.screens {
            let view = SnipView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height))
            
            let window = SnipWindow(contentRect: screen.frame, styleMask: .nonactivatingPanel, backing: .buffered, defer: false, screen: screen)
            window.contentView = view
            
            let controller = SnipWindowController()
            controller.window = window
//            DLog("screen.backingScaleFactor \(screen.backingScaleFactor)")
            controller.screenScale = screen.backingScaleFactor
            controller.startCaptureWithScreen(screen: screen)
            self.captureState = .hilight
            controllers.append(controller)
        }
    }
    
    func endCapture() {
        guard isWorking else {
            return
        }
        
        self.escHotKey.isPaused = true
        
        self.isWorking = false
        
        for controller in self.controllers {
            controller.window?.orderOut(nil)
            controller.shutdown()
        }
        self.captureState = .idle
        self.controllers.removeAll()
    }
}

fileprivate protocol MouseEventProtocol {
    func mouseDown(event: NSEvent)
    
    func mouseUp(event: NSEvent)
    
    func mouseDragged(event: NSEvent)
    
    func mouseMoved(event: NSEvent)
}

fileprivate class SnipWindowController: NSWindowController, NSWindowDelegate, MouseEventProtocol {
    fileprivate var snipView: SnipView!
    fileprivate var snipDrawView: SnipDrawView!
    
    fileprivate var screenScale: CGFloat!
    private let NOTIFICATION_NAME = NSNotification.Name("kNotifyMouseLocationChange")
    private var originImage: NSImage!
    private var darkImage: NSImage!
    private var captureWindowRect: NSRect!
    private var lastRect: NSRect! = NSRect.zero
    
    private var startPoint: NSPoint!
    private var endPoint: NSPoint!
    
    private var drawStartPoint: NSPoint!
    private var drawEndPoint: NSPoint!
    
    fileprivate var mouseGlobalHandler: Any?

    deinit {
        shutdown()
    }
    
    func startCaptureWithScreen(screen: NSScreen) {
        self.doSnapshot(screen: screen)
        // backgroud image
        self.window!.backgroundColor = NSColor(patternImage: self.darkImage)
        var screenFrame = screen.frame
        screenFrame.size.width /= 1;
        screenFrame.size.height /= 1;
        self.window!.setFrame(screenFrame, display: true, animate: false)
        self.snipView = (self.window!.contentView as! SnipView)
        self.snipDrawView = SnipDrawView(frame: self.snipView.frame)
        self.snipDrawView.snipView = self.snipView
        self.snipView.snipDrawView = self.snipDrawView
        self.snipView.addSubview(self.snipDrawView)
        
        (self.window as! SnipWindow).mouseDelegate = self
        self.snipView.setupTrackingArea(rect: self.window!.screen!.frame)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.onNotifyMouseChange(notify:)), name: NOTIFICATION_NAME, object: nil)
        
        self.mouseGlobalHandler = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { (event) in
            self.mouseMoved(event: event)
        }
        
        self.showWindow(nil)
        self.captureAppScreen()
    }
    
    private func doSnapshot(screen: NSScreen) {
        let cgImage = shot(ofScreen: screen)
//        DLog("cgImage size \(cgImage?.width) * \(cgImage?.height)")
        self.originImage = NSImage(cgImage: cgImage!, size: screen.frame.size)
        self.darkImage = NSImage(cgImage: cgImage!, size: screen.frame.size)
        self.darkImage.lockFocus()
        NSColor(calibratedWhite: 0, alpha: 0.22).set()
        screen.frame.zeroed.fill(using: .sourceAtop)
        self.darkImage.unlockFocus()
    }
    
    fileprivate func captureAppScreen() {
        let screen = self.window!.screen!
        let screenFrame = screen.frame
        let mouseLocation = NSEvent.mouseLocation
        self.captureWindowRect = screenFrame
        var minArea = screenFrame.area;
//        DLog("screen rect \(screenFrame), mouse location \(mouseLocation), window count \(SnipManager.shared.windowInfoes.count)")
        for windowInfo in SnipManager.shared.windowInfoes {
//            DLog("windowInfo: \(windowInfo)")
            let windowRect = CGRect(dictionaryRepresentation: windowInfo[kCGWindowBounds] as! CFDictionary)!
            let appScreenRect = windowRect.screenRect
            var layer = 0
            let numLayer = windowInfo[kCGWindowLayer] as! CFNumber
            CFNumberGetValue(numLayer, .sInt32Type, &layer)
            if NSPointInRect(mouseLocation, appScreenRect) {
                if layer == 0 {
                    self.captureWindowRect = appScreenRect
                    break;
                }
                if appScreenRect.area < minArea {
                    minArea = appScreenRect.area
                    self.captureWindowRect = appScreenRect
                }
            }
//            DLog("mouse location \(mouseLocation), layer \(layer), window rect \(windowRect), app screen rect \(appScreenRect), area \(appScreenRect.area), \(NSPointInRect(mouseLocation, appScreenRect)), min area \(minArea)")
        }
        if NSPointInRect(mouseLocation, screenFrame) {
            self.redrawView(nsImage: self.originImage)
        } else {
            self.redrawView(nsImage: nil)
            NotificationCenter.default.post(name: NOTIFICATION_NAME, object: nil, userInfo: ["context": self])
        }
    }
    
    private func redrawView(nsImage: NSImage?) {
        self.captureWindowRect = NSIntersectionRect(self.captureWindowRect, self.window!.frame)
        
        if (nsImage != nil && self.lastRect.origin.x == self.captureWindowRect.origin.x
                && self.lastRect.origin.y == self.captureWindowRect.origin.y
                && self.lastRect.size.width == self.captureWindowRect.size.width
                && self.lastRect.size.height == self.captureWindowRect.size.height) {
//            DLog("already set image (\(self.lastRect))")
            return;
        }

        if self.snipView.image == nil && nsImage == nil {
//            DLog("snipview's image already is nil")
            return
        }
        
//        DLog("set snipview's image (\(nsImage != nil))")
        
        DispatchQueue.main.async {
            self.snipView.image = nsImage
            let rect = self.window!.convertFromScreen(self.captureWindowRect)
//            DLog("convertFromScreen \(rect)")
            self.snipView.drawingRect = rect
            self.snipView.needsDisplay = true
            self.snipDrawView.frame = rect
            self.snipDrawView.needsDisplay = true
            self.lastRect = self.captureWindowRect
        }
    }
    
    private func setupToolClick() {
        self.snipView.toolContainer.toolClick = { index in
            self.ok()
        }
    }
    
    @objc
    func onNotifyMouseChange(notify: NSNotification) {
        guard notify.userInfo?["context"] as? SnipWindowController != self else {
            return
        }
    }
    
    internal func mouseUp(event: NSEvent) {
        DLog("mouseUp  \(SnipManager.shared.captureState)")
        if SnipManager.shared.captureState == .mouseFirstDown ||
            SnipManager.shared.captureState == .selecting ||
            SnipManager.shared.captureState == .waiting {
            SnipManager.shared.captureState = .edit
            self.snipView.needsDisplay = true
            self.snipView.setupTool()
            self.setupToolClick()
            self.snipDrawView.setupDrawPath()
        } else {
            if SnipManager.shared.captureState == .edit {
                self.drawEndPoint = NSEvent.mouseLocation.floored
                let sp = window!.convertPoint(fromScreen: self.drawStartPoint)
                let ep = window!.convertPoint(fromScreen: self.drawEndPoint)
                let frame = self.snipDrawView.frame
                self.snipDrawView.pathView.rectArray.append(DrawPathInfo(startPoint: NSPoint(x: sp.x - frame.origin.x, y: sp.y - frame.origin.y), endPoint: NSPoint(x: ep.x - frame.origin.x, y: ep.y - frame.origin.y)))
            }
        }
    }
    
    internal func mouseDown(event: NSEvent) {
        DLog("mouseDown \(SnipManager.shared.captureState)")
        let mouseLocation = NSEvent.mouseLocation.floored
        if event.clickCount == 2 {
            if NSPointInRect(mouseLocation, self.captureWindowRect) {
                self.ok()
            } else {
                DLog("cancel")
                SnipManager.shared.endCapture()
            }
            return
        }
        
        if SnipManager.shared.captureState == .hilight {
            self.startPoint = mouseLocation
            SnipManager.shared.captureState = .mouseFirstDown
        } else if SnipManager.shared.captureState == .edit {
            self.snipView.toolContainer.isHidden = true
            self.drawStartPoint = mouseLocation
        } else if SnipManager.shared.captureState == .waiting {
            
        }
    }
    
    internal func mouseDragged(event: NSEvent) {
//        DLog("mouseDragged \(SnipManager.shared.captureState)")
        if SnipManager.shared.captureState == .mouseFirstDown {
            SnipManager.shared.captureState = .selecting
        }
        if SnipManager.shared.captureState == .selecting {
            self.endPoint = NSEvent.mouseLocation.ceiled
            self.captureWindowRect = NSUnionRect(NSRect(x: self.startPoint.x, y: self.startPoint.y, width: 1, height: 1), NSRect(x: self.endPoint.x, y: self.endPoint.y, width: 1, height: 1))
            self.captureWindowRect = NSIntersectionRect(self.captureWindowRect, self.window!.frame);
            self.redrawView(nsImage: self.originImage)
        } else if SnipManager.shared.captureState == .edit {
            self.drawEndPoint = NSEvent.mouseLocation
            let sp = window!.convertPoint(fromScreen: self.drawStartPoint)
            let ep = window!.convertPoint(fromScreen: self.drawEndPoint)
            let frame = self.snipDrawView.frame
            
            self.snipDrawView.pathView.currentInfo = DrawPathInfo(startPoint: NSPoint(x: sp.x - frame.origin.x, y: sp.y - frame.origin.y), endPoint: NSPoint(x: ep.x - frame.origin.x, y: ep.y - frame.origin.y))
//            DLog("start converted \(sp) end converted \(ep) draw frame \(self.snipDrawView.frame)")
            self.snipDrawView.pathView.needsDisplay = true
        } else if SnipManager.shared.captureState == .waiting {
        }
    }
    
    internal func mouseMoved(event: NSEvent) {
//        DLog("mouseMoved \(SnipManager.shared.captureState)")
        if SnipManager.shared.captureState == .hilight {
            self.captureAppScreen()
        }
    }
    
    private func ok() {
//        let rect = NSIntersectionRect(self.snipDrawView.frame, self.window!.frame)
//        let rect1 = self.window!.convertFromScreen(rect)
//        let rect2 = NSIntegralRect(rect1)
//        DLog("rect \(rect) rect1 \(rect1) rect2 \(rect2)")
        let x_start = ceil(snipDrawView.bounds.origin.x)
        let y_start = ceil(snipDrawView.bounds.origin.y)
        let width = ceil(snipDrawView.bounds.width)
        let height = ceil(snipDrawView.bounds.height)
        let rect = CGRect(x: x_start, y: y_start, width: width, height: height)
        guard let bitmap = snipDrawView.bitmapImageRepForCachingDisplay(in: rect) else {
            DLog("bitmap fail")
            return
        }
        // DLog("bitmap pixels (\(bitmap.pixelsHigh)*\(bitmap.pixelsWide)) scale \(self.screenScale)")
        bitmap.pixelsHigh = Int(ceil(bitmap.size.height * self.screenScale))
        bitmap.pixelsWide = Int(ceil(bitmap.size.width * self.screenScale))
        snipDrawView.cacheDisplay(in: rect, to: bitmap)
    
        let prop: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: 1.0
        ]

        if let data = bitmap.representation(using: .png, properties: prop),
            let image = NSImage(data: data) {
            
            DLog("draw view size = \(snipDrawView.bounds.size), rect = \(rect), bitmap size = \(bitmap.size), bimap pixel = \(bitmap.pixelsWide)*\(bitmap.pixelsHigh), image size = \(image.size)")
            
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image, ])
            
            DLog(NSHomeDirectory())
//            let dir = "/Users/caoyunhao/Downloads/Snapshot"
//            let paths = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
//            DLog(paths)
            let dirPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshot")
            DLog(dirPath)
            if !FileManager.default.fileExists(atPath: dirPath.absoluteString) {
                do {
                    try FileManager.default.createDirectory(atPath: dirPath.absoluteString, withIntermediateDirectories: true, attributes: nil)
                    DLog("\(dirPath.absoluteString) created")
                } catch let e {
                    DLog(e)
                }
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let dataString = formatter.string(from: Date())
            let name = "snapshot-\(dataString).png"

            do {
                try data.write(to: dirPath.appendingPathComponent(name, isDirectory: false))
            } catch let e {
                DLog(e)
            }
        }
        SnipManager.shared.endCapture()
        self.window?.orderOut(nil)
    }
    
    fileprivate func shutdown() {
        DLog("shutdown")
//        self.window?.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
        if let mouseGlobalHandler = self.mouseGlobalHandler {
            NSEvent.removeMonitor(mouseGlobalHandler)
        }
    }
}

fileprivate class SnipWindow: NSPanel {
    
    fileprivate var mouseDelegate: MouseEventProtocol!
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        
        self.acceptsMouseMovedEvents = true
        self.isFloatingPanel = true
        self.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        self.isMovableByWindowBackground = false
        self.isExcludedFromWindowsMenu = true
        self.alphaValue = 1.0
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
//        self.level = NSWindow.Level(Int(CGWindowLevelKey.maximumWindow.rawValue))
        self.isRestorable = false
        self.disableSnapshotRestoration()
        self.level = NSWindow.Level(2147483631)
        self.isMovable = false
        DLog("init \(Int(CGWindowLevelKey.maximumWindow.rawValue))")
    }
    
    override func mouseUp(with event: NSEvent) {
        self.mouseDelegate.mouseUp(event: event)
    }
    
    override func mouseDown(with event: NSEvent) {
        self.mouseDelegate.mouseDown(event: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        self.mouseDelegate.mouseDragged(event: event)
    }
    
    override func mouseMoved(with event: NSEvent) {
        self.mouseDelegate.mouseMoved(event: event)
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
//            exit(0)
        }
    }
}


fileprivate class SnipView: NSView {
    fileprivate var snipDrawView: SnipDrawView!
    fileprivate var toolContainer: ToolContainer!
    
    fileprivate var image: NSImage!
    fileprivate var drawingRect: NSRect!
    
    private var trackingArea: NSTrackingArea!
    
    override func draw(_ dirtyRect: NSRect) {
//        NSDisableScreenUpdates()
//        DLog("draw \(dirtyRect) frame \(frame) \(SnipManager.shared.captureState)")
        super.draw(dirtyRect)
        
        if let image = self.image {
            let imageRect = NSIntersectionRect(self.drawingRect, self.bounds)
            if SnipManager.shared.captureState == .waiting {
                NSColor.white.set()
                for i in 0..<8 {
                    let path = NSBezierPath()
                    path.removeAllPoints()
                    path.appendOval(in: self.pointRect(index: i, inRect: imageRect))
                    path.fill()
                }
            }
        }
        if let toolContainer = self.toolContainer,
            toolContainer.isHidden {
            self.showTool()
        }
//        NSEnableScreenUpdates()
    }
    
    fileprivate func setupTrackingArea(rect: NSRect) {
        self.trackingArea = NSTrackingArea(rect: rect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        self.addTrackingArea(self.trackingArea)
    }
    
    fileprivate func setupTool() {
        DLog("setup Tool but not show")
        self.toolContainer = ToolContainer()
        self.toolContainer.isHidden = true
        self.addSubview(self.toolContainer)
    }
    
    fileprivate func showTool() {
        DLog("show Tool")
        let imageRect = NSIntersectionRect(self.drawingRect, self.bounds)
        var y = Int(imageRect.origin.y) - 28
        var x = Int(imageRect.origin.x + imageRect.size.width)
        
        if y < 0 {
            y = 0
        }
        
        let toolCount = 1
        let toolWidth = TOOL_BUTTON_STEP * toolCount + TOOL_BUTTON_MARGIN * 2 - (TOOL_BUTTON_STEP - TOOL_BUTTON_WIDTH);
        if x < toolWidth {
            x = toolWidth
        }
        
        let rect1 = NSRect(x: x - toolWidth, y: y, width: toolWidth, height: 26)
        if !NSEqualRects(self.toolContainer.frame, NSRect(x: x - toolWidth, y: y, width: toolWidth, height: 26)) {
            self.toolContainer.frame = rect1
        }
        
        if self.toolContainer.isHidden {
            self.toolContainer.isHidden = false
        }
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    private func pointRect(index: Int, inRect rect: NSRect) -> NSRect {
        var x: CGFloat = 0.0, y: CGFloat = 0.0
        switch index {
        case 0:
            x = rect.minX
            y = rect.maxY
        case 1:
            x = rect.midX
            y = rect.maxY
        case 2:
            x = rect.maxX
            y = rect.maxY
        case 3:
            x = rect.minX
            y = rect.midY
        case 4:
            x = rect.maxX
            y = rect.midY
        case 5:
            x = rect.minX
            y = rect.minY
        case 6:
            x = rect.midX
            y = rect.minY
        case 7:
            x = rect.maxX
            y = rect.minY
        default:
            break
        }
        return NSRect(x: x - 5, y: y - 5, width: 10, height: 10)
    }
}

fileprivate class SnipDrawView: NSView {
    fileprivate var snipView: SnipView!
    fileprivate var pathView: DrawPathView!
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if let image = self.snipView.image {
            let imageRect = NSIntersectionRect(self.snipView.drawingRect, self.snipView.bounds)
            image.draw(in: self.bounds, from: imageRect, operation: .sourceOver, fraction: 1.0)
        }
        
//        NSColor(calibratedWhite: 1, alpha: 0.66).set()
//        let path = NSBezierPath()
//        path.lineWidth = 2.0
//        path.removeAllPoints()
//        path.appendRect(dirtyRect)
//        path.stroke()
    }
    
    func setupDrawPath() {
        guard pathView == nil else {
            return
        }
        DLog("setup draw path")
        self.pathView = DrawPathView()
        self.addSubview(self.pathView)
//        let rect = NSIntersectionRect(self.snipView.drawingRect, self.bounds)
        self.pathView.frame = self.bounds
        self.pathView.isHidden = false
    }
}

fileprivate class DrawPathView: NSView {
    fileprivate var rectArray: [DrawPathInfo] = []
    fileprivate var currentInfo: DrawPathInfo?
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if SnipManager.shared.captureState == .edit {
            self.drawCommentInRect(rect: self.bounds)
            if let currentInfo = self.currentInfo {
                self.drawShape(info: currentInfo, inBackgroud: false)
            }
        }
    }
    
    fileprivate func drawCommentInRect(rect: NSRect) {
        let path = NSBezierPath(rect: rect)
        path.addClip()
        NSColor.red.set()
        for info in self.rectArray {
            self.drawShape(info: info, inBackgroud: false)
        }
    }
    
    private func drawShape(info: DrawPathInfo, inBackgroud: Bool) {
        var rect = NSRect(x: info.startPoint.x, y: info.startPoint.y, width: info.endPoint.x - info.startPoint.x, height: info.endPoint.y - info.startPoint.y)
//        DLog("drawShape rect \(rect) start point \(info.startPoint) end point \(info.endPoint)")
//        if inBackgroud {
//            rect = self.window!.convertFromScreen(rect)
//        } else {
//            var rect1 = self.window!.convertFromScreen(rect)
//            rect1.origin.x -= self.frame.origin.x
//            rect1.origin.y -= self.frame.origin.y
//            rect = rect1
//        }
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        
        rect = rect.uniform
        if rect.size.width * rect.size.width < 1e-2 {
            return
        }
        path.appendRect(rect)
        path.stroke()
    }
}

fileprivate class DrawPathInfo: NSObject {
    fileprivate var startPoint: NSPoint
    fileprivate var endPoint: NSPoint
    fileprivate var points: [NSPoint] = []
    
    init(startPoint: NSPoint, endPoint: NSPoint) {
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
}

fileprivate let TOOL_BUTTON_WIDTH = 75
fileprivate let TOOL_BUTTON_HEIGHT = 26
fileprivate let TOOL_BUTTON_STEP = 35
fileprivate let TOOL_BUTTON_MARGIN = 10
fileprivate class ToolContainer: NSView {
    fileprivate var toolClick: ((Int) -> ())!
    
    private var copyButton: NSButton!
    private var buttons: [NSButton] = []
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        copyButton = NSButton(title: "Copy", target: self, action: #selector(self.click))
        buttons.append(copyButton)
        
        for btn in buttons {
            self.addSubview(btn)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: self.bounds, xRadius: 3, yRadius: 3)
        path.setClip()
        NSColor(calibratedWhite: 1.0, alpha: 0.3).setFill()
        self.bounds.fill()
    }
    
    override var frame: NSRect {
        get {
            return super.frame
        }
        set {
            DLog("set frame")
            super.frame = newValue

            var index = 0
            for button in self.buttons {
                button.frame = NSRect(x: TOOL_BUTTON_MARGIN + TOOL_BUTTON_STEP * index, y: 0, width: TOOL_BUTTON_WIDTH, height: TOOL_BUTTON_HEIGHT)
                index += 1
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc
    func click() {
        DLog("call click")
        toolClick(1)
    }
}

// globle util function

fileprivate func shot(ofScreen screen: NSScreen) -> CGImage? {
    return CGWindowListCreateImage(screen.frame.screenRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
}

fileprivate extension CGRect {
    var screenRect: CGRect {
        var mainRect = NSScreen.main!.frame;
        for screen in NSScreen.screens {
            if (screen.frame.origin.x == 0 && screen.frame.origin.y == 0) {
                mainRect = screen.frame;
            }
        }
        return CGRect(x: self.origin.x, y: mainRect.size.height - self.size.height - self.origin.y, width: self.size.width, height: self.size.height)
    }
    
    var zeroed: CGRect {
        return self.offsetBy(dx: -self.origin.x, dy: -self.origin.y)
    }
    
    var area: CGFloat {
        return self.width * self.height
    }
    var uniform: CGRect {
        var x = origin.x;
        var y = origin.y;
        var w = size.width;
        var h = size.height;
        if (w < 0) {
            x += w;
            w = -w;
        }
        if (h < 0) {
            y += h;
            h = -h;
        }
        return NSRect(x: x, y: y, width: w, height: h);
    }
}

fileprivate extension CGPoint {
    var floored: CGPoint {
        return CGPoint(x: floor(self.x), y: floor(self.y))
    }
    
    var ceiled: CGPoint {
        return CGPoint(x: ceil(self.x), y: ceil(self.y))
    }
}
