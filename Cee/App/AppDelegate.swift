import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        #if DEBUG
        if TestMode.isUITesting {
            if TestMode.shouldDisableAnimations {
                NSAnimationContext.current.duration = 0
            }
            if TestMode.shouldResetState {
                UserDefaults.standard.removeObject(forKey: "CeeViewerSettings")
            }
            if let fixtureURL = TestMode.testFixturePath {
                ImageWindowController.open(with: fixtureURL)
                return
            }
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        ImageWindowController.open(with: url)
    }

    // MARK: - Empty State Launch

    /// Called by macOS when app is launched/activated without a document
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        ImageWindowController.openEmpty()
        return true
    }

    // MARK: - Open File Dialog

    @MainActor @objc func openFile(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFolder.supportedTypes.map { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ImageWindowController.open(with: url)
    }

    // MARK: - Programmatic Menu (Full, Phase 3)

    @MainActor
    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // ── App Menu (Cee) ──────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Cee")
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Cee", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Cee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // ── File Menu ───────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(makeItem("Copy Image", action: #selector(ImageViewController.copyImage(_:)), key: ""))
        fileMenu.addItem(makeItem("Reveal in Finder", action: #selector(ImageViewController.revealInFinder(_:)), key: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // ── View Menu ───────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        viewMenu.addItem(makeItem("Fit on Screen",  action: #selector(ImageViewController.fitOnScreen(_:)),  key: "0"))
        viewMenu.addItem(makeItem("Actual Size",    action: #selector(ImageViewController.actualSize(_:)),   key: "1"))
        viewMenu.addItem(makeItem("Zoom In",        action: #selector(ImageViewController.zoomIn(_:)),       key: "="))
        viewMenu.addItem(makeItem("Zoom Out",       action: #selector(ImageViewController.zoomOut(_:)),      key: "-"))
        viewMenu.addItem(.separator())

        let alwaysFitItem = makeItem("Always Fit Opened Images", action: #selector(ImageViewController.toggleAlwaysFit(_:)), key: "*")
        viewMenu.addItem(alwaysFitItem)

        // Fitting Options submenu
        let fittingMenuItem = NSMenuItem(title: "Fitting Options", action: nil, keyEquivalent: "")
        let fittingMenu = NSMenu(title: "Fitting Options")
        fittingMenu.addItem(makeItem("Shrink to Fit Horizontally",  action: #selector(ImageViewController.toggleShrinkH(_:)),  key: ""))
        fittingMenu.addItem(makeItem("Shrink to Fit Vertically",    action: #selector(ImageViewController.toggleShrinkV(_:)),  key: ""))
        fittingMenu.addItem(makeItem("Stretch to Fit Horizontally", action: #selector(ImageViewController.toggleStretchH(_:)), key: ""))
        fittingMenu.addItem(makeItem("Stretch to Fit Vertically",   action: #selector(ImageViewController.toggleStretchV(_:)), key: ""))
        fittingMenuItem.submenu = fittingMenu
        viewMenu.addItem(fittingMenuItem)

        // Scaling Quality submenu
        let scalingMenuItem = NSMenuItem(title: "Scaling Quality", action: nil, keyEquivalent: "")
        let scalingMenu = NSMenu(title: "Scaling Quality")
        scalingMenu.addItem(makeItem("Low",    action: #selector(ImageViewController.setScalingLow(_:)),    key: ""))
        scalingMenu.addItem(makeItem("Medium", action: #selector(ImageViewController.setScalingMedium(_:)), key: ""))
        scalingMenu.addItem(makeItem("High",   action: #selector(ImageViewController.setScalingHigh(_:)),   key: ""))
        scalingMenu.addItem(.separator())
        let showPixelsItem = makeItem("Show Pixels When Zooming In",
                                      action: #selector(ImageViewController.toggleShowPixels(_:)), key: "p")
        showPixelsItem.keyEquivalentModifierMask = [.command, .shift]
        scalingMenu.addItem(showPixelsItem)
        scalingMenuItem.submenu = scalingMenu
        viewMenu.addItem(scalingMenuItem)

        // Trackpad Sensitivity submenu
        let trackpadMenuItem = NSMenuItem(title: "Trackpad Sensitivity", action: nil, keyEquivalent: "")
        let trackpadMenu = NSMenu(title: "Trackpad Sensitivity")
        trackpadMenu.addItem(makeItem("Low",    action: #selector(ImageViewController.setTrackpadLow(_:)),    key: ""))
        trackpadMenu.addItem(makeItem("Medium", action: #selector(ImageViewController.setTrackpadMedium(_:)), key: ""))
        trackpadMenu.addItem(makeItem("High",   action: #selector(ImageViewController.setTrackpadHigh(_:)),   key: ""))
        trackpadMenuItem.submenu = trackpadMenu
        viewMenu.addItem(trackpadMenuItem)

        // Wheel Sensitivity submenu
        let wheelMenuItem = NSMenuItem(title: "Wheel Sensitivity", action: nil, keyEquivalent: "")
        let wheelMenu = NSMenu(title: "Wheel Sensitivity")
        wheelMenu.addItem(makeItem("Low",    action: #selector(ImageViewController.setWheelLow(_:)),    key: ""))
        wheelMenu.addItem(makeItem("Medium", action: #selector(ImageViewController.setWheelMedium(_:)), key: ""))
        wheelMenu.addItem(makeItem("High",   action: #selector(ImageViewController.setWheelHigh(_:)),   key: ""))
        wheelMenuItem.submenu = wheelMenu
        viewMenu.addItem(wheelMenuItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem("Navigate with Left/Right Arrows", action: #selector(ImageViewController.toggleArrowLeftRightNav(_:)), key: ""))
        viewMenu.addItem(makeItem("Navigate with Up/Down Arrows",    action: #selector(ImageViewController.toggleArrowUpDownNav(_:)),    key: ""))
        viewMenu.addItem(makeItem("Use Low-Res Preview While Browsing", action: #selector(ImageViewController.toggleThumbnailFallback(_:)), key: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem("Resize Window Automatically", action: #selector(ImageViewController.toggleResizeAutomatically(_:)), key: ""))
        viewMenu.addItem(makeItem("Enter Full Screen",           action: #selector(ImageViewController.toggleFullScreen(_:)),          key: "f"))
        viewMenu.addItem(makeItem("Float on Top",                action: #selector(ImageViewController.toggleFloatOnTop(_:)),          key: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem("Show Status Bar",             action: #selector(ImageViewController.toggleStatusBar(_:)),           key: "/"))
        viewMenu.addItem(makeItem("Quick Grid",                    action: #selector(ImageViewController.toggleQuickGrid(_:)),            key: ""))
        viewMenu.addItem(makeItem("Scroll to Cursor After Zoom",  action: #selector(ImageViewController.toggleQuickGridScrollAfterZoom(_:)), key: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem("Dual Page",                   action: #selector(ImageViewController.toggleDualPage(_:)),            key: "k"))
        let offsetItem = makeItem("First Page as Cover",         action: #selector(ImageViewController.togglePageOffset(_:)),           key: "o")
        offsetItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(offsetItem)
        let rtlItem = makeItem("Reading: Left to Right",       action: #selector(ImageViewController.toggleReadingDirection(_:)),     key: "k")
        rtlItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(rtlItem)
        viewMenu.addItem(makeItem("Right-to-Left Navigation",  action: #selector(ImageViewController.toggleDuoPageRTLNavigation(_:)), key: ""))
        viewMenu.addItem(makeItem("Right-to-Left Navigation (Single Page)", action: #selector(ImageViewController.toggleSinglePageRTLNavigation(_:)), key: ""))

        // ── Go Menu ─────────────────────────────────────────────────────
        // Bare arrow/Home/End keys are handled by ImageScrollView.keyDown.
        // No keyEquivalents here to avoid double-triggering.
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        goMenu.addItem(makeItem("Next Image",     action: #selector(ImageViewController.goToNextImage),     key: "]"))
        goMenu.addItem(makeItem("Previous Image", action: #selector(ImageViewController.goToPreviousImage), key: "["))
        goMenu.addItem(makeItem("First Image",    action: #selector(ImageViewController.goToFirstImage),    key: ""))
        goMenu.addItem(makeItem("Last Image",     action: #selector(ImageViewController.goToLastImage),     key: ""))
        goMenu.addItem(.separator())
        goMenu.addItem(makeItem("Scroll to Bottom on Previous", action: #selector(ImageViewController.toggleScrollToBottomOnPrevious(_:)), key: ""))

        // ── Window Menu ─────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",     action: #selector(NSWindow.performZoom(_:)),        keyEquivalent: ""))

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Helper

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil  // routes through first responder chain
        return item
    }
}
