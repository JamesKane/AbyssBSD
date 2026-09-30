// The Installer — the hub, its spokes, and the plan they add up to.
//
// This file is the *model*. Where it goes and what it may do live here as
// values; `InstallerView.swift` draws them and `AquaWindow` routes clicks and
// keys into them. The split is the same one `widgetsLayout` makes and for the
// same reason — but it matters more here, because the thing this GUI produces
// is a program that rewrites somebody's disk, and a unit test can check the
// plan it built without a compositor, a service or a disk anywhere in sight.
//
// **Why a hub and not a wizard.** `bsdinstall` marches you through a fixed
// sequence: answer this, then that, and if you were wrong three screens back
// you start again. Anaconda's shape — which is the one worth copying — is a
// summary page whose spokes are entered and returned from **in any order**,
// each carrying its own one-line status, with the button that starts the
// install inert until every required one is done. The difference is not
// cosmetic: it is the difference between a program that interrogates you and
// one you can look over before committing.

import Install

/// One spoke off the hub.
public enum Spoke: Int, CaseIterable, Sendable, Equatable {
    case keyboard, disk, timezone, account

    /// The title on the hub.
    public var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .disk:     return "Installation Disk"
        case .timezone: return "Date & Time"
        case .account:  return "User Account"
        }
    }

    /// Whether the Install button waits for this one.
    ///
    /// Keyboard and time zone have defaults that are *fine*; a disk and someone
    /// to log in as do not. Anaconda draws the same line and it is the right
    /// one: require what cannot be guessed, default what can.
    public var required: Bool {
        switch self {
        case .disk, .account: return true
        case .keyboard, .timezone: return false
        }
    }
}

/// Where the installer is.
public enum InstallerPage: Equatable, Sendable {
    case hub
    case spoke(Spoke)
    /// **Erasing a disk that already has something on it**, named, with its
    /// contents listed. A separate stop from `.confirm` and deliberately so:
    /// that one asks "shall I install", this one asks "shall I destroy what is
    /// already here", and a person who has answered the second still gets the
    /// first.
    case eraseConfirm(disk: String)
    /// The point of no return, with the disk named in the sentence.
    case confirm
    case installing
    case done(ok: Bool, error: String)
}

/// Everything the installer knows. A plain struct the caller owns, like
/// `WidgetState` and `FinderState`.
public struct InstallerModel: Sendable {
    // ---- what the machine offered
    public var inventory: DiskInventory
    /// What the service said when asked for the disks, if it could not answer.
    public var inventoryError: String

    // ---- what the user chose
    public var keymap: String
    /// The disk to install onto.
    ///
    /// **Assigning a different one withdraws any erase confirmation.** A person
    /// who agreed to destroy `nda1` has not agreed to destroy `nda0`, and a
    /// consent that outlives the thing it was about is not consent. This is a
    /// property of the *setter* rather than of the screen, because the screen is
    /// not the only caller and the guarantee must not depend on which one it is.
    public var disk: String {
        didSet { if disk != oldValue { eraseConfirmed = false } }
    }
    /// Permission to destroy what is on `disk`, granted only by the sheet.
    ///
    /// `private(set)` so nothing can quietly set it: the one way to turn this on
    /// is `confirmErase()`, which requires a person to have been shown what
    /// would be lost.
    public private(set) var eraseConfirmed: Bool = false
    public var timezone: String
    public var hostname: String
    public var accountName: String
    public var accountFullName: String
    public var accountPassword: String
    public var accountConfirm: String
    public var accountIsAdministrator: Bool

    // ---- where we are
    public var page: InstallerPage
    /// Which row is highlighted inside the current spoke.
    public var selection: Int
    /// Progress, while installing.
    public var stepIndex: Int
    public var stepTotal: Int
    public var stepWhat: String

    public init(inventory: DiskInventory = DiskInventory(disks: []),
                inventoryError: String = "",
                keymap: String = "", disk: String = "", timezone: String = "",
                hostname: String = "abyss",
                accountName: String = "", accountFullName: String = "",
                accountPassword: String = "", accountConfirm: String = "",
                accountIsAdministrator: Bool = true,
                page: InstallerPage = .hub, selection: Int = 0,
                stepIndex: Int = 0, stepTotal: Int = 0, stepWhat: String = "") {
        self.inventory = inventory
        self.inventoryError = inventoryError
        self.keymap = keymap
        self.disk = disk
        self.timezone = timezone
        self.hostname = hostname
        self.accountName = accountName
        self.accountFullName = accountFullName
        self.accountPassword = accountPassword
        self.accountConfirm = accountConfirm
        self.accountIsAdministrator = accountIsAdministrator
        self.page = page
        self.selection = selection
        self.stepIndex = stepIndex
        self.stepTotal = stepTotal
        self.stepWhat = stepWhat
    }

    // MARK: - What each spoke says on the hub

    /// The one-line status under a spoke's title.
    ///
    /// **Every spoke says something, including the ones that are not done.**
    /// A hub whose incomplete rows are blank tells you there is a problem
    /// without telling you what — which is the failure mode of every summary
    /// screen that has ever annoyed anybody.
    public func status(_ spoke: Spoke) -> String {
        switch spoke {
        case .keyboard:
            // The layout's name, not its file (T.1).
            return keymap.isEmpty ? Keymaps.displayName(forKbdmap: "us.kbd") + " (default)"
                                  : Keymaps.displayName(forKbdmap: keymap)
        case .disk:
            guard !disk.isEmpty else {
                if !inventoryError.isEmpty { return inventoryError }
                return installableDisks.isEmpty
                    ? "No disk on this machine can be installed to"
                    : "Choose a disk to install onto"
            }
            guard let d = inventory.disk(named: disk) else {
                return "\(disk) is no longer there"
            }
            return "\(d.name) — \(gib(d.bytes))"
                + (d.description.isEmpty ? "" : " (\(d.description))")
        case .timezone:
            return timezone.isEmpty ? "UTC (default)" : timezone
        case .account:
            if accountName.isEmpty { return "No account will be created" }
            if !passwordProblem.isEmpty { return passwordProblem }
            return accountIsAdministrator
                ? "\(accountName) — can administer this computer"
                : "\(accountName)"
        }
    }

    /// Whether a spoke has been answered well enough to install.
    public func complete(_ spoke: Spoke) -> Bool {
        switch spoke {
        case .keyboard, .timezone:
            return true                       // defaults are answers
        case .disk:
            return !disk.isEmpty && inventory.disk(named: disk) != nil
        case .account:
            return !accountName.isEmpty && passwordProblem.isEmpty
        }
    }

    /// What is wrong with the password, if anything. Empty when it is fine.
    public var passwordProblem: String {
        if accountName.isEmpty { return "" }
        if accountPassword.isEmpty { return "This account has no password" }
        if accountPassword != accountConfirm { return "The passwords do not match" }
        return ""
    }

    /// Every spoke that still needs answering, in hub order.
    public var outstanding: [Spoke] {
        Spoke.allCases.filter { $0.required && !complete($0) }
    }

    /// Whether the install may be started at all.
    ///
    /// This is the whole point of a hub: one predicate, over the same statuses
    /// the user can see, and the button is dead until it is true.
    public var canInstall: Bool { outstanding.isEmpty }

    /// The sentence on the hub beneath the Install button.
    public var readiness: String {
        if canInstall {
            return "Ready to install onto \(disk). This will erase everything on it."
        }
        let names = outstanding.map { $0.title.lowercased() }
        if names.count == 1 {
            return "Choose \(article(names[0])) \(names[0]) before installing."
        }
        return "Still to do: " + names.joined(separator: ", ") + "."
    }

    /// Disks this machine could actually be installed onto, which is the list
    /// the disk spoke shows. Note what it does NOT do: it does not filter out
    /// the refusable ones. **A disk you cannot use has to appear, with the
    /// reason next to it** — a picker that silently omits your disk is one you
    /// argue with.
    public var installableDisks: [Disk] { inventory.disks }

    /// Why this disk cannot be chosen, or empty if it can.
    public func objection(to d: Disk) -> String {
        // `erase: false` — the row tells the truth about what is on a disk
        // whether or not somebody has already agreed to destroy it.
        let trial = plan(disk: d.name, passwordHash: "$6$x", erase: false)
        let problems = Install.problems(trial, on: inventory)
        // Only the ones that are about *this disk*; a missing account is not
        // the disk's fault and belongs on its own spoke.
        //
        // **This list is a whitelist, and that is a trap worth naming.** A
        // refusal added to `Safety.swift` and not added here is refused by the
        // model and *offered by the picker* — the user chooses a disk, gets to
        // the end, and the install fails on a reason the screen never showed.
        // `diskHoldsExistingSystem` arrived exactly that way (§2.46 again: a GUI
        // cannot be trusted to be right about itself), and the test below now
        // fails if a new case is not listed.
        for p in problems {
            switch p {
            case .diskHoldsRunningRoot, .diskIsMounted, .diskTooSmall, .notAWholeDisk,
                 .diskIsFull:
                return p.message
            case .emptyDisk, .noSuchDisk, .badPoolName, .poolNameInUse, .noSets,
                 .baseSetNotFirst, .sizeNotWholeMiB, .relativePath, .noAdministrator:
                continue
            }
        }
        return ""
    }

    /// Whether anything stops this disk being used **that a person cannot
    /// answer**. The running root, a mounted filesystem, a disk too small: no
    /// sentence makes those installable.
    public func isBlocked(_ d: Disk) -> Bool {
        let trial = plan(disk: d.name, passwordHash: "$6$x", erase: false)
        for p in Install.problems(trial, on: inventory) {
            switch p {
            case .diskHoldsRunningRoot, .diskIsMounted, .diskTooSmall, .notAWholeDisk:
                return true
            case .diskIsFull:
                // **Answerable, and therefore not a blocker.** This is the whole
                // difference the sheet exists to express: "there is no room" is
                // a fact about the disk, and whether to make room is a decision
                // that belongs to the person, not to us.
                continue
            case .emptyDisk, .noSuchDisk, .badPoolName, .poolNameInUse, .noSets,
                 .baseSetNotFirst, .sizeNotWholeMiB, .relativePath, .noAdministrator:
                continue
            }
        }
        return false
    }

    /// Whether choosing this disk means destroying what is on it.
    public func needsErasing(_ d: Disk) -> Bool {
        let trial = plan(disk: d.name, passwordHash: "$6$x", erase: false)
        return Install.problems(trial, on: inventory).contains {
            if case .diskIsFull = $0 { return true }; return false
        }
    }

    public func canChoose(_ d: Disk) -> Bool { !isBlocked(d) }

    // MARK: - The plan

    /// The plan this model describes.
    ///
    /// The hashing is the caller's, passed in — the model stays pure and a test
    /// can build the same plan without linking crypt(3). The plaintext password
    /// lives in this struct and **never** reaches an `InstallPlan`, which is a
    /// value that gets logged and rendered into a golden test.
    /// What the Aqua installer installs: FreeBSD **and this desktop**.
    ///
    /// `InstallPlan`'s own default is base and kernel, which is right for a
    /// module that knows nothing about media. This is the installer, and the
    /// thing it exists to install is the thing it is running on.
    public static let sets = ["base.txz", "kernel.txz", InstallPlan.desktopSet]

    /// The account's supplementary groups. `wheel` and `operator` make it an
    /// administrator. **`audio` is for everyone**: from FreeBSD 16 the sound
    /// devices are `root:audio` 0660, so a desktop user outside the group has no
    /// mixer and no sound at all — the Sound pane, the menu bar's volume and
    /// every application go quiet (HANDOFF §2.95).
    public static func groups(administrator: Bool) -> [String] {
        administrator ? ["wheel", "operator", "audio"] : ["audio"]
    }

    /// - Parameter erase: overrides the granted permission. **The predicates
    ///   that ask "what is wrong with this disk" must pass `false`**, because
    ///   they are asking about the disk and not about what has already been
    ///   permitted — a trial plan that inherits the current consent reports
    ///   every disk as fine the moment one of them is, which is how a yes for
    ///   `nda1` silently became a yes for `nda0`.
    public func plan(disk overrideDisk: String? = nil,
                     passwordHash: String,
                     sets: [String] = InstallerModel.sets,
                     distDirectory: String = "/usr/freebsd-dist",
                     erase: Bool? = nil) -> InstallPlan {
        var accounts: [Account] = []
        if !accountName.isEmpty {
            accounts.append(Account(name: accountName,
                                    fullName: accountFullName,
                                    passwordHash: passwordHash,
                                    groups: InstallerModel.groups(administrator: accountIsAdministrator),
                                    shell: "/bin/sh"))
        }
        return InstallPlan(disk: overrideDisk ?? disk,
                           sets: sets,
                           distDirectory: distDirectory,
                           hostname: hostname,
                           timezone: timezone,
                           keymap: keymap,
                           // The account is the administrator; root gets no
                           // password of its own, exactly as a Mac does.
                           rootPasswordHash: "*",
                           accounts: accounts,
                           // Only ever set by the sheet, and cleared the moment
                           // a different disk is chosen (see `disk`'s setter).
                           // **Consent belongs to `disk`, so a plan built for a
                           // different one carries none of it.** Otherwise
                           // `plan(disk: other)` quietly inherits a yes that was
                           // given about something else — the same leak as
                           // `chooseSelection`'s, one layer down, and the reason
                           // this is enforced here rather than left to callers
                           // to remember.
                           eraseExistingData: erase ?? (eraseConfirmed
                               && (overrideDisk == nil || overrideDisk == disk)))
    }

    // MARK: - Moving around

    /// The rows shown inside the current spoke, whatever kind of spoke it is.
    public var spokeRowCount: Int {
        guard case .spoke(let s) = page else { return 0 }
        switch s {
        case .keyboard: return installerKeymaps.count
        case .timezone: return installerTimezones.count
        case .disk:     return installableDisks.count
        case .account:  return 0        // fields, not rows
        }
    }

    public mutating func enter(_ spoke: Spoke) {
        page = .spoke(spoke)
        // Open on what is already chosen, so returning to a spoke shows you
        // where you left off rather than the top of the list.
        switch spoke {
        case .keyboard: selection = max(0, installerKeymaps.firstIndex(of: keymap) ?? 0)
        case .timezone: selection = max(0, installerTimezones.firstIndex(of: timezone) ?? 0)
        case .disk:     selection = max(0, installableDisks.firstIndex { $0.name == disk } ?? 0)
        case .account:  selection = 0
        }
    }

    /// Commit the highlighted row. Returns whether it took.
    ///
    /// **A choice that does not take does not leave the spoke.** Pressing Choose
    /// on a disk that cannot be used and being returned to the hub with nothing
    /// chosen is the worst of both: it looks like it worked and it did not. Stay
    /// on the list, where the reason is written next to the row.
    @discardableResult
    public mutating func chooseSelection() -> Bool {
        guard case .spoke(let s) = page else { return false }
        switch s {
        case .keyboard:
            guard installerKeymaps.indices.contains(selection) else { return false }
            keymap = installerKeymaps[selection]
        case .timezone:
            guard installerTimezones.indices.contains(selection) else { return false }
            timezone = installerTimezones[selection]
        case .disk:
            guard installableDisks.indices.contains(selection) else { return false }
            let d = installableDisks[selection]
            // A disk nothing can make installable is shown, with its reason, and
            // simply does not take.
            guard !isBlocked(d) else { return false }
            // **A disk that is merely full asks first.** Returning false here
            // was the old behaviour and it was a dead end: the row said why and
            // the button did nothing, so on a machine where every disk is full
            // the installer was unusable with no way forward and nothing to
            // click. Now it opens the sheet, which is the place a person can
            // actually answer.
            // **Consent is scoped to the disk it was given for.** Testing the
            // flag alone let a yes for `nda1` carry silently to `nda0`: the
            // setter withdrew it a line later, so the disk was taken *without*
            // the permission and the install would have been refused at the end
            // with no way back. The flag is only an answer about `disk`.
            if needsErasing(d), !(eraseConfirmed && disk == d.name) {
                page = .eraseConfirm(disk: d.name)
                return false
            }
            disk = d.name
        case .account:
            break
        }
        page = .hub
        return true
    }

    public mutating func back() { page = .hub }

    // MARK: - The erase sheet

    /// The disk the sheet is asking about, if it is open.
    public var eraseSubject: Disk? {
        guard case .eraseConfirm(let name) = page else { return nil }
        return inventory.disk(named: name)
    }

    /// What is about to be destroyed, in a person's words.
    ///
    /// **The sheet's whole job is this sentence.** A confirmation that says only
    /// "are you sure?" teaches people to click through; one that names the disk,
    /// its size and what is actually on it gives them something to recognise —
    /// and on the bring-up machine the difference is between "some disk" and
    /// "the 931 GB one with Windows on it".
    public var eraseWarning: String {
        guard let d = eraseSubject else { return "" }
        let what = d.contents.isEmpty ? "existing partitions" : d.contents.joined(separator: ", ")
        return "\(d.name) contains \(what).\n"
             + "Installing AbyssBSD here erases the whole disk. "
             + "This cannot be undone."
    }

    /// Yes: destroy what is on it, and take it.
    public mutating func confirmErase() {
        guard case .eraseConfirm(let name) = page else { return }
        // Order matters: `disk`'s setter withdraws consent when the disk
        // changes, so the flag has to be set *after* the disk it is about.
        disk = name
        eraseConfirmed = true
        page = .hub
    }

    /// No. Back to the list, with nothing chosen and nothing granted.
    public mutating func cancelErase() {
        guard case .eraseConfirm = page else { return }
        eraseConfirmed = false
        page = .spoke(.disk)
    }
}

/// The keyboard layouts the installer offers, as the `kbdmap` names rc.conf
/// takes. The list is `Install.Keymaps.offered`, which also carries each one's
/// XKB layout, so the desktop types what the console types (HANDOFF §2.70).
public let installerKeymaps = Keymaps.offered.map(\.kbdmap)
/// What each is called on the Keyboard page, in the same order (T.1).
public let installerKeymapNames = Keymaps.offered.map(\.name)

/// Likewise for time zones — the common ones, plus UTC.
public let installerTimezones = [
    "UTC",
    "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
    "Europe/London", "Europe/Paris", "Europe/Berlin",
    "Asia/Tokyo", "Australia/Sydney",
]

/// "a" or "an". Trivial, and the alternative is a sentence that reads as
/// carelessly written on the one screen where care is the whole product.
func article(_ word: String) -> String {
    "aeiou".contains(word.lowercased().first ?? "x") ? "an" : "a"
}

func gib(_ bytes: UInt64) -> String {
    let tenths = (bytes * 10) / (1024 * 1024 * 1024)
    return "\(tenths / 10).\(tenths % 10) GB"
}
