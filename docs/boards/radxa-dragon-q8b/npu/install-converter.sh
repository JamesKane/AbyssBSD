#!/bin/sh
#
# Install QAIRT's model converters to run on the board, under the Linux
# layer: the SDK's Python tools and modules (aarch64 builds of their native
# parts are in the SDK, for Python 3.12), a relocatable Python 3.12 for
# aarch64 Linux (python-build-standalone), and the packages they import.
# As root, with the network up:
#	sh install-converter.sh /path/to/qairt/2.51.0.260929 \
#	    cpython-3.12.15+20261001-aarch64-unknown-linux-gnu-install_only.tar.gz
#
set -e
Q=/usr/local/qnn
sdk=${1:?usage: install-converter.sh SDK-DIRECTORY PYTHON-TARBALL}
py=${2:?usage: install-converter.sh SDK-DIRECTORY PYTHON-TARBALL}
tools="qairt-converter qairt-quantizer qnn-onnx-converter qnn-model-lib-generator"

[ -d "$sdk/lib/python/qti" ] || { echo "no $sdk/lib/python/qti" >&2; exit 1; }
mkdir -p $Q/sdk/lib $Q/sdk/bin/aarch64-linux
# The modules, without their x86-64 and Windows builds.
rm -rf $Q/sdk/lib/python
(cd "$sdk/lib" && tar -cf - --exclude linux-x86_64 --exclude '*windows*' \
    python) | tar -xf - --no-same-owner -C $Q/sdk/lib
for t in $tools; do
	install -m 555 "$sdk/bin/x86_64-linux-clang/$t" $Q/sdk/bin/aarch64-linux/
done
rm -rf $Q/python
tar -xzf "$py" --no-same-owner -C $Q
chown -R root:wheel $Q/sdk $Q/python
chmod -R go-w $Q/sdk $Q/python
# What the ONNX converter and the quantizer import, at QAIRT's tested
# versions where it names them; setuptools for distutils, gone in 3.12.
$Q/python/bin/python3.12 -m pip install --no-cache-dir \
    --root-user-action=ignore setuptools numpy==1.26.4 onnx==1.17.0 \
    pyyaml==6.0.3 packaging==24.0 aenum==3.1.15 typing-extensions==4.14.0 \
    absl-py==2.1.0 six==1.16.0 mako==1.2.0 tabulate==0.9.0 attrs==23.2.0 \
    pillow==10.2.0
echo "converters in $Q/sdk: qnn qairt-converter ..."
