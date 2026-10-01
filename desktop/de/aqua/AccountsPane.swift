// AccountsPane — System Preferences' Accounts (PHASE16 P16.6a).
//
// Jaguar's Accounts pane: the people who can log in, each marked Admin or
// Standard; New User… and Delete User; and who, if anyone, is logged in
// automatically at boot. Every change goes through the settings helper (root,
// for an administrator only — P14.3's rule), as an `accounts` plan:
//
//   - **New User…** asks for a name, a short name, the password twice, and
//     whether they may administer this computer. The password is hashed
//     here (SHA-512 crypt, as the installer does) and only the hash goes to
//     the helper, which gives it to `pw` on stdin.
//   - **Delete User** asks first, and keeps the home folder unless told —
//     a button that says "delete user" does not delete a person's files.
//   - **Log in automatically as …** replaces the login window at boot with
//     that person's desktop; off, the login window again.
//
// What is drawn is read, not remembered: the accounts from the password
// file, the automatic login from rc.conf — so a change made elsewhere shows.

import AquaDraw
import Login
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct AccountRow: Equatable, Sendable {
    public let name: String
    public let fullName: String
    public let admin: Bool
    public init(name: String, fullName: String, admin: Bool) { self.name = name; self.fullName = fullName; self.admin = admin }
}

/// New User…'s sheet.
public struct NewUserForm: Equatable, Sendable {
    public enum Field: Int, CaseIterable, Sendable { case fullName, shortName, password, verify }
    public var fullName = "", shortName = "", password = "", verify = ""
    public var admin = false
    public var focus: Field = .fullName
    public var problem = ""
    public init() {}

    public subscript(_ f: Field) -> String {
        get { switch f { case .fullName: fullName; case .shortName: shortName; case .password: password; case .verify: verify } }
        set { switch f { case .fullName: fullName = newValue; case .shortName: shortName = newValue
                         case .password: password = newValue; case .verify: verify = newValue } }
    }

    /// Typing: a character into the focused field, Backspace, Tab between
    /// them. The short name follows the full name until it is typed itself,
    /// as the Mac's does.
    public mutating func type(_ text: String) {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return }
        let followed = shortName == NewUserForm.suggest(fullName)
        self[focus] += text
        if focus == .fullName, followed { shortName = NewUserForm.suggest(fullName) }
        problem = ""
    }
    public mutating func backspace() {
        guard !self[focus].isEmpty else { return }
        let followed = shortName == NewUserForm.suggest(fullName)
        var v = self[focus]; v.removeLast(); self[focus] = v
        if focus == .fullName, followed { shortName = NewUserForm.suggest(fullName) }
    }
    public mutating func tab(_ delta: Int = 1) {
        let all = Field.allCases
        focus = all[((focus.rawValue + delta) % all.count + all.count) % all.count]
    }

    /// "Ada Lovelace" → "ada": the first word, lower-cased, letters and digits.
    public static func suggest(_ full: String) -> String {
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        return String(first.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
                        .map(Character.init).prefix(16))
    }

    /// Why it cannot be created yet, in the sheet's words; nil when it can.
    public var whyNot: String? {
        if shortName.isEmpty { return "Type a short name." }
        if password.isEmpty { return "Type a password." }
        if password != verify { return "The passwords do not match." }
        return nil
    }

    /// Forget what was typed.
    public mutating func clear() { password = ""; verify = "" }
}

public struct AccountsPaneState: Equatable, Sendable {
    public var accounts: [AccountRow] = []
    public var selected: Int?
    public var autoLogin: String?
    public var form: NewUserForm?
    public var confirmingDelete = false
    public var removeHome = false
    public var note = ""
    public var busy = false
    public init() {}

    public var selectedAccount: AccountRow? { selected.flatMap { accounts.indices.contains($0) ? accounts[$0] : nil } }

    /// Read: the accounts from a passwd file, administrators from group's
    /// wheel, the automatic login from rc.conf.
    public static func read(passwd: String, group: String, rcConf: String) -> AccountsPaneState {
        var s = AccountsPaneState()
        let admins = LoginAccounts.members(of: "wheel", in: group)
        s.accounts = LoginAccounts.parse(passwd: passwd).map {
            AccountRow(name: $0.name, fullName: $0.fullName, admin: admins.contains($0.name))
        }
        s.autoLogin = LoginAccounts.autoLogin(rcConf: rcConf)
        s.selected = s.accounts.isEmpty ? nil : 0
        return s
    }

    public static let sample: AccountsPaneState = {
        var s = AccountsPaneState()
        s.accounts = [AccountRow(name: "ada", fullName: "Ada Lovelace", admin: true),
                      AccountRow(name: "grace", fullName: "Grace Hopper", admin: false)]
        s.selected = 0
        return s
    }()
}

public struct AccountsLayout: Equatable, Sendable {
    public var list = Rect(0, 0, 0, 0)
    public var rows: [Rect] = []
    public var newUser = Rect(0, 0, 0, 0), deleteUser = Rect(0, 0, 0, 0)
    public var autoLogin = Rect(0, 0, 0, 0)
    // The sheet, when one is open.
    public var sheet = Rect(0, 0, 0, 0)
    public var fields: [Rect] = []
    public var adminBox = Rect(0, 0, 0, 0)
    public var cancel = Rect(0, 0, 0, 0), confirm = Rect(0, 0, 0, 0)
}

public func accountsLayout(body: Rect, _ s: AccountsPaneState) -> AccountsLayout {
    var l = AccountsLayout()
    let left = body.x + 40, w = body.w - 80
    l.list = Rect(left, body.y + 40, w, 6 * 40)
    for i in 0..<min(s.accounts.count, 6) { l.rows.append(Rect(left, l.list.y + Double(i) * 40, w, 40)) }
    l.newUser = Rect(left, l.list.y + l.list.h + 12, 120, 22)
    l.deleteUser = Rect(left + 132, l.list.y + l.list.h + 12, 120, 22)
    l.autoLogin = Rect(left, l.list.y + l.list.h + 52, w, 22)
    if s.form != nil {
        l.sheet = Rect(body.x + (body.w - 420) / 2, body.y, 420, 250)
        for i in 0..<4 { l.fields.append(Rect(l.sheet.x + 150, l.sheet.y + 22 + Double(i) * 34, 240, 22)) }
        l.adminBox = Rect(l.sheet.x + 150, l.sheet.y + 160, 240, 22)
        l.cancel = Rect(l.sheet.x + l.sheet.w - 240, l.sheet.y + l.sheet.h - 36, 100, 22)
        l.confirm = Rect(l.sheet.x + l.sheet.w - 128, l.sheet.y + l.sheet.h - 36, 108, 22)
    } else if s.confirmingDelete {
        l.sheet = Rect(body.x + (body.w - 420) / 2, body.y, 420, 150)
        l.adminBox = Rect(l.sheet.x + 24, l.sheet.y + 70, 300, 22)
        l.cancel = Rect(l.sheet.x + l.sheet.w - 240, l.sheet.y + l.sheet.h - 36, 100, 22)
        l.confirm = Rect(l.sheet.x + l.sheet.w - 128, l.sheet.y + l.sheet.h - 36, 108, 22)
    }
    return l
}

public enum AccountsHit: Equatable, Sendable {
    case row(Int), newUser, deleteUser, autoLogin
    case field(NewUserForm.Field), adminBox, cancel, confirm
}

public func accountsHit(_ l: AccountsLayout, _ s: AccountsPaneState, x: Double, y: Double) -> AccountsHit? {
    if s.form != nil || s.confirmingDelete {
        // A sheet is modal: only it answers.
        for (i, r) in l.fields.enumerated() where r.contains(x, y) { return .field(NewUserForm.Field(rawValue: i)!) }
        if l.adminBox.contains(x, y) { return .adminBox }
        if l.cancel.contains(x, y) { return .cancel }
        if l.confirm.contains(x, y) { return .confirm }
        return nil
    }
    for (i, r) in l.rows.enumerated() where r.contains(x, y) { return .row(i) }
    if l.newUser.contains(x, y) { return .newUser }
    if l.deleteUser.contains(x, y) { return .deleteUser }
    if l.autoLogin.contains(x, y) { return .autoLogin }
    return nil
}

public func paintAccountsPane(_ cr: OpaquePointer, _ l: AccountsLayout, _ s: AccountsPaneState) {
    Draw.textLeft(cr, "The people who can log in to this computer:", x: l.list.x, baselineY: l.list.y - 12,
                  color: Theme.bodyText, size: 13)
    Draw.setColor(cr, Color(1, 1, 1)); cairo_rectangle(cr, l.list.x, l.list.y, l.list.w, l.list.h); cairo_fill(cr)
    Draw.setColor(cr, Color(0.6, 0.6, 0.6)); cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, l.list.x + 0.5, l.list.y + 0.5, l.list.w - 1, l.list.h - 1); cairo_stroke(cr)
    for (i, (a, r)) in zip(s.accounts, l.rows).enumerated() {
        let on = i == s.selected
        if on { Draw.setColor(cr, Color(0.22, 0.46, 0.84)); cairo_rectangle(cr, r.x + 1, r.y, r.w - 2, r.h); cairo_fill(cr) }
        let ink = on ? Color(1, 1, 1) : Theme.bodyText
        Draw.icon("icon.myAccount", cr, Rect(r.x + 8, r.y + 6, 28, 28))
        Draw.textLeft(cr, a.fullName, x: r.x + 46, baselineY: r.y + 18, color: ink, size: 13, style: .bold)
        Draw.textLeft(cr, a.name + (s.autoLogin == a.name ? " — logs in automatically" : ""),
                      x: r.x + 46, baselineY: r.y + 33, color: on ? ink : Theme.secondaryText, size: 11)
        let kind = a.admin ? "Admin" : "Standard"
        let kw = Draw.textWidth(cr, kind, size: 12)
        Draw.textLeft(cr, kind, x: r.x + r.w - kw - 12, baselineY: r.y + 25, color: ink, size: 12)
    }
    Draw.gelButton(cr, l.newUser, label: "New User…", blue: false, pressed: false)
    Draw.gelButton(cr, l.deleteUser, label: "Delete User", blue: false, pressed: false)
    let who = s.selectedAccount
    Draw.checkbox(cr, Rect(l.autoLogin.x, l.autoLogin.y + 3, 16, 16), checked: who != nil && s.autoLogin == who?.name)
    Draw.textLeft(cr, "Log in automatically as " + (who?.fullName ?? "the selected user"),
                  x: l.autoLogin.x + 24, baselineY: l.autoLogin.y + 15, color: Theme.bodyText, size: 13)
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: l.list.x, baselineY: l.autoLogin.y + 48, color: Theme.bodyText, size: 12)
    }

    if let f = s.form {
        paintSheetBackground(cr, l.sheet)
        let labels = ["Name:", "Short Name:", "Password:", "Verify:"]
        for (i, field) in NewUserForm.Field.allCases.enumerated() {
            let r = l.fields[i]
            let w = Draw.textWidth(cr, labels[i], size: 13)
            Draw.textLeft(cr, labels[i], x: r.x - 12 - w, baselineY: r.y + 16, color: Theme.bodyText, size: 13)
            let text = field == .password || field == .verify ? String(repeating: "•", count: f[field].count) : f[field]
            Draw.textField(cr, r, text: text, caret: f.focus == field)
        }
        Draw.checkbox(cr, Rect(l.adminBox.x, l.adminBox.y + 3, 16, 16), checked: f.admin)
        Draw.textLeft(cr, "Allow user to administer this computer", x: l.adminBox.x + 24, baselineY: l.adminBox.y + 15,
                      color: Theme.bodyText, size: 12)
        if !f.problem.isEmpty {
            Draw.textLeft(cr, f.problem, x: l.sheet.x + 24, baselineY: l.cancel.y + 16, color: Color(0.65, 0.05, 0.05), size: 11)
        }
        Draw.gelButton(cr, l.cancel, label: "Cancel", blue: false, pressed: false)
        Draw.gelButton(cr, l.confirm, label: "Create User", blue: true, pressed: false)
    } else if s.confirmingDelete, let who {
        paintSheetBackground(cr, l.sheet)
        Draw.textLeft(cr, "Delete the account \(who.fullName) (\(who.name))?", x: l.sheet.x + 24, baselineY: l.sheet.y + 40,
                      color: Theme.bodyText, size: 13, style: .bold)
        Draw.checkbox(cr, Rect(l.adminBox.x, l.adminBox.y + 3, 16, 16), checked: s.removeHome)
        Draw.textLeft(cr, "Delete the home folder too", x: l.adminBox.x + 24, baselineY: l.adminBox.y + 15,
                      color: Theme.bodyText, size: 12)
        Draw.gelButton(cr, l.cancel, label: "Cancel", blue: false, pressed: false)
        Draw.gelButton(cr, l.confirm, label: "Delete", blue: true, pressed: false)
    }
}

private func paintSheetBackground(_ cr: OpaquePointer, _ r: Rect) {
    Draw.setColor(cr, Color(0, 0, 0, 0.25)); cairo_rectangle(cr, r.x + 3, r.y + 3, r.w, r.h); cairo_fill(cr)
    Draw.setColor(cr, Theme.contentBackground); cairo_rectangle(cr, r.x, r.y, r.w, r.h); cairo_fill(cr)
    Draw.pinstripe(cr, r, Color(1, 1, 1, 0.4))
    Draw.setColor(cr, Color(0.55, 0.55, 0.55)); cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1); cairo_stroke(cr)
}
