#!/bin/sh
# Assemble the AbyssBSD monorepo from this repo and the forks on GitHub.
#
# What it builds, in $ABYSS_MONO (default: ../AbyssBSD beside this repo):
#
#   desktop/        this repo, with its history
#   kmod/drm-msm/   drm-msm-kmod, with its history
#   ports/          a poudriere overlay (`poudriere bulk -O`): every port the
#                   freebsd-ports fork changes, whole, as its branch has it
#   src/            submodule: freebsd-src
#   kmod/drm/       submodule: drm-kmod
#   firmware/       submodule: drm-kmod-firmware
#
# The submodules are gitlinks pinned to their branch's tip **on GitHub**, read
# with ls-remote — nothing is cloned for them, so a commit that is only in a
# local checkout is not in the result. The sibling checkouts are looked at only
# to warn about exactly that.
#
# The desktop comes from a local checkout (ABYSS_DESKTOP, default this repo),
# because it has no remote. Only its committed history is taken.
#
# Nothing here pushes. The result is a local repo; pushing it is up to you.
#
# Case: the firmware fork holds radeon files that differ only by case, which a
# case-insensitive filesystem (macOS's default APFS) folds into one. Assembling
# never checks the submodules out, so it is safe anywhere; checking them out is
# not, and the script says so when it finds it is on such a filesystem.
#
# Needs: git, git-filter-repo, tar.
#
# Usage: assemble-monorepo.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)

: "${ABYSS_DESKTOP:=$(cd "$here/../.." && pwd)}"
: "${ABYSS_DESKTOP_BRANCH:=master}"
: "${ABYSS_MONO:=$(cd "$ABYSS_DESKTOP/.." && pwd)/AbyssBSD}"
# Where the other checkouts live, for the unpushed-commit warning only.
: "${ABYSS_SIBLINGS:=$(cd "$ABYSS_DESKTOP/.." && pwd)}"

: "${ABYSS_GH:=https://github.com/JamesKane}"
: "${ABYSS_PORTS_UPSTREAM:=https://github.com/freebsd/freebsd-ports.git}"

: "${ABYSS_SRC_BRANCH:=orangepi-6-plus}"
: "${ABYSS_DRM_BRANCH:=sysfbdrm}"
: "${ABYSS_FW_BRANCH:=qcom}"
: "${ABYSS_MSM_BRANCH:=main}"
: "${ABYSS_PORTS_BRANCH:=freedreno}"

say() { echo "[mono] $*"; }
warn() { echo "[mono] warning: $*" >&2; }
die() { echo "[mono] $*" >&2; exit 1; }

git filter-repo --version >/dev/null 2>&1 \
  || die "git-filter-repo is not installed (pkg/apt/brew install git-filter-repo)"
git -C "$ABYSS_DESKTOP" rev-parse --verify -q "$ABYSS_DESKTOP_BRANCH" >/dev/null \
  || die "no branch $ABYSS_DESKTOP_BRANCH in $ABYSS_DESKTOP"
[ -e "$ABYSS_MONO" ] && die "$ABYSS_MONO exists; move it aside or set ABYSS_MONO"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/abyss-mono.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$ABYSS_MONO"
touch "$ABYSS_MONO/.case-probe"
if [ -e "$ABYSS_MONO/.CASE-PROBE" ]; then
  warn "$ABYSS_MONO is on a case-insensitive filesystem: assembling is fine,"
  warn "but do not check out firmware/ (or src/) here"
fi
rm -f "$ABYSS_MONO/.case-probe"

# Commits on a branch in a sibling checkout that no remote-tracking ref has.
# As fresh as that checkout's last fetch — a warning, not a check.
unpushed() { # dir branch
  d="$ABYSS_SIBLINGS/$1"
  [ -e "$d/.git" ] || return 0  # a worktree's .git is a file
  git -C "$d" rev-parse --verify -q "$2" >/dev/null || return 0
  n=$(git -C "$d" rev-list --count "$2" --not --remotes --)
  [ "$n" -eq 0 ] || warn "$1: $n commit(s) on $2 are not pushed and will not be in the result"
}
unpushed freebsd-src "$ABYSS_SRC_BRANCH"
unpushed drm-kmod "$ABYSS_DRM_BRANCH"
unpushed drm-kmod-firmware "$ABYSS_FW_BRANCH"
unpushed drm-msm-kmod "$ABYSS_MSM_BRANCH"
unpushed freebsd-ports-sparse "$ABYSS_PORTS_BRANCH"
[ -z "$(git -C "$ABYSS_DESKTOP" status --porcelain)" ] \
  || warn "the desktop checkout has uncommitted changes; they are not taken"

tip() { # url branch
  t=$(git ls-remote "$1" "refs/heads/$2" | cut -f1)
  [ -n "$t" ] || die "no branch $2 at $1"
  echo "$t"
}

git init -q -b main "$ABYSS_MONO"
cd "$ABYSS_MONO"

cat > README.md <<'EOF'
# AbyssBSD

A FreeBSD distribution: a fork of FreeBSD with new hardware support, and a
desktop written in Swift.

| Path | What |
|------|------|
| `desktop/` | the Swift desktop, its session, and its build/test VM harness |
| `kmod/drm-msm/` | the DRM driver for Qualcomm Adreno GPUs |
| `ports/` | a poudriere overlay: `poudriere bulk -O abyss ...` |
| `src/` | submodule: the FreeBSD fork |
| `kmod/drm/` | submodule: the drm-kmod fork |
| `firmware/` | submodule: the drm-kmod-firmware fork |

`git submodule update --init src kmod/drm` fetches the source trees. Leave
`firmware/` out on a case-insensitive filesystem (macOS's default): it holds
files whose names differ only by case.
EOF
git add README.md
git commit -q -m "AbyssBSD: one repository for the distribution"

# A repo's branch, moved under a directory and merged in with its history.
import() { # url branch dir what
  say "importing $4 into $3/"
  c="$tmp/import"
  rm -rf "$c"
  git clone -q --no-local --single-branch --no-tags --branch "$2" "$1" "$c"
  git -C "$c" filter-repo --quiet --force --to-subdirectory-filter "$3" >/dev/null 2>&1 \
    || die "filter-repo failed on $4"
  git fetch -q "$c" "$2"
  git merge -q --allow-unrelated-histories --no-edit \
    -m "Import $4 into $3/, with its history" FETCH_HEAD
}
import "$ABYSS_DESKTOP" "$ABYSS_DESKTOP_BRANCH" desktop "the desktop"
import "$ABYSS_GH/drm-msm-kmod.git" "$ABYSS_MSM_BRANCH" kmod/drm-msm drm-msm-kmod

# The ports overlay. Only blobless history is fetched: the merge base needs
# commits, and archive fetches just the blobs of the ports it copies.
say "reading the ports fork's changes"
p="$tmp/ports"
git clone -q --filter=blob:none --no-checkout --single-branch --no-tags \
  --branch "$ABYSS_PORTS_BRANCH" "$ABYSS_GH/freebsd-ports.git" "$p"
git -C "$p" fetch -q --filter=blob:none --no-tags "$ABYSS_PORTS_UPSTREAM" main
ptip=$(git -C "$p" rev-parse "$ABYSS_PORTS_BRANCH")
pbase=$(git -C "$p" merge-base FETCH_HEAD "$ptip")
changed=$(git -C "$p" diff --name-only "$pbase" "$ptip")
# An overlay carries ports, so a change outside one (Mk/, Mk/Uses/, Tools/, a
# category's Makefile) cannot be carried. Category Makefiles only list
# SUBDIRs, which poudriere does not read; anything else would be a change the
# overlay drops. A port is a category/name directory with a Makefile, at the
# fork's tip or, for one it removes, at the base: Mk/Uses/ is two deep too.
# rev-parse reads trees only, so no blob is fetched to decide.
isport() { # dir
  git -C "$p" rev-parse -q --verify "$ptip:$1/Makefile" >/dev/null \
    || git -C "$p" rev-parse -q --verify "$pbase:$1/Makefile" >/dev/null
}
classified=$(printf '%s\n' "$changed" | while IFS= read -r f; do
  case $f in
    '') ;;
    */*/*)
      d=${f%"/${f#*/*/}"}
      if isport "$d"; then echo "port $d"; else echo "infra $f"; fi ;;
    */Makefile) ;;
    *) echo "infra $f" ;;
  esac
done)
infra=$(echo "$classified" | sed -n 's/^infra //p')
[ -z "$infra" ] || die "the ports fork changes more than ports, which an overlay cannot carry:
$infra"
ports=$(echo "$classified" | sed -n 's/^port //p' | sort -u)
mkdir -p ports
for port in $ports; do
  if git -C "$p" cat-file -e "$ptip:$port" 2>/dev/null; then
    git -C "$p" archive "$ptip" "$port" | tar -x -C ports
  else
    warn "the ports fork removes $port; an overlay cannot remove a port"
  fi
done
# A port that reads a file out of another port's directory reads it from the
# overlay, where that port is not unless it is carried too: drm-msm-kmod
# includes ../drm-latest-kmod/Makefile.version. So the ports those references
# name are carried as the fork has them, until no reference is left unmet.
# Each spelling is resolved to a category/port origin: ${.CURDIR}/../name and
# ${.CURDIR:H}/name against the referring port's category,
# ${.CURDIR}/../../cat/name and ${.CURDIR:H:H}/cat/name as they are.
# Every reference on a line counts, not just the last.
refs() {
  for mk in ports/*/*/Makefile*; do
    [ -f "$mk" ] || continue
    cat=$(echo "$mk" | cut -d/ -f2)
    c='[A-Za-z0-9_+-][A-Za-z0-9._+-]*'
    grep -oE "\\\$\\{\\.CURDIR(:H|:H:H)?\\}(/\\.\\.){0,2}(/$c){1,2}" "$mk" |
    while IFS= read -r r; do
      case $r in
        '${.CURDIR}/../../'*/*) r=${r#'${.CURDIR}/../../'}; echo "$r" ;;
        '${.CURDIR:H:H}/'*/*) r=${r#'${.CURDIR:H:H}/'}; echo "$r" ;;
        '${.CURDIR}/../../'*|'${.CURDIR:H:H}/'*) ;;  # a category, not a port
        '${.CURDIR}/../'*) r=${r#'${.CURDIR}/../'}; echo "$cat/${r%%/*}" ;;
        '${.CURDIR:H}/'*) r=${r#'${.CURDIR:H}/'}; echo "$cat/${r%%/*}" ;;
      esac
    done
  done | sort -u
}
carried=""
while :; do
  new=""
  for port in $(refs); do
    [ -d "ports/$port" ] || new="$new $port"
  done
  [ -n "$new" ] || break
  for port in $new; do
    git -C "$p" cat-file -e "$ptip:$port" 2>/dev/null \
      || die "an overlay port refers to $port, which the ports tree does not have"
    say "carrying $port, which an overlay port reads from"
    git -C "$p" archive "$ptip" "$port" | tar -x -C ports
    carried="$carried$port
"
  done
done
cat > ports/README.md <<EOF
# ports

A poudriere overlay: each directory replaces the port of the same origin in
the ports tree it is built against.

    poudriere ports -c -p abyss -m null -M \$PWD/ports
    poudriere bulk -j <jail> -p default -O abyss <origins>

Taken from $ABYSS_GH/freebsd-ports, branch $ABYSS_PORTS_BRANCH at
$ptip, over freebsd-ports $pbase.
EOF
git add ports
git commit -q -F - <<EOF
ports: An overlay of the ports the freebsd-ports fork changes

Each changed port is copied whole from $ABYSS_PORTS_BRANCH at ${ptip%"${ptip#??????????}"}:

$(echo "$ports" | sed 's/^/  /')

from these commits over freebsd-ports ${pbase%"${pbase#??????????}"}:

$(git -C "$p" log --reverse --format='  %h %s' "$pbase..$ptip")
${carried:+
and, unchanged, the ports those read files from, which an overlay must carry
for them to find:

$(printf '%s' "$carried" | sed 's/^/  /')
}
EOF

# Submodules, pinned without cloning: .gitmodules plus a gitlink in the index.
submodule() { # path repo branch
  url="$ABYSS_GH/$2.git"
  sha=$(tip "$url" "$3")
  say "pinning $1 to $2 $3 at $sha"
  git config -f .gitmodules "submodule.$1.path" "$1"
  git config -f .gitmodules "submodule.$1.url" "$url"
  git config -f .gitmodules "submodule.$1.branch" "$3"
  git update-index --add --cacheinfo "160000,$sha,$1"
  mkdir -p "$1"  # as an uninitialised submodule leaves it, so status is clean
  pins="${pins:-}  $1 = $2 $3 at $sha
"
}
submodule src freebsd-src "$ABYSS_SRC_BRANCH"
submodule kmod/drm drm-kmod "$ABYSS_DRM_BRANCH"
submodule firmware drm-kmod-firmware "$ABYSS_FW_BRANCH"
git add .gitmodules
git commit -q -F - <<EOF
Add the FreeBSD, drm-kmod and firmware forks as submodules

$pins
EOF

say "done: $ABYSS_MONO"
git log --oneline --first-parent
echo
echo "To publish it (the GitHub repo must still be empty):"
echo "  git -C $ABYSS_MONO remote add origin $ABYSS_GH/AbyssBSD.git"
echo "  git -C $ABYSS_MONO push -u origin main"
