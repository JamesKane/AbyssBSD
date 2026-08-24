// AquaWindow — a top-level Jaguar window: rounded chrome, gradient title bar,
// traffic lights, a pinstriped content area, and a live default gel button.
// It owns a Surface.Window and serves as its WindowDelegate.

import Surface
import CCairo
import Install

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let kBtnLeft: UInt32 = 0x110  // BTN_LEFT from linux/input-event-codes.h

public final class AquaWindow: WindowDelegate {
    private var window: Window?
    private let title: String
    private let sceneKind: SceneKind

    // Interaction state.
    private var clickCount = 0
    private var buttonRect = Rect(0, 0, 0, 0)
    private var buttonPressed = false
    private var pointerX = 0.0
    private var pointerY = 0.0
    private var typedText = ""

    // Widgets-scene state.
    private var widgets = WidgetState()
    private var widgetLayout = WidgetLayout()
    private var draggingSlider = false
    // Keyboard focus starts on the default button (OK), Aqua-style.
    private var widgetFocus: WidgetFocus = .ok

    // Scroll-scene state.
    private var scrollOffset = 0.0
    private var scrollLayoutCache = ScrollLayout()
    private var draggingThumb = false
    private var thumbGrabDy = 0.0

    // Active pop-up menu (widgets scene), if open.
    private var menu: AquaMenu?
    private var menuPopup: Popup?

    // Tabs-scene state.
    private var tabs = TabsState()
    private var tabsLayoutCache = TabsLayout()

    // Installer-scene state (PHASE5 P5.4). The model is public so the app can
    // seed it from `abyss-install` before the first frame, and so a live test
    // can read back what the clicks and keystrokes actually produced.
    public var installer = InstallerModel()
    public private(set) var installerLayoutCache = InstallerLayout()
    public var accountFocus: AccountField? = nil
    private var installerPressed = false
    private var installerLastDumped: InstallerPage? = nil
    private let installerDumpLayout = getenv("ABYSS_INSTALLER_DUMP") != nil
    /// Where an install's progress arrives, once one has been started.
    public private(set) var installerSocket: Int32 = -1
    /// Redraw, for a caller driving the model from outside (install progress).
    public func refresh() { window?.setNeedsDisplay() }

    /// Called when the user commits, so the app can start the install and fold
    /// the socket into its run loop. The window itself never installs anything.
    public var onInstall: ((InstallPlan) -> Void)?
    public var onQuit: (() -> Void)?

    // Sheet-scene state (progress 0…1 drives the slide animation).
    private var sheetVisible = false
    private var sheetProgress = 0.0
    private var sheetOpening = false
    private var sheetAction = "—"
    private var sheetScene = SheetScene()

    public init?(display: Display, title: String, scene: SceneKind = .window,
                 width: Int32 = 440, height: Int32 = 300) {
        self.title = title
        self.sceneKind = scene
        // AQUA_SCALE, when set, pins the buffer scale (handy for forcing HiDPI
        // without a HiDPI output); otherwise the window auto-tracks its outputs.
        let (scale, auto) = AquaWindow.scaleConfig()
        guard let win = Window(display: display, title: title,
                               appID: "org.abyssbsd.aquademo",
                               width: width, height: height,
                               scale: scale, autoScale: auto,
                               delegate: self) else { return nil }
        window = win
        display.window = win
    }

    private static func scaleConfig() -> (scale: Int32, auto: Bool) {
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 {
            return (v, false)   // pinned override — don't follow outputs
        }
        return (1, true)        // auto-detect from wl_output
    }

    // MARK: WindowDelegate

    public func render(_ buffer: PixelBuffer) {
        // Shape/hint text on this frame's device pixel grid.
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale)
        let h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(
            buffer.data.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else {
            cairo_surface_destroy(cs)
            return
        }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))

        // Transparent ground so the rounded corners read.
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        drawWindow(cr, w: w, h: h)

        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    private func drawWindow(_ cr: OpaquePointer, w: Double, h: Double) {
        switch sceneKind {
        case .window:
            buttonRect = paintAquaWindow(cr, w: w, h: h, title: title,
                                         clickCount: clickCount,
                                         buttonPressed: buttonPressed,
                                         typed: typedText, focused: true)
        case .systemPreferences:
            paintSystemPreferences(cr, w: w, h: h)
        case .widgets:
            widgetLayout = paintWidgets(cr, w: w, h: h, state: widgets,
                                        focus: widgetFocus)
        case .scroll:
            scrollLayoutCache = paintScroll(cr, w: w, h: h, offset: scrollOffset)
        case .tabs:
            tabsLayoutCache = paintTabs(cr, w: w, h: h, state: tabs)
        case .sheet:
            sheetScene = paintSheetScene(cr, w: w, h: h, progress: sheetProgress,
                                         visible: sheetVisible,
                                         lastAction: sheetAction)
        case .wallpaper:
            paintWallpaper(cr, w: w, h: h)  // not used live (Wallpaper owns it)
        case .installer:
            installerLayoutCache = paintInstaller(cr, w: w, h: h, model: installer,
                                                  focus: accountFocus,
                                                  pressed: installerPressed)
            // Publish the geometry whenever the page changes, so a test clicks
            // what was actually drawn instead of coordinates copied into a
            // shell script that will be wrong the first time this layout moves.
            if installerDumpLayout && installerLastDumped != installer.page {
                installerLastDumped = installer.page
                dumpInstallerLayout(w: w, h: h)
            }
        case .menubar, .dock, .finder, .notify:
            break  // not used live (MenuBar/Dock/FinderWindow own them)
        }
    }

    // Drive the sheet slide from the per-frame tick (safe to setNeedsDisplay
    // here — unlike from inside render()).
    public func windowDidRenderFrame(_ window: Window) {
        guard sceneKind == .sheet else { return }
        let step = 0.18
        if sheetOpening {
            if sheetProgress < 1 {
                sheetProgress = min(1, sheetProgress + step)
                window.setNeedsDisplay()
            }
        } else if sheetVisible {
            if sheetProgress > 0 {
                sheetProgress = max(0, sheetProgress - step)
                window.setNeedsDisplay()
            } else {
                sheetVisible = false
                window.setNeedsDisplay()
            }
        }
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x
        pointerY = y
        if sceneKind == .widgets, draggingSlider {
            widgets.slider = sliderValue(at: x)
            window?.setNeedsDisplay()
        }
        if sceneKind == .scroll, draggingThumb {
            scrollToThumbTop(y - thumbGrabDy)
            window?.setNeedsDisplay()
        }
    }

    public func pointerAxis(_ axis: UInt32, value: Double) {
        // Vertical wheel scrolls the list. `value` is logical px; a small
        // multiplier makes a notch move a few rows, matching Aqua's feel.
        guard sceneKind == .scroll, axis == 0 else { return }
        scrollBy(value * 2)
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft else { return }
        switch sceneKind {
        case .widgets: widgetsPointerButton(pressed: pressed)
        case .scroll:  scrollPointerButton(pressed: pressed)
        case .tabs:    tabsPointerButton(pressed: pressed)
        case .sheet:   sheetPointerButton(pressed: pressed)
        case .installer: installerPointerButton(pressed: pressed)
        default:       windowPointerButton(pressed: pressed)
        }
    }

    // MARK: Sheet-scene input

    private func sheetPointerButton(pressed: Bool) {
        guard pressed else { return }
        if sheetVisible {
            // Modal: only the sheet's own buttons respond, and only once it's
            // fully out (ignore clicks mid-slide).
            guard sheetProgress >= 1 else { return }
            if sheetScene.ok.contains(pointerX, pointerY) {
                sheetAction = "Deleted"; closeSheet()
            } else if sheetScene.cancel.contains(pointerX, pointerY) {
                sheetAction = "Cancelled"; closeSheet()
            }
            return
        }
        if sheetScene.baseButton.contains(pointerX, pointerY) { openSheet() }
    }

    private func openSheet() {
        sheetVisible = true
        sheetOpening = true
        sheetProgress = 0
        window?.setNeedsDisplay()
    }

    private func closeSheet() {
        sheetOpening = false     // the frame tick slides it back up
        window?.setNeedsDisplay()
    }

    // MARK: Tabs-scene input

    private func tabsPointerButton(pressed: Bool) {
        guard pressed else { return }
        for (i, r) in tabsLayoutCache.segments.enumerated()
        where r.contains(pointerX, pointerY) {
            tabs.segment = i; window?.setNeedsDisplay(); return
        }
        for (i, r) in tabsLayoutCache.tabs.enumerated()
        where r.contains(pointerX, pointerY) {
            tabs.tab = i; window?.setNeedsDisplay(); return
        }
    }

    private func tabsKey(_ keysym: UInt32) {
        let n = tabsTabLabels.count
        switch keysym {
        case KeySym.left:  tabs.tab = (tabs.tab - 1 + n) % n; window?.setNeedsDisplay()
        case KeySym.right: tabs.tab = (tabs.tab + 1) % n; window?.setNeedsDisplay()
        default: break
        }
    }

    private func windowPointerButton(pressed: Bool) {
        if pressed {
            if buttonRect.contains(pointerX, pointerY) {
                buttonPressed = true
                window?.setNeedsDisplay()
            }
        } else {
            if buttonPressed {
                if buttonRect.contains(pointerX, pointerY) { clickCount += 1 }
                buttonPressed = false
                window?.setNeedsDisplay()
            }
        }
    }

    // MARK: Widgets-scene input

    private func sliderValue(at x: Double) -> Double {
        let t = widgetLayout.sliderTrack
        let usable = t.w - 2 * Draw.sliderThumbRadius
        guard usable > 0 else { return 0 }
        return max(0, min(1, (x - t.x - Draw.sliderThumbRadius) / usable))
    }

    private func widgetsPointerButton(pressed: Bool) {
        guard pressed else {
            draggingSlider = false
            if widgets.okPressed || widgets.cancelPressed {
                widgets.okPressed = false; widgets.cancelPressed = false
                window?.setNeedsDisplay()
            }
            return
        }
        for (i, r) in widgetLayout.checks.enumerated()
        where r.contains(pointerX, pointerY) {
            widgetFocus = .check(i)
            widgets.checks[i].toggle(); window?.setNeedsDisplay(); return
        }
        for (i, r) in widgetLayout.radios.enumerated()
        where r.contains(pointerX, pointerY) {
            widgetFocus = .radio
            widgets.radio = i; window?.setNeedsDisplay(); return
        }
        if widgetLayout.sliderTrack.contains(pointerX, pointerY) {
            widgetFocus = .slider
            draggingSlider = true
            widgets.slider = sliderValue(at: pointerX)
            window?.setNeedsDisplay(); return
        }
        if widgetLayout.popup.contains(pointerX, pointerY) {
            widgetFocus = .popup
            openAppearanceMenu(); return
        }
        if widgetLayout.cancelButton.contains(pointerX, pointerY) {
            widgetFocus = .cancel
            widgets.cancelPressed = true; window?.setNeedsDisplay(); return
        }
        if widgetLayout.okButton.contains(pointerX, pointerY) {
            widgetFocus = .ok
            widgets.okPressed = true; window?.setNeedsDisplay()
        }
    }

    /// Open a real pop-up menu (an xdg-popup child surface) anchored under the
    /// Appearance pop-up button; choosing an item sets the value.
    private func openAppearanceMenu() {
        guard let window, menuPopup == nil else { return }
        let r = widgetLayout.popup
        let m = AquaMenu(items: widgetPopupOptions, selected: widgets.popup)
        guard let popup = window.openPopup(
            anchorX: Int32(r.x.rounded()), anchorY: Int32(r.y.rounded()),
            anchorW: Int32(r.w.rounded()), anchorH: Int32(r.h.rounded()),
            width: Int32(r.w.rounded()), height: Int32(m.preferredHeight.rounded()),
            delegate: m) else { return }
        m.popup = popup
        m.onChoose = { [weak self] idx in
            guard let self else { return }
            self.widgets.popup = idx
            self.menuPopup?.close()
            self.menu = nil
            self.menuPopup = nil
            self.window?.setNeedsDisplay()
        }
        m.onDismiss = { [weak self] in
            self?.menu = nil
            self?.menuPopup = nil
        }
        menu = m
        menuPopup = popup
    }

    // MARK: Scroll-scene input

    private func scrollClamp(_ v: Double) -> Double {
        max(0, min(v, scrollMaxOffset(viewportH: scrollLayoutCache.list.h)))
    }

    private func scrollBy(_ dy: Double) {
        let old = scrollOffset
        scrollOffset = scrollClamp(scrollOffset + dy)
        if scrollOffset != old { window?.setNeedsDisplay() }
    }

    /// Move the offset so the thumb's top edge lands at `thumbTopY`.
    private func scrollToThumbTop(_ thumbTopY: Double) {
        let L = scrollLayoutCache
        let vp = L.list.h
        guard let thumb = scrollThumbRect(track: L.track, offset: scrollOffset,
                                          viewportH: vp) else { return }
        let travel = L.track.h - thumb.h
        guard travel > 0 else { return }
        let t = max(0, min(1, (thumbTopY - L.track.y) / travel))
        scrollOffset = t * scrollMaxOffset(viewportH: vp)
    }

    private func scrollPointerButton(pressed: Bool) {
        guard pressed else { draggingThumb = false; return }
        let L = scrollLayoutCache
        let vp = L.list.h
        if let thumb = scrollThumbRect(track: L.track, offset: scrollOffset,
                                       viewportH: vp),
           thumb.contains(pointerX, pointerY) {
            draggingThumb = true
            thumbGrabDy = pointerY - thumb.y
            return
        }
        if L.upArrow.contains(pointerX, pointerY) { scrollBy(-scrollRowHeight); return }
        if L.downArrow.contains(pointerX, pointerY) { scrollBy(scrollRowHeight); return }
        if L.track.contains(pointerX, pointerY),
           let thumb = scrollThumbRect(track: L.track, offset: scrollOffset,
                                       viewportH: vp) {
            scrollBy(pointerY < thumb.y ? -vp * 0.9 : vp * 0.9)  // page toward click
        }
    }

    private func scrollKey(_ keysym: UInt32) {
        let vp = scrollLayoutCache.list.h
        switch keysym {
        case KeySym.up:       scrollBy(-scrollRowHeight)
        case KeySym.down:     scrollBy(scrollRowHeight)
        case KeySym.pageUp:   scrollBy(-vp * 0.9)
        case KeySym.pageDown: scrollBy(vp * 0.9)
        case KeySym.home:     scrollOffset = 0; window?.setNeedsDisplay()
        case KeySym.end:
            scrollOffset = scrollMaxOffset(viewportH: vp); window?.setNeedsDisplay()
        default: break
        }
    }

    // MARK: Widgets-scene keyboard focus/traversal

    private func moveWidgetFocus(_ delta: Int) {
        let order = widgetFocusOrder
        guard let i = order.firstIndex(of: widgetFocus) else {
            widgetFocus = order.first ?? .ok; return
        }
        widgetFocus = order[(i + delta + order.count) % order.count]
    }

    /// Nudge the focused slider/radio; a no-op for controls arrows don't drive.
    private func adjustFocused(_ dir: Int) {
        switch widgetFocus {
        case .radio:
            let n = widgetRadioLabels.count
            widgets.radio = (widgets.radio + dir + n) % n
        case .slider:
            widgets.slider = max(0, min(1, widgets.slider + Double(dir) * 0.05))
        default: break
        }
    }

    /// Activate a control by keyboard: toggle a checkbox, open the pop-up menu,
    /// or "press" a push button (held until the key releases).
    private func activateWidget(_ target: WidgetFocus) {
        switch target {
        case .check(let i): widgets.checks[i].toggle()
        case .popup:        openAppearanceMenu()
        case .ok:           widgets.okPressed = true
        case .cancel:       widgets.cancelPressed = true
        case .radio, .slider: break  // arrows drive these
        }
    }

    private func widgetsKey(_ event: KeyEvent) {
        // A live pop-up menu grabs the keyboard while it's open.
        if let menu, menuPopup != nil {
            if event.pressed { _ = menu.keyDown(event.keysym) }
            return
        }
        guard event.pressed else {
            // Release the keyboard-held button, if any.
            if widgets.okPressed || widgets.cancelPressed {
                widgets.okPressed = false; widgets.cancelPressed = false
                window?.setNeedsDisplay()
            }
            return
        }
        switch event.keysym {
        case KeySym.tab:     moveWidgetFocus(1)
        case KeySym.backTab: moveWidgetFocus(-1)
        case KeySym.enter:   activateWidget(.ok)      // default button
        case KeySym.escape:  activateWidget(.cancel)
        case KeySym.space:   activateWidget(widgetFocus)
        case KeySym.left, KeySym.down:  adjustFocused(-1)
        case KeySym.right, KeySym.up:   adjustFocused(1)
        default: break
        }
        window?.setNeedsDisplay()
    }

    // MARK: Sheet-scene keyboard

    private func sheetKey(_ keysym: UInt32) {
        guard sheetVisible, sheetProgress >= 1 else {
            if !sheetVisible, keysym == KeySym.enter || keysym == KeySym.space {
                openSheet()
            }
            return
        }
        switch keysym {
        case KeySym.enter:  sheetAction = "Deleted"; closeSheet()    // default
        case KeySym.escape: sheetAction = "Cancelled"; closeSheet()
        default: break
        }
    }

    public func keyEvent(_ event: KeyEvent) {
        switch sceneKind {
        case .widgets: widgetsKey(event); return
        case .scroll:  if event.pressed { scrollKey(event.keysym) }; return
        case .tabs:    if event.pressed { tabsKey(event.keysym) }; return
        case .sheet:   if event.pressed { sheetKey(event.keysym) }; return
        case .installer: installerKey(event); return
        default: break
        }
        guard event.pressed else { return }  // act on press; release is a no-op
        switch event.keysym {
        case KeySym.backspace:
            if !typedText.isEmpty { typedText.removeLast() }
        case KeySym.escape:
            typedText = ""
        case KeySym.enter, KeySym.tab:
            break  // no multiline / focus traversal yet
        default:
            // Any key that produced text lands in the field; ignore the rest
            // (arrows, modifiers, function keys report empty text).
            if !event.text.isEmpty { typedText += event.text }
        }
        window?.setNeedsDisplay()
    }
}

// MARK: - Installer-scene input (PHASE5 P5.4)
//
// Every rect comes from `installerLayoutCache`, which is what `paintInstaller`
// returned on the last frame — so what is clickable is exactly what was drawn.

extension AquaWindow {

    /// Print every rect on the current page, so a test can click by name.
    fileprivate func dumpInstallerLayout(w: Double, h: Double) {
        let l = installerLayoutCache
        // The surface size goes first: a caller clicking these has to know
        // where the window is on the output, and the window is the only thing
        // that knows how big it is.
        var parts = ["size=\(Int(w))x\(Int(h))", "primary=\(rectText(l.primary))"]
        if l.secondary.w > 0 { parts.append("secondary=\(rectText(l.secondary))") }
        for (i, r) in l.spokeRows.enumerated() { parts.append("spoke\(i)=\(rectText(r))") }
        for (i, r) in l.listRows.enumerated() { parts.append("row\(i)=\(rectText(r))") }
        for (i, r) in l.fields.enumerated() { parts.append("field\(i)=\(rectText(r))") }
        if l.adminCheck.w > 0 { parts.append("admin=\(rectText(l.adminCheck))") }
        installerLog("layout " + parts.joined(separator: " "))
    }

    fileprivate func rectText(_ r: Rect) -> String {
        // The centre, which is what a test wants to click.
        "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))"
    }

    /// Say what just happened, on stderr.
    ///
    /// An installer is driven by clicks, and a click leaves no trace — so the
    /// only way for anything (a test, or somebody reading a log after a failed
    /// install) to know what was chosen is for the app to say. Cheap, and the
    /// difference between "the window was on screen" and "the window did what
    /// it was clicked to do".
    fileprivate func installerLog(_ msg: String) {
        let line = "Installer: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    /// Build the plan the hub describes, hashing the password on the way out.
    public func installerPlan() -> InstallPlan {
        installer.plan(passwordHash: InstallerClient.hash(installer.accountPassword),
                       distDirectory: installerDistDirectory())
    }

    fileprivate func installerPointerButton(pressed: Bool) {
        let l = installerLayoutCache
        if !pressed {
            installerPressed = false
            window?.setNeedsDisplay()
            return
        }
        installerPressed = l.primary.contains(pointerX, pointerY)

        switch installer.page {
        case .hub:
            for (i, r) in l.spokeRows.enumerated() where r.contains(pointerX, pointerY) {
                installer.enter(Spoke.allCases[i])
                installerLog("entered \(Spoke.allCases[i].title)")
                window?.setNeedsDisplay()
                return
            }
            if l.primary.contains(pointerX, pointerY) {
                // The button is drawn spent when the hub is incomplete, and it
                // does nothing when pressed. Both, not either: a control that
                // looks dead and still fires is worse than one that does not
                // look dead at all.
                if installer.canInstall {
                    installer.page = .confirm
                    installerLog("confirming: erase \(installer.disk)")
                } else {
                    installerLog("install is not armed: \(installer.readiness)")
                }
            } else if l.secondary.contains(pointerX, pointerY) {
                onQuit?()
            }

        case .spoke(let spoke):
            for (i, r) in l.listRows.enumerated() where r.contains(pointerX, pointerY) {
                installer.selection = i
                window?.setNeedsDisplay()
                return
            }
            if spoke == .account {
                for (i, r) in l.fields.enumerated() where r.contains(pointerX, pointerY) {
                    accountFocus = AccountField.allCases[i]
                    window?.setNeedsDisplay()
                    return
                }
                if l.adminCheck.contains(pointerX, pointerY) {
                    installer.accountIsAdministrator.toggle()
                }
            }
            if l.primary.contains(pointerX, pointerY) {
                if spoke == .account {
                    installer.back()
                    installerLog("account is \(installer.accountName.isEmpty ? "(none)" : installer.accountName)"
                                 + (installer.passwordProblem.isEmpty ? "" : " — \(installer.passwordProblem)"))
                } else {
                    let took = installer.chooseSelection()
                    switch spoke {
                    case .disk:
                        took ? installerLog("disk is \(installer.disk)")
                             : installerLog("refused that disk: "
                                 + installer.objection(to: installer.installableDisks[installer.selection]))
                    case .keyboard: installerLog("keyboard is \(installer.keymap)")
                    case .timezone: installerLog("time zone is \(installer.timezone)")
                    case .account: break
                    }
                }
                installerLog(installer.canInstall ? "ready to install" : "not ready")
                accountFocus = nil
            } else if l.secondary.contains(pointerX, pointerY) {
                installer.back()
                accountFocus = nil
            }

        case .confirm:
            if l.primary.contains(pointerX, pointerY) {
                installer.page = .installing
                onInstall?(installerPlan())
            } else if l.secondary.contains(pointerX, pointerY) {
                installer.page = .hub
            }

        case .installing:
            break                       // nothing to click; it is happening

        case .done:
            if l.primary.contains(pointerX, pointerY) { onQuit?() }
        }
        window?.setNeedsDisplay()
    }

    fileprivate func installerKey(_ event: KeyEvent) {
        guard event.pressed else { return }
        defer { window?.setNeedsDisplay() }

        // Typing into the account fields comes first: a text field has to
        // swallow the keys a list would otherwise use.
        if case .spoke(.account) = installer.page, let field = accountFocus {
            switch event.keysym {
            case KeySym.backspace:
                switch field {
                case .fullName: if !installer.accountFullName.isEmpty { installer.accountFullName.removeLast() }
                case .name:     if !installer.accountName.isEmpty { installer.accountName.removeLast() }
                case .password: if !installer.accountPassword.isEmpty { installer.accountPassword.removeLast() }
                case .confirm:  if !installer.accountConfirm.isEmpty { installer.accountConfirm.removeLast() }
                }
                return
            case KeySym.tab:
                let all = AccountField.allCases
                let i = all.firstIndex(of: field) ?? 0
                accountFocus = all[(i + 1) % all.count]
                return
            case KeySym.enter:
                accountFocus = nil
                installer.back()
                return
            case KeySym.escape:
                accountFocus = nil
                return
            default:
                if !event.text.isEmpty {
                    switch field {
                    case .fullName: installer.accountFullName += event.text
                    case .name:     installer.accountName += event.text
                    case .password: installer.accountPassword += event.text
                    case .confirm:  installer.accountConfirm += event.text
                    }
                    return
                }
            }
        }

        switch event.keysym {
        case KeySym.down:
            if installer.spokeRowCount > 0 {
                installer.selection = min(installer.selection + 1, installer.spokeRowCount - 1)
            }
        case KeySym.up:
            installer.selection = max(installer.selection - 1, 0)
        case KeySym.enter:
            switch installer.page {
            case .hub:
                if installer.canInstall { installer.page = .confirm }
            case .spoke(let s):
                if s == .account { installer.back() } else { installer.chooseSelection() }
            case .confirm:
                installer.page = .installing
                onInstall?(installerPlan())
            case .installing: break
            case .done: onQuit?()
            }
        case KeySym.escape:
            switch installer.page {
            case .spoke: installer.back()
            case .confirm: installer.page = .hub
            default: break
            }
        default:
            break
        }
    }
}

func installerDistDirectory() -> String {
    getenv("ABYSS_DIST_DIR").map { String(cString: $0) } ?? "/usr/freebsd-dist"
}

/// A fixed machine for the PNG preview, so the shot is the same on any box.
public func installerSampleModel() -> InstallerModel {
    var m = InstallerModel(inventory: DiskInventory(disks: [
        Disk(name: "ada0", bytes: 500 << 30, description: "APPLE SSD SM0512F",
             mountedAt: ["/"], holdsRunningRoot: true),
        Disk(name: "ada1", bytes: 256 << 30, description: "Crucial CT256MX100"),
        Disk(name: "da0", bytes: 2 << 30, description: "SanDisk Cruzer"),
    ], importedPools: ["zroot"]))
    m.disk = "ada1"
    m.timezone = "America/Chicago"
    m.accountName = "jkane"
    m.accountFullName = "J Kane"
    m.accountPassword = "secret"
    m.accountConfirm = "secret"
    return m
}
