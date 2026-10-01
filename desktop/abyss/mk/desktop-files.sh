# shellcheck shell=sh
# What the desktop puts on a machine, in one place. Sourced by live-image.sh,
# which builds media and the `abyss.tzst` set from it, and by metal.sh's `push`,
# which updates a running developer medium — so a push can never carry a
# different set of programs from the image it is updating.

# The products that go on the medium. An explicit list, not a glob over
# `.build/debug`, because that directory is full of SwiftPM's own intermediates.
BINARIES="undertow anchor abyssctl abyss-idle AquaDemo abyss-portal abyss-dbus abyss-theme
          abyss-install abyss-installctl abyssopen abyssgrab abyssnotify ventsctl
          fathom abyss-settings abyss-settingsctl abyss-appgen
          abyss-loginwindow abyss-loginctl"

# Data read at run time, from the tree, installed under /usr/local/share/abyss.
DATA_DIRS="themes fonts"
