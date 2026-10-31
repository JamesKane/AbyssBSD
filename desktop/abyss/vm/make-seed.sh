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
instance-id: abyss-build$_role$_suffix-001
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
EOF

# What the role installs, appended to the same runcmd.
if [ "$ABYSS_VM_ROLE" = builder ]; then
  # The release pipeline's (PHASE17 P17.0): poudriere builds the overlay;
  # git for the ports tree poudriere is given. World and kernel need nothing
  # beyond base. Every install best-effort, then recorded, as the guest's.
  cat >> "$work/user-data" <<EOF
  - pkg install -y sudo rsync git gmake pkgconf poudriere || true
  - sh -c 'for p in sudo rsync git gmake pkgconf poudriere; do pkg info -e "\$p" || echo "\$p" >> /home/$ABYSS_SSH_USER/.pkg-missing; done'
  - touch /home/$ABYSS_SSH_USER/.cloud-init-done
  - chown $ABYSS_SSH_USER /home/$ABYSS_SSH_USER/.cloud-init-done
EOF
else
  cat >> "$work/user-data" <<EOF
  # Base tooling. sudo/rsync are not in FreeBSD base.
  - pkg install -y sudo rsync git gmake pkgconf || true
  # The C libraries the desktop links (abyss-sys/build.rs):
  #   wayland (client+server), xkbcommon, cairo, freetype/harfbuzz + a font,
  #   png/jpeg. wayland-protocols supplies xdg-shell.xml for the scanner.
  - pkg install -y wayland wayland-protocols libxkbcommon cairo || true
  - pkg install -y freetype2 harfbuzz dejavu png jpeg-turbo || true
  # wlroots + seatd + a stock compositor: the shell runs as a *client*
  # against sway here exactly as it does on Linux, beside undertow. grim
  # captures the headless output for the live tests.
  - pkg install -y wlroots019 seatd sway grim || true
  # wlroots 0.20 beside 0.19 (sway's): undertow's pin, on both platforms.
  - pkg install -y wlroots020 || true
  # What the harness grew into after the seed was written, installed by hand
  # on the 15.0 box and recorded here so a rebuilt guest is the same guest:
  # nested bhyve's firmware for the --full installs (P5), gdb for the wtap
  # vmcores (P14.5), GTK applications for the bar's menus and a real port's
  # bundle (zenity, galculator — U.5, P15.1; one toolkit, GTK: no Qt), the
  # browser the medium carries and its H.264 (firefox-esr, ffmpeg — P15.3), and
  # an independent
  # wlr-output-management client (P14.7).
  - pkg install -y edk2-bhyve gdb zenity galculator firefox-esr ffmpeg wlr-randr || true
  # Rust (docs/RUST.md): the desktop builds and is tested here on every pass.
  - pkg install -y rust || true
  # Every install above is best-effort (|| true) so one missing port can't wedge
  # first boot — which means a silent miss would otherwise look like success.
  # Record what actually landed; abyss/vm/check.sh asserts on this file.
  - sh -c 'for p in sudo rsync git gmake pkgconf wayland wayland-protocols libxkbcommon cairo freetype2 harfbuzz dejavu png jpeg-turbo wlroots019 wlroots020 seatd sway grim edk2-bhyve gdb zenity galculator firefox-esr ffmpeg wlr-randr rust; do pkg info -e "\$p" || echo "\$p" >> /home/$ABYSS_SSH_USER/.pkg-missing; done'
  - touch /home/$ABYSS_SSH_USER/.cloud-init-done
  - chown $ABYSS_SSH_USER /home/$ABYSS_SSH_USER/.cloud-init-done
EOF
fi

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
