// The Installer's pixels — and, first, its geometry.
//
// `installerLayout` is the single source of truth for where everything is, read
// by the painter below and by the hit-tester in `AquaWindow`. That is the same
// discipline `widgetsLayout` established, and it is what makes "what you see is
// exactly what you can click" true by construction rather than by care.

import CCairo
import Install

/// Every rect the installer has, for whichever page it is on.
public struct InstallerLayout: Sendable {
    public var spokeRows: [Rect] = []      // hub: one per Spoke, in order
    public var listRows: [Rect] = []       // spoke: one per choice
    public var fields: [Rect] = []         // account spoke: the text fields
    public var adminCheck = Rect(0, 0, 0, 0)
    public var primary = Rect(0, 0, 0, 0)  // Install / Choose / Erase / Restart
    public var secondary = Rect(0, 0, 0, 0) // Quit / Back / Cancel
    /// The labels too, so the painter and the hit-tester cannot disagree about
    /// which button is which — and so a button can be as wide as its own words.
    public var primaryLabel = ""
    public var secondaryLabel = ""
    public var progress = Rect(0, 0, 0, 0)
    public init() {}
}

/// The account spoke's fields, in Tab order.
public enum AccountField: Int, CaseIterable, Sendable {
    case fullName, name, password, confirm
    public var label: String {
        switch self {
        case .fullName: return "Name:"
        case .name:     return "Short Name:"
        case .password: return "Password:"
        case .confirm:  return "Verify:"
        }
    }
    public var secret: Bool { self == .password || self == .confirm }
}

private let pad = 20.0
private let rowH = 46.0
private let buttonW = 108.0
private let buttonH = 24.0

public func installerLayout(w: Double, h: Double, model: InstallerModel) -> InstallerLayout {
    var l = InstallerLayout()

    switch model.page {
    case .hub:       l.primaryLabel = "Install\u{2026}";     l.secondaryLabel = "Quit"
    case .spoke(let s):
        l.primaryLabel = s == .account ? "Done" : "Choose";  l.secondaryLabel = "Back"
    // **The destructive verb, and the disk's own name, on the button.** "OK" on
    // a sheet like this is how people click through them; "Erase nda1" is a
    // sentence somebody can disagree with. Cancel is second, which is where the
    // eye and the Escape key both go.
    case .eraseConfirm(let d):
        l.primaryLabel = "Erase \(d)"; l.secondaryLabel = "Cancel"
    case .confirm:   l.primaryLabel = "Erase and Install";   l.secondaryLabel = "Cancel"
    case .installing: break
    case .done(let ok, _):
        l.primaryLabel = ok ? "Restart" : "Quit"
    }

    // A gel button is as wide as its words need, never a fixed 108 that clips
    // them — "Erase and Install" is the label that matters most on this screen
    // and it is also the longest.
    let bottom = h - pad - buttonH
    let pw = max(buttonW, labelWidth(l.primaryLabel) + 34)
    let sw = max(buttonW, labelWidth(l.secondaryLabel) + 34)
    l.primary = Rect(w - pad - pw, bottom, pw, buttonH)
    l.secondary = l.secondaryLabel.isEmpty
        ? Rect(0, 0, 0, 0)
        : Rect(w - pad - pw - 10 - sw, bottom, sw, buttonH)

    switch model.page {
    case .hub:
        var y = pad + 52
        for _ in Spoke.allCases {
            l.spokeRows.append(Rect(pad, y, w - pad * 2, rowH))
            y += rowH + 8
        }
    case .spoke(let s):
        if s == .account {
            var y = pad + 60
            for _ in AccountField.allCases {
                l.fields.append(Rect(pad + 120, y, w - pad * 2 - 130, 22))
                y += 34
            }
            l.adminCheck = Rect(pad + 120, y + 4, 16, 16)
        } else {
            var y = pad + 52
            let n = model.spokeRowCount
            for _ in 0..<n {
                l.listRows.append(Rect(pad, y, w - pad * 2, 26))
                y += 27
            }
        }
    case .eraseConfirm, .confirm:
        break
    case .installing:
        l.progress = Rect(pad, h / 2, w - pad * 2, 14)
    case .done:
        break
    }
    return l
}

/// Paint the installer, returning the layout that was used — so the caller
/// hit-tests exactly what it drew.
@discardableResult
public func paintInstaller(_ cr: OpaquePointer, w: Double, h: Double,
                           model: InstallerModel,
                           focus: AccountField? = nil,
                           pressed: Bool = false) -> InstallerLayout {
    let l = installerLayout(w: w, h: h, model: model)

    // The window body: Aqua's pale, with the pinstripe at the top the way a
    // Jaguar utility window wears it.
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, 0, w, h)
    cairo_fill(cr)
    Draw.pinstripe(cr, Rect(0, 0, w, 40), Theme.pinstripe)
    Draw.setColor(cr, Theme.separator)
    cairo_rectangle(cr, 0, 39.5, w, 1)
    cairo_fill(cr)

    switch model.page {
    case .hub:
        Draw.textLeft(cr, "Install AbyssBSD", x: pad, baselineY: 26,
                      color: Theme.bodyText, size: 15, style: .bold)
        for (i, spoke) in Spoke.allCases.enumerated() {
            paintSpokeRow(cr, l.spokeRows[i], spoke: spoke, model: model)
        }
        // The readiness line sits with the button it governs, not at the top
        // where nobody reads it.
        Draw.textLeft(cr, model.readiness, x: pad, baselineY: h - pad - 6,
                      color: model.canInstall ? Theme.bodyText : Theme.attentionText,
                      size: 11)
        Draw.gelButton(cr, l.secondary, label: l.secondaryLabel, blue: false, pressed: false)
        Draw.gelButton(cr, l.primary, label: l.primaryLabel,
                       blue: model.canInstall, pressed: pressed)
        // A button that cannot be pressed says so by looking spent, not by
        // being missing: the user needs to see WHERE the install starts while
        // they are still filling in what it needs.
        if !model.canInstall { veil(cr, l.primary) }

    case .spoke(let s):
        Draw.textLeft(cr, s.title, x: pad, baselineY: 26,
                      color: Theme.bodyText, size: 15, style: .bold)
        if s == .account {
            paintAccountSpoke(cr, w: w, l: l, model: model, focus: focus)
        } else {
            paintListSpoke(cr, l: l, s: s, model: model)
        }
        Draw.gelButton(cr, l.secondary, label: l.secondaryLabel, blue: false, pressed: false)
        Draw.gelButton(cr, l.primary, label: l.primaryLabel, blue: true, pressed: pressed)

    case .eraseConfirm:
        paintEraseConfirm(cr, w: w, h: h, model: model)
        Draw.gelButton(cr, l.secondary, label: l.secondaryLabel, blue: true, pressed: false)
        Draw.gelButton(cr, l.primary, label: l.primaryLabel, blue: false, pressed: pressed)

    case .confirm:
        paintConfirm(cr, w: w, h: h, model: model)
        Draw.gelButton(cr, l.secondary, label: l.secondaryLabel, blue: true, pressed: false)
        // **The destructive verb is on the button**, and Cancel is the blue
        // default. "OK" on a sheet that erases a disk is how people click
        // through them without reading.
        Draw.gelButton(cr, l.primary, label: l.primaryLabel, blue: false, pressed: pressed)

    case .installing:
        Draw.textLeft(cr, "Installing AbyssBSD", x: pad, baselineY: 26,
                      color: Theme.bodyText, size: 15, style: .bold)
        let frac = model.stepTotal > 0
            ? Double(model.stepIndex) / Double(model.stepTotal) : 0
        Draw.progressBar(cr, l.progress, value: frac)
        Draw.textLeft(cr, model.stepWhat, x: pad, baselineY: l.progress.y - 10,
                      color: Theme.bodyText, size: 12)
        Draw.textLeft(cr, "Step \(model.stepIndex) of \(model.stepTotal)",
                      x: pad, baselineY: l.progress.y + 34,
                      color: Theme.secondaryText, size: 11)

    case .done(let ok, let error):
        Draw.textLeft(cr, ok ? "AbyssBSD is installed" : "The installation failed",
                      x: pad, baselineY: 26, color: Theme.bodyText, size: 15, style: .bold)
        Draw.textLeft(cr, ok ? "Restart, and remove the installation medium." : error,
                      x: pad, baselineY: 80,
                      color: ok ? Theme.bodyText : Theme.attentionText, size: 12)
        Draw.gelButton(cr, l.primary, label: l.primaryLabel, blue: true, pressed: pressed)
    }
    return l
}

// MARK: - The hub's rows

private func paintSpokeRow(_ cr: OpaquePointer, _ r: Rect,
                           spoke: Spoke, model: InstallerModel) {
    let done = model.complete(spoke)
    Draw.setColor(cr, done ? Theme.rowBackground : Theme.attentionBackground)
    Draw.roundedRect(cr, r, radius: 6)
    cairo_fill(cr)
    Draw.setColor(cr, Theme.separator)
    Draw.roundedRect(cr, r, radius: 6)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    Draw.textLeft(cr, spoke.title, x: r.x + 12, baselineY: r.y + 19,
                  color: Theme.bodyText, size: 12, style: .bold)
    Draw.textLeft(cr, model.status(spoke), x: r.x + 12, baselineY: r.y + 36,
                  color: done ? Theme.secondaryText : Theme.attentionText, size: 11)

    // A spoke that still needs answering wears a mark. Required and unanswered
    // is a different thing from optional and defaulted, and the hub should not
    // make you read both lines to tell.
    if spoke.required && !done {
        Draw.text(cr, "!", centerX: r.x + r.w - 18, centerY: r.y + r.h / 2,
                  color: Theme.attentionText, size: 15, style: .bold)
    }
}

// MARK: - A list spoke

private func paintListSpoke(_ cr: OpaquePointer, l: InstallerLayout,
                            s: Spoke, model: InstallerModel) {
    for (i, row) in l.listRows.enumerated() {
        let selected = i == model.selection
        var label = ""
        var detail = ""
        var refused = false
        switch s {
        case .keyboard: label = installerKeymaps[i]
        case .timezone: label = installerTimezones[i]
        case .disk:
            let d = model.installableDisks[i]
            label = d.description.isEmpty ? d.name : "\(d.name) — \(d.description)"
            let why = model.objection(to: d)
            refused = !why.isEmpty
            detail = refused ? why : gib(d.bytes)
        case .account: break
        }
        if selected {
            Draw.setColor(cr, refused ? Theme.trafficInactive : Theme.menuHighlight)
            cairo_rectangle(cr, row.x, row.y, row.w, row.h)
            cairo_fill(cr)
        }
        // A disk that cannot be used is shown greyed, WITH its reason — never
        // hidden. A picker that silently omits your disk is one you argue with.
        Draw.textLeft(cr, label, x: row.x + 10, baselineY: row.y + 18,
                      color: refused ? Theme.secondaryText
                           : (selected ? Theme.menuTextOnHighlight : Theme.bodyText),
                      size: 12)
        if !detail.isEmpty {
            Draw.textLeft(cr, detail,
                          x: row.x + row.w - 10 - Draw.textWidth(cr, detail, size: 11),
                          baselineY: row.y + 18,
                          color: refused ? Theme.attentionText
                               : (selected ? Theme.menuTextOnHighlight : Theme.secondaryText),
                          size: 11)
        }
    }
}

// MARK: - The account spoke

private func paintAccountSpoke(_ cr: OpaquePointer, w: Double, l: InstallerLayout,
                               model: InstallerModel, focus: AccountField?) {
    for (i, field) in AccountField.allCases.enumerated() {
        let r = l.fields[i]
        Draw.textLeft(cr, field.label, x: pad, baselineY: r.y + 15,
                      color: Theme.bodyText, size: 12)
        var value: String
        switch field {
        case .fullName: value = model.accountFullName
        case .name:     value = model.accountName
        case .password: value = model.accountPassword
        case .confirm:  value = model.accountConfirm
        }
        if field.secret { value = String(repeating: "•", count: value.count) }
        Draw.textField(cr, r, text: value, caret: focus == field)
    }
    Draw.checkbox(cr, l.adminCheck, checked: model.accountIsAdministrator)
    Draw.textLeft(cr, "Allow this account to administer this computer",
                  x: l.adminCheck.x + 24, baselineY: l.adminCheck.y + 13,
                  color: Theme.bodyText, size: 12)
    if !model.passwordProblem.isEmpty {
        Draw.textLeft(cr, model.passwordProblem, x: pad, baselineY: l.adminCheck.y + 44,
                      color: Theme.attentionText, size: 11)
    }
}

// MARK: - Asking before destroying somebody else's data

/// The sheet that stands between a full disk and being chosen.
///
/// **Cancel is the blue one.** Aqua's default button is the lickable one, and on
/// every other screen in this installer that is the affirmative — here it is the
/// way out. That inversion is the whole point: the default action on a sheet
/// that destroys somebody's Windows install should be *not doing that*, and the
/// eye goes to the blue button whether or not the words were read.
private func paintEraseConfirm(_ cr: OpaquePointer, w: Double, h: Double,
                               model: InstallerModel) {
    guard let d = model.eraseSubject else { return }
    Draw.textLeft(cr, "Erase \(d.name)?", x: pad, baselineY: 26,
                  color: Theme.bodyText, size: 15, style: .bold)

    // The disk, so it can be recognised — a name alone is not identification on
    // a machine with three of them.
    Draw.textLeft(cr, "\(gib(d.bytes)) — \(d.description.isEmpty ? "disk" : d.description)",
                  x: pad, baselineY: 52, color: Theme.secondaryText, size: 12)

    // **What is on it, in attention colour, one item per line.** A comma-joined
    // sentence reads as prose and gets skimmed; a list reads as an inventory and
    // gets counted.
    var y = 84.0
    Draw.textLeft(cr, "This disk contains:", x: pad, baselineY: y,
                  color: Theme.bodyText, size: 12)
    y += 20
    let items = d.contents.isEmpty ? ["existing partitions"] : d.contents
    for item in items {
        Draw.textLeft(cr, "\u{2022}  " + item, x: pad + 12, baselineY: y,
                      color: Theme.attentionText, size: 12)
        y += 18
    }
    y += 10
    for line in ["Installing AbyssBSD here erases the whole disk.",
                 "This cannot be undone."] {
        Draw.textLeft(cr, line, x: pad, baselineY: y, color: Theme.bodyText, size: 12)
        y += 18
    }
}

// MARK: - The point of no return

private func paintConfirm(_ cr: OpaquePointer, w: Double, h: Double,
                          model: InstallerModel) {
    Draw.textLeft(cr, "Erase \(model.disk)?", x: pad, baselineY: 26,
                  color: Theme.bodyText, size: 15, style: .bold)
    let d = model.inventory.disk(named: model.disk)
    // **The disk is named in the sentence, with what is on it.** Every installer
    // gets this wrong the same way — a warning nobody reads, then a progress bar
    // past the point of no return. The disk, its size and its description are
    // the three things that tell somebody whether this is the right one.
    var lines = [
        "Everything on \(model.disk) will be erased and cannot be recovered."
    ]
    if let d {
        lines.append("\(model.disk) is a \(gib(d.bytes)) disk"
                     + (d.description.isEmpty ? "." : " — \(d.description)."))
        if !d.mountedAt.isEmpty {
            lines.append("It is currently in use at " + d.mountedAt.joined(separator: ", ") + ".")
        }
    }
    lines.append("AbyssBSD will be installed on it, and \(model.hostname) will be"
                 + " the name of this computer.")
    var y = 80.0
    for line in lines {
        Draw.textLeft(cr, line, x: pad, baselineY: y, color: Theme.bodyText, size: 12)
        y += 22
    }
}

/// Grey out a control that is present but cannot be used.
private func veil(_ cr: OpaquePointer, _ r: Rect) {
    Draw.roundedRect(cr, r, radius: r.h / 2)
    Draw.setColor(cr, Theme.disabledVeil)
    cairo_fill(cr)
}

/// How wide a button label is, without a cairo context to ask.
///
/// `Draw.textWidth` needs one, and layout runs before any painting — so this
/// approximates from the shaped advance of the font at button size. It only has
/// to be close: the result is a minimum width, and it is compared against a
/// floor of \(Int(buttonW)) points.
private func labelWidth(_ s: String) -> Double {
    Text.available
        ? Text.width(Text.shape(s, px: Text.px(12), style: .regular)) : Double(s.count) * 7
}
