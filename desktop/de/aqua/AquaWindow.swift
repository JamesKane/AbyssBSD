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
                                         buttonPressed: buttonPressed)
        case .systemPreferences:
            paintSystemPreferences(cr, w: w, h: h)
        }
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x
        pointerY = y
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft else { return }
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
}
