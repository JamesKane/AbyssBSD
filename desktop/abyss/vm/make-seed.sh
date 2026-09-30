#!/bin/sh
# Build a cloud-init NoCloud seed as an ISO9660 image labeled "CIDATA" with
# Rock Ridge + Joliet long names. FreeBSD's nuageinit mounts it via cd9660 and
# reads the real "meta-data"/"user-data" names (msdosfs/FAT long-name interop is
# unreliable here, so we avoid it). Uses pycdlib -> no root, no mkisofs.
set -eu
. "$(dirname "$0")/config.sh"

mkdir -p "$ABYSS_VM_HOME"
# The keypair is per-VM-home and disposable: generate it on first run so the
# whole flow is reproducible from a clean checkout (the sibling's was made by
# hand, which is why its absence used to be a hard error here).
if [ ! -f "$ABYSS_SSH_KEY.pub" ]; then
  echo "[seed] generating ssh key $ABYSS_SSH_KEY"
  rm -f "$ABYSS_SSH_KEY"
  ssh-keygen -t ed25519 -N '' -C "abyss-swift-build" -f "$ABYSS_SSH_KEY" >/dev/null
fi
pubkey=$(cat "$ABYSS_SSH_KEY.pub")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/meta-data" <<EOF
instance-id: abyss-build$_suffix-001
local-hostname: $ABYSS_HOSTNAME
EOF

cat > "$work/user-data" <<EOF
#cloud-config
hostname: $ABYSS_HOSTNAME
ssh_pwauth: false
users:
  - name: $ABYSS_SSH_USER
    # audio: from FreeBSD 16 the sound devices are root:audio 0660, and the
    # harness drives snd_dummy's mixer as this user (HANDOFF §2.95).
    groups: [wheel, audio]
    shell: /bin/sh
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $pubkey
# Hold the base system at the image's own snapshot. A pkgbase image (16) comes
# with firstboot_pkg_upgrade on and the FreeBSD-base repository enabled, so its
# first boot would upgrade world and kernel to whatever CURRENT built last night
# — past the snapshot config.sh pins, and past the base.txz/kernel.txz the medium
# is built from. nuageinit writes these before NETWORKING; the upgrade needs it.
# Moving the base is a deliberate step: a new pin in config.sh, and a new guest.
write_files:
  - path: /etc/rc.conf.d/firstboot_pkg_upgrade
    content: |
      firstboot_pkg_upgrade_enable="NO"
  - path: /usr/local/etc/pkg/repos/FreeBSD.conf
    content: |
      FreeBSD-base: { enabled: no }
runcmd:
  - ASSUME_ALWAYS_YES=yes pkg bootstrap -f || true
  - pkg update -f || true
  # Base tooling. sudo/rsync are not in FreeBSD base.
  - pkg install -y sudo rsync git gmake pkgconf || true
  # Swift's own runtime/build dependencies (the same set Linux needs):
  # ICU, libxml2, curl, libedit. No Rust: the engine is a Swift *rewrite*,
  # not a reuse of the sibling's crates (PLAN.md, corrected 2026-07-27).
  - pkg install -y icu libxml2 curl libedit || true
  # DE C-lib substrate the Swift Surface/Aqua targets FFI into:
  #   wayland (client+server), xkbcommon, cairo, freetype/harfbuzz + a font,
  #   png/jpeg. wayland-protocols supplies xdg-shell.xml for the scanner.
  - pkg install -y wayland wayland-protocols libxkbcommon cairo || true
  - pkg install -y freetype2 harfbuzz dejavu png jpeg-turbo || true
  # wlroots + seatd + a stock compositor: the Swift shell runs as a *client*
  # against sway here exactly as it does on Linux (a Swift compositor is
  # Phase 6). grim captures the headless output for the live tests.
  - pkg install -y wlroots019 seatd sway grim || true
  # wlroots 0.20 beside 0.19: undertow moves to it on both platforms at once
  # (Package.swift's pin), and the guest should already have it when it does.
  - pkg install -y wlroots020 || true
  # What the harness grew into after the seed was written, installed by hand
  # on the 15.0 box and recorded here so a rebuilt guest is the same guest:
  # nested bhyve's firmware for the --full installs (P5), gdb for the wtap
  # vmcores (P14.5), a Qt and a GTK application whose menus our bar has to show
  # (kcalc, qt6-wayland, zenity — P10.7, U.5), and an independent
  # wlr-output-management client (P14.7).
  - pkg install -y edk2-bhyve gdb kcalc qt6-wayland zenity wlr-randr || true
  # Swift toolchain. FreeBSD is not an *official* swift.org target, but ports
  # carries one: the package is \`swift6\` (\`swift\` alone matches nothing, which
  # is why this line used to report a false negative). Confirmed 2026-07-28:
  # swift6-6.3.2, newer than the 6.3.1 we develop against on Linux. Option (a)
  # of docs/SWIFT-ON-FREEBSD.md; proving it builds *this repo* is P3.2.
  - pkg install -y swift6 || echo "swift6 pkg install failed — see docs/SWIFT-ON-FREEBSD.md" >> /home/$ABYSS_SSH_USER/.swift-todo
  # The port installs to /usr/local/swift6/bin (deliberately off PATH, so 5.10
  # and 6.x can coexist). Put it on PATH for interactive logins; scripts use
  # \$ABYSS_GUEST_SWIFT_BIN from config.sh instead, since a non-interactive
  # \`ssh host 'cmd'\` reads neither .profile nor /etc/profile.
  - sh -c 'echo "PATH=/usr/local/swift6/bin:\\\$PATH; export PATH" >> /home/$ABYSS_SSH_USER/.profile'
  # Every install above is best-effort (|| true) so one missing port can't wedge
  # first boot — which means a silent miss would otherwise look like success.
  # Record what actually landed; abyss/vm/check.sh asserts on this file.
  - sh -c 'for p in sudo rsync git gmake pkgconf icu libxml2 curl libedit wayland wayland-protocols libxkbcommon cairo freetype2 harfbuzz dejavu png jpeg-turbo wlroots019 wlroots020 seatd sway grim edk2-bhyve gdb kcalc qt6-wayland zenity wlr-randr swift6; do pkg info -e "\$p" || echo "\$p" >> /home/$ABYSS_SSH_USER/.pkg-missing; done'
  - touch /home/$ABYSS_SSH_USER/.cloud-init-done
  - chown $ABYSS_SSH_USER /home/$ABYSS_SSH_USER/.cloud-init-done
EOF

echo "[seed] building Rock Ridge ISO at $ABYSS_SEED"
ABYSS_SEED="$ABYSS_SEED" META="$work/meta-data" USER_DATA="$work/user-data" \
python3 - <<'PY'
import os, pycdlib
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, rock_ridge='1.09', joliet=3, vol_ident='CIDATA')
for src, iso_path, rr in (
    (os.environ['META'],      '/METADATA.;1', 'meta-data'),
    (os.environ['USER_DATA'], '/USERDATA.;1', 'user-data'),
):
    iso.add_file(src, iso_path, rr_name=rr, joliet_path='/' + rr)
iso.write(os.environ['ABYSS_SEED'])
iso.close()
print('[seed] wrote', os.environ['ABYSS_SEED'])
PY
echo "[seed] done"
