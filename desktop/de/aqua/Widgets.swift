// Widgets — a showcase scene of the classic Aqua controls (checkbox, radio,
// slider, pop-up button, progress bar, push buttons), wired to live input.
//
// Geometry lives in one place: `widgetsLayout(w:h:)` returns every control's
// rect, and BOTH the painter (paintWidgets) and the hit-tester (AquaWindow)
// read it, so what you see is exactly what you can click. State is a plain
// struct the caller owns.

import CCairo

public struct WidgetState: Sendable {
    public var checks: [Bool]
    public var radio: Int
    public var slider: Double        // 0…1
    public var popup: Int
    public var okPressed: Bool

    public init(checks: [Bool] = [true, false, true], radio: Int = 1,
                slider: Double = 0.6, popup: Int = 0, okPressed: Bool = false) {
        self.checks = checks; self.radio = radio; self.slider = slider
        self.popup = popup; self.okPressed = okPressed
    }
}

/// Resolved rects for one widgets scene. Interactive rects are hit-tested;
/// `checkBoxes`/`progress` are draw-only geometry.
public struct WidgetLayout {
    public var checks: [Rect] = []        // clickable strips (box + label)
    public var checkBoxes: [Rect] = []    // the 14px boxes themselves
    public var radios: [Rect] = []        // clickable strips
    public var radioCenters: [(Double, Double)] = []
    public var sliderTrack = Rect(0, 0, 0, 0)
    public var progress = Rect(0, 0, 0, 0)
    public var popup = Rect(0, 0, 0, 0)
    public var okButton = Rect(0, 0, 0, 0)
    public var cancelButton = Rect(0, 0, 0, 0)
}

public let widgetCheckLabels = [
    "Play user interface sound effects",
    "Show all file extensions",
    "Use smooth scrolling",
]
public let widgetRadioLabels = ["Small", "Medium", "Large"]
public let widgetPopupOptions = ["Aqua Blue", "Graphite"]

/// Pure geometry for the widgets scene at logical size (w, h).
public func widgetsLayout(w: Double, h: Double) -> WidgetLayout {
    var L = WidgetLayout()
    let m = 22.0
    let boxSize = 14.0

    // Options group box with three checkboxes.
    let groupTop = Theme.titleBarHeight + 26
    let rowH = 24.0
    let group = Rect(m, groupTop, w - 2 * m, rowH * 3 + 18)
    let boxX = group.x + 14
    for i in 0..<widgetCheckLabels.count {
        let box = Rect(boxX, group.y + 15 + Double(i) * rowH, boxSize, boxSize)
        L.checkBoxes.append(box)
        L.checks.append(Rect(box.x, box.y - 3, group.w - 28, 20))
    }

    // Radio group ("Icon size:") on one row.
    let radioCy = group.y + group.h + 26
    let radioR = 7.0
    let slot0 = m + 84.0, gap = 92.0
    for i in 0..<widgetRadioLabels.count {
        let cx = slot0 + Double(i) * gap
        L.radioCenters.append((cx, radioCy))
        L.radios.append(Rect(cx - radioR - 2, radioCy - 9, gap - 6, 18))
    }

    // Slider ("Volume:") + a progress bar mirroring it. The label column is
    // wide enough for the longest label ("Appearance:").
    let trackX = m + 96.0
    let sliderY = radioCy + 24
    L.sliderTrack = Rect(trackX, sliderY, w - m - trackX, 18)
    let progY = sliderY + 30
    L.progress = Rect(trackX, progY + 4, w - m - trackX, 10)

    // Pop-up button ("Appearance:").
    let popupY = progY + 30
    L.popup = Rect(trackX, popupY, 170, 22)

    // Push buttons, bottom-right.
    let bw = 92.0, bh = 28.0, by = h - bh - 18
    L.okButton = Rect(w - bw - 18, by, bw, bh)
    L.cancelButton = Rect(w - 2 * bw - 30, by, bw, bh)
    return L
}

/// Paint the widgets scene and return its layout for hit-testing.
@discardableResult
public func paintWidgets(_ cr: OpaquePointer, w: Double, h: Double,
                         state: WidgetState) -> WidgetLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Aqua Controls")
    let L = widgetsLayout(w: w, h: h)
    let m = 22.0

    Draw.textLeft(cr, "A tour of the Jaguar control set", x: m,
                  baselineY: Theme.titleBarHeight + 20,
                  color: Theme.bodyText.with(a: 0.75), size: Theme.fontSize)

    // Options group + checkboxes.
    let group = Rect(m, Theme.titleBarHeight + 26, w - 2 * m, 24 * 3 + 18)
    Draw.groupBox(cr, group, title: "Options")
    for i in 0..<widgetCheckLabels.count {
        let box = L.checkBoxes[i]
        Draw.checkbox(cr, box, checked: state.checks[i])
        Draw.textLeft(cr, widgetCheckLabels[i], x: box.x + box.w + 8,
                      baselineY: box.y + box.h - 2.5,
                      color: Theme.controlLabel, size: Theme.fontSize)
    }

    // Radio group.
    let radioCy = L.radioCenters.first?.1 ?? 0
    Draw.textLeft(cr, "Icon size:", x: m, baselineY: radioCy + 4,
                  color: Theme.controlLabel, size: Theme.fontSize)
    for i in 0..<widgetRadioLabels.count {
        let (cx, cy) = L.radioCenters[i]
        Draw.radioButton(cr, cx: cx, cy: cy, radius: 7, selected: state.radio == i)
        Draw.textLeft(cr, widgetRadioLabels[i], x: cx + 12, baselineY: cy + 4,
                      color: Theme.controlLabel, size: Theme.fontSize)
    }

    // Slider + progress mirror.
    Draw.textLeft(cr, "Volume:", x: m,
                  baselineY: L.sliderTrack.y + L.sliderTrack.h / 2 + 4,
                  color: Theme.controlLabel, size: Theme.fontSize)
    Draw.slider(cr, L.sliderTrack, value: state.slider)
    Draw.textLeft(cr, "Level:", x: m, baselineY: L.progress.y + L.progress.h + 1,
                  color: Theme.controlLabel, size: Theme.fontSize)
    Draw.progressBar(cr, L.progress, value: state.slider)

    // Pop-up button.
    Draw.textLeft(cr, "Appearance:", x: m, baselineY: L.popup.y + L.popup.h / 2 + 4,
                  color: Theme.controlLabel, size: Theme.fontSize)
    Draw.popUpButton(cr, L.popup, label: widgetPopupOptions[state.popup])

    // Push buttons.
    Draw.gelButton(cr, L.cancelButton, label: "Cancel", blue: false, pressed: false)
    Draw.gelButton(cr, L.okButton, label: "OK", blue: true, pressed: state.okPressed)
    return L
}
