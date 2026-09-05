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
    public var disk: String
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
            return keymap.isEmpty ? "US (default)" : keymap
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
        let trial = plan(disk: d.name, passwordHash: "$6$x")   // same sets as the real one
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

    public func canChoose(_ d: Disk) -> Bool { objection(to: d).isEmpty }

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

    public func plan(disk overrideDisk: String? = nil,
                     passwordHash: String,
                     sets: [String] = InstallerModel.sets,
                     distDirectory: String = "/usr/freebsd-dist") -> InstallPlan {
        var accounts: [Account] = []
        if !accountName.isEmpty {
            accounts.append(Account(name: accountName,
                                    fullName: accountFullName,
                                    passwordHash: passwordHash,
                                    groups: accountIsAdministrator ? ["wheel", "operator"] : [],
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
                           accounts: accounts)
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
            // A disk with an objection is shown, with its reason, and simply
            // does not take.
            guard canChoose(d) else { return false }
            disk = d.name
        case .account:
            break
        }
        page = .hub
        return true
    }

    public mutating func back() { page = .hub }
}

/// The keyboard layouts the installer offers. A short, honest list rather than
/// every layout xkeyboard-config knows: this is the live installer's first
/// screen, not System Preferences.
public let installerKeymaps = [
    "us.kbd", "uk.kbd", "de.kbd", "fr.kbd", "es.kbd", "it.kbd",
    "dvorak.kbd", "colemak.kbd",
]

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
