#!/bin/sh
#
# Build the FastRPC library for Linux programs (QNN's libcdsprpc), and the
# libyaml it needs, with Rocky Linux 9's gcc (linux-rl9-devtools) under the
# Linux layer, from FreeBSD's sh and gmake as a cross build.  As a user:
#	sh build-linux-fastrpc.sh FASTRPC-SOURCE yaml-0.2.5.tar.gz BUILD-DIR
# then, as root, the same with "install" first to install into
# /usr/local/qnn/lib.  FASTRPC-SOURCE is github.com/JamesKane/fastrpc,
# branch freebsd: it builds without libbsd, which Rocky 9 lacks.
#
set -e
P=/usr/local/qnn
T=aarch64-linux-gnu
inst=
[ "$1" = install ] && { inst=1; shift; }
src=$(realpath "${1:?FASTRPC-SOURCE}")
yaml=$(realpath "${2:?yaml-0.2.5.tar.gz}")
B=${3:?BUILD-DIR}

mkdir -p $B/bin
B=$(realpath $B)
# The cross tools: Rocky's, under the names configure looks for.
for t in gcc g++ ar ranlib nm strip ld as objdump; do
	printf '#!/bin/sh\nexec /compat/linux/usr/bin/%s "$@"\n' $t > $B/bin/$T-$t
	chmod 755 $B/bin/$T-$t
done
export PATH=$B/bin:$PATH
# libyaml as staged in the build, and none of FreeBSD's .pc files.
export PKG_CONFIG_SYSROOT_DIR=$B/stage PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR=$B/stage$P/lib/pkgconfig

if [ -n "$inst" ]; then
	gmake -C $B/yaml-0.2.5 install
	# The libraries only: the rest installs systemd and udev files.
	gmake -C $B/fastrpc/src install
	rm -f $P/lib/*.la
	exit 0
fi

rm -rf $B/yaml-0.2.5 $B/fastrpc $B/stage
tar -xzf $yaml -C $B
(cd $B/yaml-0.2.5 && ./configure --host=$T --prefix=$P && gmake -j8 &&
    gmake install DESTDIR=$B/stage)
mkdir -p $B/fastrpc
(cd $src && tar -cf - --exclude .git .) |
    tar -xf - -C $B/fastrpc
(cd $B/fastrpc && sh ./autogen.sh && ./configure --host=$T --prefix=$P &&
    gmake -j8)
echo "built in $B"
