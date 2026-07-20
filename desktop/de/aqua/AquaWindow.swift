// AquaWindow — a top-level Jaguar window: rounded chrome, gradient title bar,
// traffic lights, a pinstriped content area, and a live default gel button.
// It owns a Surface.Window and serves as its WindowDelegate.

import Surface
import CCairo

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

    public init?(display: Display, title: String, scene: SceneKind = .window,
                 width: Int32 = 440, height: Int32 = 300) {
        self.title = title
        self.sceneKind = scene
        guard let win = Window(display: display, title: title,
                               appID: "org.abyssbsd.aquademo",
                               width: width, height: height,
                               scale: AquaWindow.envScale(),
                               delegate: self) else { return nil }
        window = win
        display.window = win
    }

    private static func envScale() -> Int32 {
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 {
            return v
        }
        return 1
    }

    // MARK: WindowDelegate

    public func render(_ buffer: PixelBuffer) {
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
            widgetLayout = paintWidgets(cr, w: w, h: h, state: widgets)
        case .scroll:
            scrollLayoutCache = paintScroll(cr, w: w, h: h, offset: scrollOffset)
        case .tabs:
            tabsLayoutCache = paintTabs(cr, w: w, h: h, state: tabs)
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

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft else { return }
        switch sceneKind {
        case .widgets: widgetsPointerButton(pressed: pressed)
        case .scroll:  scrollPointerButton(pressed: pressed)
        case .tabs:    tabsPointerButton(pressed: pressed)
        default:       windowPointerButton(pressed: pressed)
        }
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
            if widgets.okPressed { widgets.okPressed = false; window?.setNeedsDisplay() }
            return
        }
        for (i, r) in widgetLayout.checks.enumerated()
        where r.contains(pointerX, pointerY) {
            widgets.checks[i].toggle(); window?.setNeedsDisplay(); return
        }
        for (i, r) in widgetLayout.radios.enumerated()
        where r.contains(pointerX, pointerY) {
            widgets.radio = i; window?.setNeedsDisplay(); return
        }
        if widgetLayout.sliderTrack.contains(pointerX, pointerY) {
            draggingSlider = true
            widgets.slider = sliderValue(at: pointerX)
            window?.setNeedsDisplay(); return
        }
        if widgetLayout.popup.contains(pointerX, pointerY) {
            openAppearanceMenu(); return
        }
        if widgetLayout.okButton.contains(pointerX, pointerY) {
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

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }  // act on press; release is a no-op
        if sceneKind == .scroll { scrollKey(event.keysym); return }
        if sceneKind == .tabs { tabsKey(event.keysym); return }
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
