// Tabs — a scene showing the two joined-button Aqua controls: a segmented
// control (a view switcher) and a tab view (rounded tabs on a content pane whose
// body changes with the selection). As elsewhere, one layout is the single
// source of geometry; the segmented rects + pane are pure, and the (text-width
// dependent) tab rects are computed during paint and returned for hit-testing.

import CCairo

public struct TabsState: Sendable {
    public var segment: Int
    public var tab: Int
    public init(segment: Int = 0, tab: Int = 0) {
        self.segment = segment; self.tab = tab
    }
}

public struct TabsLayout {
    public var segments: [Rect] = []
    public var tabs: [Rect] = []
    public var pane = Rect(0, 0, 0, 0)
}

public let tabsSegmentLabels = ["Icons", "List", "Columns"]
public let tabsTabLabels = ["General", "Advanced", "Sharing"]

// Per-tab pane content: a heading plus a couple of body lines.
private let tabsContent: [(String, [String])] = [
    ("General", ["General settings live here.",
                 "The basics, front and centre."]),
    ("Advanced", ["Advanced options for power users.",
                  "Tuning knobs — handle with care."]),
    ("Sharing", ["Share this Mac on the network.",
                 "Services, computer name, and access."]),
]

private let tabsMargin = 20.0
private func tabsSegRect() -> Rect {
    Rect(tabsMargin + 52, Theme.titleBarHeight + 18, 240, 22)
}

/// Pure geometry: the segmented rects and the tab pane. (Tab rects depend on
/// text width and are filled in during paint.)
public func tabsLayout(w: Double, h: Double) -> TabsLayout {
    var L = TabsLayout()
    L.segments = Draw.segmentRects(tabsSegRect(), count: tabsSegmentLabels.count)
    let paneTop = Theme.titleBarHeight + 74
    L.pane = Rect(tabsMargin, paneTop, w - 2 * tabsMargin, h - paneTop - tabsMargin)
    return L
}

/// Paint the tabs scene and return its layout (including the tab rects).
@discardableResult
public func paintTabs(_ cr: OpaquePointer, w: Double, h: Double,
                      state: TabsState) -> TabsLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Tab View")
    var L = tabsLayout(w: w, h: h)

    // Segmented control ("View:").
    let segRect = tabsSegRect()
    Draw.textLeft(cr, "View:", x: tabsMargin,
                  baselineY: segRect.y + segRect.h / 2 + 4,
                  color: Theme.controlLabel, size: Theme.fontSize)
    Draw.segmentedControl(cr, segRect, labels: tabsSegmentLabels,
                          selected: state.segment)

    // Tab view: pane, then tabs (unselected first, the selected one on top).
    Draw.tabPane(cr, L.pane)
    let tabH = 24.0
    let widths = tabsTabLabels.map {
        max(64, Draw.textWidth(cr, $0, size: Theme.fontSize) + 34)
    }
    let total = widths.reduce(0, +)
    var x = (w - total) / 2
    var tabs: [Rect] = []
    for tw in widths {
        tabs.append(Rect(x, L.pane.y - tabH, tw, tabH))
        x += tw
    }
    L.tabs = tabs
    for (i, tr) in tabs.enumerated() where i != state.tab {
        Draw.tab(cr, tr, label: tabsTabLabels[i], selected: false)
    }
    let sel = tabs[min(max(state.tab, 0), tabs.count - 1)]
    Draw.tab(cr, sel, label: tabsTabLabels[state.tab], selected: true)
    // Merge the selected tab into the pane by erasing the border beneath it.
    Draw.paint("tab.merge", cr, sel, parameters: ["pane": L.pane.y - sel.y])

    // Pane content for the selected tab.
    let (heading, lines) = tabsContent[state.tab]
    let cx = L.pane.x + 20
    var cy = L.pane.y + 34
    Draw.textLeft(cr, heading, x: cx, baselineY: cy, color: Theme.bodyText, size: 15)
    cy += 28
    for line in lines {
        Draw.textLeft(cr, line, x: cx, baselineY: cy,
                      color: Theme.bodyText.with(a: 0.75), size: Theme.fontSize)
        cy += 20
    }
    return L
}
