#!/bin/sh
# Build a cloud-init NoCloud seed as an ISO9660 image labeled "CIDATA" with
# Rock Ridge + Joliet long names. FreeBSD's nuageinit mounts it via cd9660 and
# reads the real "meta-data"/"user-data" names (msdosfs/FAT long-name interop is
# unreliable here, so we avoid it). Uses pycdlib -> no root, no mkisofs.
set -eu
. "$(dirname "$0")/config.sh"

[ -f "$ABYSS_SSH_KEY.pub" ] || { echo "missing pubkey $ABYSS_SSH_KEY.pub" >&2; exit 1; }
pubkey=$(cat "$ABYSS_SSH_KEY.pub")
mkdir -p "$ABYSS_VM_HOME"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/meta-data" <<EOF
instance-id: abyss-build-001
local-hostname: $ABYSS_HOSTNAME
EOF

cat > "$work/user-data" <<EOF
#cloud-config
hostname: $ABYSS_HOSTNAME
ssh_pwauth: false
users:
  - name: $ABYSS_SSH_USER
    groups: [wheel]
    shell: /bin/sh
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $pubkey
runcmd:
  - ASSUME_ALWAYS_YES=yes pkg bootstrap -f || true
  - pkg update -f || true
  # Base tooling. sudo/rsync are not in FreeBSD base.
  - pkg install -y sudo rsync git gmake pkgconf || true
  # Rust (stable) — for the BORROWED engine (tide compositor, current/pool, …)
  # we reuse from the sibling in Phase 3. The Swift DE itself needs no Rust.
  - pkg install -y rust || true
  # DE C-lib substrate the Swift Surface/Aqua targets FFI into:
  #   wayland (client+server), xkbcommon, cairo, freetype/harfbuzz + a font,
  #   png/jpeg. wayland-protocols supplies xdg-shell.xml for the scanner.
  - pkg install -y wayland wayland-protocols libxkbcommon cairo || true
  - pkg install -y freetype2 harfbuzz dejavu png jpeg-turbo || true
  # wlroots + seatd: needed in Phase 3 to run the Rust tide compositor, and a
  # stock compositor (sway) lets us run the Swift clients in the VM meanwhile.
  - pkg install -y wlroots019 seatd sway || true
  # Swift toolchain: NOT an official FreeBSD pkg as of writing — this is the
  # Phase-0 spike. Try the port if present; otherwise see
  # docs/SWIFT-ON-FREEBSD.md (cross-SDK from Linux, or build-from-source).
  - pkg install -y swift || echo "swift pkg unavailable — see docs/SWIFT-ON-FREEBSD.md" >> /home/$ABYSS_SSH_USER/.swift-todo
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
