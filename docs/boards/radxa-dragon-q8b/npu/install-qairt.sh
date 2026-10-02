#!/bin/sh
#
# Install the parts of Qualcomm's QAIRT SDK that run QNN on the Q8B's NPU
# into /usr/local/qnn: the Linux aarch64 tools and libraries, and the
# Hexagon v68 libraries the DSP loads.  As root:
#	sh install-qairt.sh /path/to/qairt/2.51.0.260929
# (the SDK unzipped; its licence is yours to accept, at Qualcomm's site).
#
set -e
Q=/usr/local/qnn
sdk=${1:?usage: install-qairt.sh SDK-DIRECTORY}
host=aarch64-ubuntu-gcc9.4

for d in bin/$host lib/$host lib/hexagon-v68/unsigned; do
	[ -d "$sdk/$d" ] || { echo "no $sdk/$d: not a QAIRT SDK?" >&2; exit 1; }
done
mkdir -p $Q/bin $Q/lib $Q/dsp $Q/etc
# Owned by root, whatever the archive said.
(cd "$sdk/bin/$host" && tar -cf - .) | tar -xf - --no-same-owner -C $Q/bin
(cd "$sdk/lib/$host" && tar -cf - .) | tar -xf - --no-same-owner -C $Q/lib
(cd "$sdk/lib/hexagon-v68/unsigned" && tar -cf - .) |
    tar -xf - --no-same-owner -C $Q/dsp
chown -R root:wheel $Q
# The zip's modes are 0777: only root writes here.
chmod -R go-w $Q
echo "QAIRT from $sdk in $Q"
