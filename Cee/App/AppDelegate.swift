import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

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
        // 對同一資料夾的多個檔案去重：每個資料夾只開一次，保留該資料夾的第一個 URL
        var seen = Set<String>()
        let deduplicated = urls.filter { url in
            let folder = url.deletingLastPathComponent().path
            return seen.insert(folder).inserted
        }
        for url in deduplicated {
            ImageWindowController.open(with: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        appMenu.addItem(NSMenuItem(title: String(localized: "menu.app.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "menu.app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // ── File Menu ───────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: String(localized: "menu.file.title"))
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: String(localized: "menu.file.open"), action: #selector(openFile(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(makeItem(String(localized: "menu.file.copyImage"), action: #selector(ImageViewController.copyImage(_:)), key: ""))
        fileMenu.addItem(makeItem(String(localized: "menu.file.revealInFinder"), action: #selector(ImageViewController.revealInFinder(_:)), key: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: String(localized: "menu.file.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // ── View Menu ───────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: String(localized: "menu.view.title"))
        viewMenuItem.submenu = viewMenu

        viewMenu.addItem(makeItem(String(localized: "menu.view.fitOnScreen"),  action: #selector(ImageViewController.fitOnScreen(_:)),  key: "0"))
        viewMenu.addItem(makeItem(String(localized: "menu.view.actualSize"),   action: #selector(ImageViewController.actualSize(_:)),   key: "1"))
        viewMenu.addItem(makeItem(String(localized: "menu.view.zoomIn"),       action: #selector(ImageViewController.zoomIn(_:)),       key: "="))
        viewMenu.addItem(makeItem(String(localized: "menu.view.zoomOut"),      action: #selector(ImageViewController.zoomOut(_:)),      key: "-"))
        viewMenu.addItem(.separator())

        let alwaysFitItem = makeItem(String(localized: "menu.view.alwaysFit"), action: #selector(ImageViewController.toggleAlwaysFit(_:)), key: "*")
        viewMenu.addItem(alwaysFitItem)

        // Fitting Options submenu
        let fittingMenuItem = NSMenuItem(title: String(localized: "menu.view.fittingOptions"), action: nil, keyEquivalent: "")
        let fittingMenu = NSMenu(title: String(localized: "menu.view.fittingOptions"))
        fittingMenu.addItem(makeItem(String(localized: "menu.view.shrinkH"),  action: #selector(ImageViewController.toggleShrinkH(_:)),  key: ""))
        fittingMenu.addItem(makeItem(String(localized: "menu.view.shrinkV"),  action: #selector(ImageViewController.toggleShrinkV(_:)),  key: ""))
        fittingMenu.addItem(makeItem(String(localized: "menu.view.stretchH"), action: #selector(ImageViewController.toggleStretchH(_:)), key: ""))
        fittingMenu.addItem(makeItem(String(localized: "menu.view.stretchV"), action: #selector(ImageViewController.toggleStretchV(_:)), key: ""))
        fittingMenuItem.submenu = fittingMenu
        viewMenu.addItem(fittingMenuItem)

        // Scaling Quality submenu
        let scalingMenuItem = NSMenuItem(title: String(localized: "menu.view.scalingQuality"), action: nil, keyEquivalent: "")
        let scalingMenu = NSMenu(title: String(localized: "menu.view.scalingQuality"))
        scalingMenu.addItem(makeItem(String(localized: "menu.view.scalingLow"),    action: #selector(ImageViewController.setScalingLow(_:)),    key: ""))
        scalingMenu.addItem(makeItem(String(localized: "menu.view.scalingMedium"), action: #selector(ImageViewController.setScalingMedium(_:)), key: ""))
        scalingMenu.addItem(makeItem(String(localized: "menu.view.scalingHigh"),   action: #selector(ImageViewController.setScalingHigh(_:)),   key: ""))
        scalingMenu.addItem(.separator())
        let showPixelsItem = makeItem(String(localized: "menu.view.showPixels"),
                                      action: #selector(ImageViewController.toggleShowPixels(_:)), key: "p")
        showPixelsItem.keyEquivalentModifierMask = [.command, .shift]
        scalingMenu.addItem(showPixelsItem)
        scalingMenuItem.submenu = scalingMenu
        viewMenu.addItem(scalingMenuItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem(String(localized: "menu.view.lowResPreview"), action: #selector(ImageViewController.toggleThumbnailFallback(_:)), key: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem(String(localized: "menu.view.resizeAuto"),    action: #selector(ImageViewController.toggleResizeAutomatically(_:)), key: ""))
        viewMenu.addItem(makeItem(String(localized: "menu.view.enterFullScreen"), action: #selector(ImageViewController.toggleFullScreen(_:)),        key: "f"))
        viewMenu.addItem(makeItem(String(localized: "menu.view.floatOnTop"),    action: #selector(ImageViewController.toggleFloatOnTop(_:)),          key: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeItem(String(localized: "menu.view.showStatusBar"), action: #selector(ImageViewController.toggleStatusBar(_:)),           key: "/"))

        // ── Navigation Menu ─────────────────────────────────────────────
        let navigationMenuItem = NSMenuItem()
        mainMenu.addItem(navigationMenuItem)
        let navigationMenu = NSMenu(title: String(localized: "menu.navigation.title"))
        navigationMenuItem.submenu = navigationMenu

        // Reading Mode group
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.dualPage"),        action: #selector(ImageViewController.toggleDualPage(_:)),            key: "k"))
        let offsetItem = makeItem(String(localized: "menu.navigation.firstPageCover"),        action: #selector(ImageViewController.togglePageOffset(_:)),           key: "o")
        offsetItem.keyEquivalentModifierMask = [.command, .shift]
        navigationMenu.addItem(offsetItem)
        let rtlItem = makeItem(String(localized: "menu.navigation.readingLTR"),               action: #selector(ImageViewController.toggleReadingDirection(_:)),     key: "k")
        rtlItem.keyEquivalentModifierMask = [.command, .shift]
        navigationMenu.addItem(rtlItem)
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.rtlDual"),         action: #selector(ImageViewController.toggleDuoPageRTLNavigation(_:)), key: ""))
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.rtlSingle"),       action: #selector(ImageViewController.toggleSinglePageRTLNavigation(_:)), key: ""))

        navigationMenu.addItem(.separator())

        // Navigation Settings group
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.arrowLR"),         action: #selector(ImageViewController.toggleArrowLeftRightNav(_:)), key: ""))
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.arrowUD"),         action: #selector(ImageViewController.toggleArrowUpDownNav(_:)),    key: ""))
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.scrollToBottom"),  action: #selector(ImageViewController.toggleScrollToBottomOnPrevious(_:)), key: ""))
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.clickToTurn"),     action: #selector(ImageViewController.toggleClickToTurnPage(_:)),           key: ""))

        // Trackpad Page-Turn Sensitivity submenu
        let trackpadMenuItem = NSMenuItem(title: String(localized: "menu.navigation.trackpadSensitivity"), action: nil, keyEquivalent: "")
        let trackpadMenu = NSMenu(title: String(localized: "menu.navigation.trackpadSensitivity"))
        trackpadMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityLow"),    action: #selector(ImageViewController.setTrackpadLow(_:)),    key: ""))
        trackpadMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityMedium"), action: #selector(ImageViewController.setTrackpadMedium(_:)), key: ""))
        trackpadMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityHigh"),   action: #selector(ImageViewController.setTrackpadHigh(_:)),   key: ""))
        trackpadMenuItem.submenu = trackpadMenu
        navigationMenu.addItem(trackpadMenuItem)

        // Wheel Page-Turn Sensitivity submenu
        let wheelMenuItem = NSMenuItem(title: String(localized: "menu.navigation.wheelSensitivity"), action: nil, keyEquivalent: "")
        let wheelMenu = NSMenu(title: String(localized: "menu.navigation.wheelSensitivity"))
        wheelMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityLow"),    action: #selector(ImageViewController.setWheelLow(_:)),    key: ""))
        wheelMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityMedium"), action: #selector(ImageViewController.setWheelMedium(_:)), key: ""))
        wheelMenu.addItem(makeItem(String(localized: "menu.navigation.sensitivityHigh"),   action: #selector(ImageViewController.setWheelHigh(_:)),   key: ""))
        wheelMenuItem.submenu = wheelMenu
        navigationMenu.addItem(wheelMenuItem)

        navigationMenu.addItem(.separator())

        // Quick Grid group
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.quickGrid"),       action: #selector(ImageViewController.toggleQuickGrid(_:)),            key: ""))
        navigationMenu.addItem(makeItem(String(localized: "menu.navigation.scrollAfterZoom"), action: #selector(ImageViewController.toggleQuickGridScrollAfterZoom(_:)), key: ""))

        // ── Go Menu ─────────────────────────────────────────────────────
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: String(localized: "menu.go.title"))
        goMenuItem.submenu = goMenu
        goMenu.addItem(makeItem(String(localized: "menu.go.nextImage"),     action: #selector(ImageViewController.goToNextImage),     key: "]"))
        goMenu.addItem(makeItem(String(localized: "menu.go.previousImage"), action: #selector(ImageViewController.goToPreviousImage), key: "["))
        goMenu.addItem(makeItem(String(localized: "menu.go.firstImage"),    action: #selector(ImageViewController.goToFirstImage),    key: ""))
        goMenu.addItem(makeItem(String(localized: "menu.go.lastImage"),     action: #selector(ImageViewController.goToLastImage),     key: ""))

        // ── Window Menu ─────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: String(localized: "menu.window.title"))
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: String(localized: "menu.window.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "menu.window.zoom"),     action: #selector(NSWindow.performZoom(_:)),        keyEquivalent: ""))
        windowMenu.addItem(.separator())
        let reuseItem = NSMenuItem(title: String(localized: "menu.window.reuseWindow"), action: #selector(toggleReuseWindow(_:)), keyEquivalent: "")
        reuseItem.target = self
        windowMenu.addItem(reuseItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Helper

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil  // routes through first responder chain
        return item
    }

    // MARK: - Reuse Window Toggle

    @objc func toggleReuseWindow(_ sender: Any?) {
        var settings = ViewerSettings.load()
        settings.reuseWindow.toggle()
        settings.save()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleReuseWindow(_:)) else {
            return true
        }
        let settings = ViewerSettings.load()
        menuItem.state = settings.reuseWindow ? .on : .off
        return true
    }
}
