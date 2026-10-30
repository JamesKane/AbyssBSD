//! The step list (Steps.swift): what a plan actually does, one command at a
//! time. `abyss-install` runs it and decides nothing, so everything worth
//! arguing about (partition order, pool properties, whether the root
//! auto-mounts) is argued about here, where a test reads the answer. The
//! list renders, and a golden test over it makes a change to what we run at
//! somebody's disk show up in a diff.

use crate::inventory::{DiskInventory, MachineIdentity};
use crate::plan::{Dataset, InstallPlan, BOOT_ENVIRONMENT_DATASETS, STANDARD_DATASETS};
use crate::safety::{check, PlanRefusal};

/// What one step does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Run a command. `stdin` so a password hash never appears in argv,
    /// which every process on the machine can read out of `ps`.
    Run { argv: Vec<String>, stdin: Option<String> },
    Write { path: String, contents: String, mode: u16 },
    Append { path: String, contents: String },
}

/// One thing to do, and what it means if it fails.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub action: Action,
    /// What it is for, in the present tense: "create the GPT".
    pub what: String,
    /// What it means if it fails: the sentence the installer shows, to a
    /// person watching their disk get rewritten.
    pub on_failure: String,
    /// True from the first step that changes the disk: the GUI confirms in
    /// front of the first of these and nowhere else.
    pub destructive: bool,
    /// Allowed to fail: `gpart destroy` on a disk with no table.
    pub may_fail: bool,
}

impl Step {
    fn new(action: Action, what: &str, on_failure: &str) -> Step {
        Step { action, what: what.to_owned(), on_failure: on_failure.to_owned(), destructive: false, may_fail: false }
    }

    fn run(argv: &[&str], what: &str, on_failure: &str) -> Step {
        Step::new(Action::Run { argv: argv.iter().map(|a| (*a).to_owned()).collect(), stdin: None }, what, on_failure)
    }

    fn run_owned(argv: Vec<String>, what: &str, on_failure: &str) -> Step {
        Step::new(Action::Run { argv, stdin: None }, what, on_failure)
    }

    fn destructive(mut self) -> Step {
        self.destructive = true;
        self
    }

    fn may_fail(mut self) -> Step {
        self.may_fail = true;
        self
    }

    fn stdin(mut self, input: &str) -> Step {
        if let Action::Run { stdin, .. } = &mut self.action {
            *stdin = Some(input.to_owned());
        }
        self
    }

    fn write(path: String, contents: String, what: &str, on_failure: &str) -> Step {
        Step::new(Action::Write { path, contents, mode: 0o644 }, what, on_failure)
    }
}

/// Where the pool cache is parked between `zpool create` and the copy into
/// the new root, which does not exist yet when the pool is created.
pub const POOL_CACHE_PATH: &str = "/tmp/abyss-install-zpool.cache";

fn mib(bytes: u64) -> String {
    format!("{}M", bytes / (1 << 20))
}

/// Compile a plan into the things to do, refusing first, so that **no step
/// exists** for a plan that should not run.
pub fn compile(plan: &InstallPlan, inventory: &DiskInventory) -> Result<Vec<Step>, PlanRefusal> {
    check(plan, inventory)?;
    Ok(steps(plan, inventory))
}

/// The step list for a plan already known to be safe: not public, so the
/// only way to get one from outside is to pass the check.
pub(crate) fn steps(plan: &InstallPlan, inventory: &DiskInventory) -> Vec<Step> {
    let mut s = vec![];
    let disk = plan.disk.as_str();
    let mnt = plan.mountpoint.as_str();
    let pool = plan.pool_name.as_str();
    let prefix = plan.label_prefix();
    // **Address the new partitions by LABEL, not by index**: an install
    // into free space lands at whatever index `gpart` picks next.
    let esp = format!("/dev/gpt/{prefix}esp");
    let pool_dev = format!("/dev/gpt/{prefix}zfs");

    // the partition table: three cases, and only erasing destroys anything
    //   erasing     the person confirmed: replace the table wholesale
    //   no table    a blank disk: create one, destroy nothing
    //   free space  somebody's disk with room: add beside what is there
    let erasing = plan.erase_existing_data;
    let has_table = inventory.disk(disk).is_some_and(|d| d.has_partition_table);
    if erasing {
        s.push(
            Step::run(&["gpart", "destroy", "-F", disk], "clear any existing partition table", &format!("the old partition table on {disk} could not be removed"))
                .destructive()
                .may_fail(),
        );
    }
    if erasing || !has_table {
        s.push(Step::run(&["gpart", "create", "-s", "gpt", disk], "create the GPT", &format!("a GPT could not be written to {disk}")).destructive());
    }
    let label = |l: &str| format!("{prefix}{l}");
    s.push(
        Step::run(&["gpart", "add", "-a", "1m", "-s", &mib(plan.esp_bytes), "-t", "efi", "-l", &label("esp"), disk], "add the EFI system partition", "the EFI partition could not be created")
            .destructive(),
    );
    if plan.swap_bytes > 0 {
        s.push(
            Step::run(&["gpart", "add", "-a", "1m", "-s", &mib(plan.swap_bytes), "-t", "freebsd-swap", "-l", &label("swap"), disk], "add swap", "the swap partition could not be created")
                .destructive(),
        );
    }
    s.push(
        Step::run(&["gpart", "add", "-a", "1m", "-t", "freebsd-zfs", "-l", &label("zfs"), disk], "add the pool partition", "the ZFS partition could not be created")
            .destructive(),
    );

    // the ESP: one sector per cluster, the shape the official images use
    s.push(Step::run(&["newfs_msdos", "-F", "32", "-c", "1", &esp], "format the EFI partition", &format!("FAT32 could not be written to {esp}")).destructive());

    // the pool: `altroot` keeps `mountpoint=/` off the running root
    s.push(
        Step::run(
            &[
                "zpool", "create", "-f", "-o", &format!("altroot={mnt}"), "-o", &format!("cachefile={POOL_CACHE_PATH}"), "-O", "compress=lz4", "-O", "atime=off", "-O",
                "mountpoint=none", pool, &pool_dev,
            ],
            "create the pool",
            &format!("the ZFS pool {pool} could not be created on {pool_dev}"),
        )
        .destructive(),
    );

    let create = |d: &Dataset| {
        let mut argv = vec!["zfs".to_owned(), "create".to_owned()];
        for (k, v) in d.properties {
            argv.push("-o".into());
            argv.push(format!("{k}={v}"));
        }
        argv.push(format!("{pool}/{}", d.name));
        Step::run_owned(argv, &format!("create {pool}/{}", d.name), &format!("the dataset {pool}/{} could not be created", d.name))
    };
    s.extend(BOOT_ENVIRONMENT_DATASETS.iter().map(create));
    // `ROOT/default` is `canmount=noauto`, so the install mounts it by hand;
    // forgetting to would extract into the pool's mountpoint and look fine.
    s.push(Step::run(&["zfs", "mount", &format!("{pool}/ROOT/default")], "mount the new root", &format!("{pool}/ROOT/default could not be mounted at {mnt}")));
    // Only now the rest. And never `zfs mount -a`, which mounts every
    // dataset on the machine, the installer's own pool included.
    s.extend(STANDARD_DATASETS.iter().map(create));
    s.push(Step::run(
        &["zpool", "set", &format!("bootfs={pool}/ROOT/default"), pool],
        "mark the boot environment",
        "the pool's bootfs property could not be set — the machine would not know what to boot",
    ));

    // the system itself
    for set in &plan.sets {
        s.push(Step::run(
            &["tar", "-xpf", &format!("{}/{set}", plan.dist_directory), "-C", mnt],
            &format!("extract {set}"),
            &format!("{set} could not be extracted — the distribution media may be damaged"),
        ));
    }

    // boot: the loader from what we just extracted, matching its kernel
    s.push(Step::run(&["mkdir", "-p", &format!("{mnt}/boot/efi")], "make the ESP mount point", &format!("{mnt}/boot/efi could not be created")));
    s.push(Step::run(&["mount", "-t", "msdosfs", &esp, &format!("{mnt}/boot/efi")], "mount the EFI partition", "the EFI partition could not be mounted"));
    s.push(Step::run(&["mkdir", "-p", &format!("{mnt}/boot/efi/EFI/BOOT")], "make EFI/BOOT", "EFI/BOOT could not be created on the EFI partition"));
    s.push(Step::run(
        &["cp", &format!("{mnt}/boot/loader.efi"), &format!("{mnt}/boot/efi/EFI/BOOT/BOOTX64.efi")],
        "install the boot loader",
        "the boot loader could not be copied to the EFI partition",
    ));
    s.push(Step::run(&["mkdir", "-p", &format!("{mnt}/boot/zfs")], "make /boot/zfs", &format!("{mnt}/boot/zfs could not be created")));
    // `zpool create -o cachefile=X` records the property and does not write
    // X, so ask for it rather than copying a file and hoping.
    s.push(Step::run(&["zpool", "set", &format!("cachefile={POOL_CACHE_PATH}"), pool], "write the pool cache", "the pool cache could not be written"));
    s.push(Step::run(
        &["cp", POOL_CACHE_PATH, &format!("{mnt}/boot/zfs/zpool.cache")],
        "install the pool cache",
        "the pool cache could not be copied — the machine would import its pool the slow way",
    ));

    // configuration
    s.push(Step::write(
        format!("{mnt}/boot/loader.conf"),
        loader_conf(plan, inventory.machine.as_ref()),
        "write loader.conf",
        "loader.conf could not be written — the machine would not find its root filesystem",
    ));
    s.push(Step::write(format!("{mnt}/etc/rc.conf"), rc_conf(plan), "write rc.conf", "rc.conf could not be written"));
    s.push(Step::write(format!("{mnt}/etc/fstab"), fstab(plan), "write fstab", "fstab could not be written"));
    if !plan.timezone.is_empty() {
        let tz = &plan.timezone;
        s.push(Step::run(
            &["cp", &format!("{mnt}/usr/share/zoneinfo/{tz}"), &format!("{mnt}/etc/localtime")],
            &format!("set the time zone to {tz}"),
            &format!("the time zone {tz} is not in the installed zoneinfo"),
        ));
    }

    // who can log in
    if !plan.root_password_hash.is_empty() && plan.root_password_hash != "*" {
        s.push(Step::run(&["pw", "-R", mnt, "usermod", "root", "-H", "0"], "set the root password", "the root password could not be set").stdin(&plan.root_password_hash));
    }
    // The login window's own account (PHASE16 P16.5): no password, no
    // shell, no home, and in `video`, since its session runs a compositor.
    if plan.installs_desktop() {
        s.push(Step::run(
            &["pw", "-R", mnt, "useradd", "-n", "_loginwindow", "-u", "1099", "-c", "Login Window", "-d", "/nonexistent", "-s", "/usr/sbin/nologin", "-w", "no", "-G", "video"],
            "create the login window's account",
            "the login window's account could not be created",
        ));
    }
    for a in &plan.accounts {
        let mut argv: Vec<String> = ["pw", "-R", mnt, "useradd", "-n", &a.name, "-m", "-s", &a.shell, "-H", "0"].map(str::to_owned).into();
        if !a.full_name.is_empty() {
            argv.extend(["-c".into(), a.full_name.clone()]);
        }
        if !a.groups.is_empty() {
            argv.extend(["-G".into(), a.groups.join(",")]);
        }
        s.push(
            Step::run_owned(argv, &format!("create the account {}", a.name), &format!("the account {} could not be created", a.name)).stdin(&a.password_hash),
        );
    }

    // leave nothing mounted: part of the list, so an interrupted install
    // resumes by running it again. `zpool export` unmounts exactly the
    // pool's datasets, so no `zfs umount -a` either.
    s.push(Step::run(&["umount", &format!("{mnt}/boot/efi")], "unmount the EFI partition", "the EFI partition could not be unmounted").may_fail());
    s.push(Step::run(
        &["zpool", "export", pool],
        "export the pool",
        &format!("the pool {pool} could not be exported — the installed system may not import it on first boot"),
    ));
    s
}

// MARK: the files we write

pub fn loader_conf(plan: &InstallPlan, machine: Option<&MachineIdentity>) -> String {
    let mut out = String::from("# Written by the AbyssBSD installer.\nzfs_load=\"YES\"\n");
    out += &format!("vfs.root.mountfrom=\"zfs:{}/ROOT/default\"\n", plan.pool_name);
    // A serial console is the only way to see a boot that fails before the
    // desktop, which is the boot that matters when an install went wrong.
    out += "boot_serial=\"YES\"\ncomconsole_speed=\"115200\"\nconsole=\"comconsole,vidconsole\"\n";
    // **The GPT labels fstab names have to survive to the installed
    // machine**: GEOM's disk-ident class can consume the disk first, and no
    // `/dev/gpt/*` is ever created (measured: no swap without this line).
    out += "kern.geom.label.disk_ident.enable=\"0\"\n";
    // **A Mac Pro accommodation, and only Mac Pros get it** (P12.2). A
    // machine that does not identify itself does not: a scrolling console
    // is visible and recoverable, a workaround everywhere is silent.
    if fathom::needs_pcie_hotplug_disabled(machine.map(|m| m.maker.as_str()), machine.map(|m| m.product.as_str())) {
        out += "hw.pci.enable_pcie_hp=\"0\"\n";
    }
    out
}

pub fn rc_conf(plan: &InstallPlan) -> String {
    let mut out = String::from("# Written by the AbyssBSD installer.\nzfs_enable=\"YES\"\n");
    out += &format!("hostname=\"{}\"\nifconfig_DEFAULT=\"DHCP\"\n", plan.hostname);
    if !plan.keymap.is_empty() {
        out += &format!("keymap=\"{}\"\n", plan.keymap);
    }
    // **A machine that installed the desktop should start it**, at the
    // login window (PHASE16 P16.5); automatic login is a choice.
    if plan.installs_desktop() {
        let admin = plan.accounts.iter().find(|a| a.is_administrator());
        match admin.or(plan.accounts.first()) {
            Some(owner) if plan.auto_login => {
                out += &format!("abyss_desktop_enable=\"YES\"\nabyss_desktop_user=\"{}\"\n", owner.name);
            }
            // Said, not left unset: rc warns about an rc.d script whose
            // enable variable is missing.
            _ => out += "abyss_desktop_enable=\"NO\"\nabyss_loginwindow_greeter=\"YES\"\n",
        }
        // System Preferences' privileged half (P14.3), **only for an
        // administrator**: it would admit nobody else.
        if let Some(admin) = admin {
            out += &format!("abyss_settings_enable=\"YES\"\nabyss_settings_admin=\"{}\"\n", admin.name);
        }
        // The authenticator (P16.1), for every account; jails (P18.2).
        out += "abyss_loginwindow_enable=\"YES\"\nabyss_jaild_enable=\"YES\"\n";
    }
    out
}

pub fn fstab(plan: &InstallPlan) -> String {
    let mut out = String::from("# Device\tMountpoint\tFStype\tOptions\tDump\tPass#\n");
    if plan.swap_bytes > 0 {
        out += &format!("/dev/gpt/{}swap\tnone\tswap\tsw\t0\t0\n", plan.label_prefix());
    }
    // Not the root: ZFS mounts it, and an entry here mounts it twice.
    out
}

// MARK: rendering

/// One argument, unambiguously: `-c J Kane` reads as three when it is two.
fn shell_quoted(arg: &str) -> String {
    if arg.is_empty() {
        return "''".into();
    }
    if arg.chars().all(|c| c.is_alphanumeric() || "-_./=:,+@".contains(c)) {
        return arg.into();
    }
    // A single quote inside single quotes closes, escapes and reopens.
    format!("'{}'", arg.replace('\'', "'\\''"))
}

/// The step list as text, stable enough to keep in a golden test.
pub fn render(steps: &[Step]) -> String {
    let mut out = String::new();
    let lines = |out: &mut String, contents: &str| {
        for line in contents.split('\n').filter(|l| !l.is_empty()) {
            *out += &format!("     | {line}\n");
        }
    };
    for (i, step) in steps.iter().enumerate() {
        let destructive = if step.destructive { " [destructive]" } else { "" };
        let may_fail = if step.may_fail { " [may fail]" } else { "" };
        out += &format!("{}. {}{destructive}{may_fail}\n", i + 1, step.what);
        match &step.action {
            Action::Run { argv, stdin } => {
                out += &format!("   $ {}\n", argv.iter().map(|a| shell_quoted(a)).collect::<Vec<_>>().join(" "));
                if stdin.is_some() {
                    out += "   < (on stdin, kept out of argv)\n";
                }
            }
            Action::Write { path, contents, mode } => {
                out += &format!("   > {path} ({mode:o})\n");
                lines(&mut out, contents);
            }
            Action::Append { path, contents } => {
                out += &format!("   >> {path}\n");
                lines(&mut out, contents);
            }
        }
    }
    out
}
