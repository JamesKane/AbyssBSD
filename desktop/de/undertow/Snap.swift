// Undertow — edge snapping (PHASE9.md P9.4).
//
// Drag a window to an edge and let go, and it takes that half of the screen.
// The one tiling affordance this project offers on purpose (PLAN, "What is
// deliberately not on this roadmap"): it is the gesture every desktop has
// converged on, it needs no mode and no keybinding, and a person who never
// drags to an edge never meets it.
//
// **It is a pure function from a cursor position and a rectangle to a
// rectangle**, which is why it lives in its own file with its own tests rather
// than inside the move grab. §2.9's discipline again: the rule that decides
// what a drag *means* must not need a running desktop to verify — and the
// cases that matter (a corner belongs to one zone, not two; a drag that ends
// in the middle snaps to nothing) are exactly the ones a live test would be
// clumsiest at.

/// Where a drag ending at the cursor would put a window.
public enum SnapZone: Equatable, Sendable {
    case left       // the left half
    case right      // the right half
    case maximize   // the whole usable area — the top edge, as on Windows/GNOME
}

public enum WindowSnap {
    /// How close to an edge the cursor must be, in logical pixels.
    ///
    /// One pixel would be unhittable and a hundred would fire when nobody meant
    /// it. Sixteen is about a finger's width of slop at 1x and still leaves the
    /// middle of even a small output overwhelmingly un-snapped.
    public static let margin: Int32 = 16

    /// The zone a cursor is in, or nil for "no snap — leave the window alone".
    ///
    /// `area` is the **usable** area, not the output: snapping a window under
    /// the menu bar would be the same defect as placing one there (P6.4), and
    /// the top edge means "maximize", which is defined as the usable area too.
    ///
    /// The top edge wins over the side edges at the two upper corners. That is a
    /// choice, and the reason is that both readings are defensible but only one
    /// can happen: a corner that sometimes maximized and sometimes halved would
    /// be a coin toss the person cannot see the edge of.
    public static func zone(cursorX x: Int32, cursorY y: Int32, area: Rect) -> SnapZone? {
        guard area.width > 0, area.height > 0 else { return nil }
        // Outside the usable area entirely (under the menu bar, say) is not a
        // snap: the pointer is somewhere this rule has nothing to say about.
        guard x >= area.x - margin, x <= area.x + area.width + margin,
              y >= area.y - margin, y <= area.y + area.height + margin
        else { return nil }
        if y <= area.y + margin { return .maximize }
        if x <= area.x + margin { return .left }
        if x >= area.x + area.width - 1 - margin { return .right }
        return nil
    }

    /// The rectangle a zone means, within `area`.
    ///
    /// Odd widths go to the left half, so the two halves always tile the area
    /// exactly — a one-pixel gutter down the middle of the screen is the kind of
    /// thing nobody reports and everybody sees.
    public static func rect(for zone: SnapZone, in area: Rect) -> Rect {
        switch zone {
        case .maximize:
            return area
        case .left:
            let w = (area.width + 1) / 2
            return Rect(x: area.x, y: area.y, width: w, height: area.height)
        case .right:
            let w = (area.width + 1) / 2
            return Rect(x: area.x + w, y: area.y, width: area.width - w,
                        height: area.height)
        }
    }
}
