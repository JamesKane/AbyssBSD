PORTNAME=	linux-fastrpc
DISTVERSIONPREFIX=	v
DISTVERSION=	1.0.8-2
DISTVERSIONSUFFIX=	-g0e38ac2
PORTREVISION=	1
CATEGORIES=	misc linux
MASTER_SITES=	https://pyyaml.org/download/libyaml/:yaml
DISTFILES=	yaml-${YAML_VERSION}.tar.gz:yaml

MAINTAINER=	kanej1973@gmail.com
COMMENT=	FastRPC library for Linux programs, and the Dragon Q8B's DSP files
WWW=		https://github.com/JamesKane/fastrpc

LICENSE=	BSD3CLAUSE MIT GPLv3+
LICENSE_COMB=	multi
LICENSE_FILE_BSD3CLAUSE=	${WRKSRC}/LICENSE.txt

ONLY_FOR_ARCHS=	aarch64
ONLY_FOR_ARCHS_REASON=	the Qualcomm DSPs it calls are on aarch64 SoCs

USES=		gmake linux:rl9 llvm:build pkgconfig:build
USE_GITHUB=	yes
GH_ACCOUNT=	JamesKane
GH_PROJECT=	fastrpc
GH_TUPLE=	radxa-pkg:radxa-firmware:${RADXA_VERSION}:radxa/radxa
USE_LINUX=	devtools:build

BUILD_DEPENDS=	autoconf>0:devel/autoconf \
		automake>0:devel/automake \
		libtool>0:devel/libtool

YAML_VERSION=	0.2.5
RADXA_VERSION=	0.2.42
# The libraries: Linux programs find them by LD_LIBRARY_PATH.
LXPREFIX=	${PREFIX}/lib/linux-fastrpc
QCOM_DSP=	share/qcom/sc8280xp/radxa/dragon-q8b/dsp

# Cross-built with LLVM's clang and lld for Linux, against Rocky Linux 9's
# headers and libraries in ${LINUXBASE}: nothing Linux runs.  Not the base
# system's clang, whose resource directory lacks stddef.h, stdatomic.h and
# their kin (gcc's are written for gcc).
LXTRIPLE=	aarch64-redhat-linux
LXCC=		${LLVM_PREFIX}/bin/clang --target=${LXTRIPLE} \
		--sysroot=${LINUXBASE} -fuse-ld=lld
LXENV=		CC="${LXCC}" CPP="${LXCC} -E" AR=${AR} RANLIB=${RANLIB} \
		NM=${NM} STRIP=${STRIP} CFLAGS="-O2 -pipe" CPPFLAGS="" \
		LDFLAGS="" PKG_CONFIG_PATH="" \
		PKG_CONFIG_LIBDIR=${WRKDIR}/yaml-stage${LXPREFIX}/lib/pkgconfig \
		PKG_CONFIG_SYSROOT_DIR=${WRKDIR}/yaml-stage
LXCONFIGURE=	--host=${LXTRIPLE} --build=${CONFIGURE_TARGET} \
		--prefix=${LXPREFIX}

do-configure:
	cd ${WRKDIR}/yaml-${YAML_VERSION} && ${SETENV} ${LXENV} \
	    ${SH} ./configure ${LXCONFIGURE} --disable-static
	cd ${WRKSRC} && ${SH} ./autogen.sh

do-build:
	cd ${WRKDIR}/yaml-${YAML_VERSION} && ${SETENV} ${LXENV} ${MAKE_CMD} && \
	    ${SETENV} ${LXENV} ${MAKE_CMD} install DESTDIR=${WRKDIR}/yaml-stage
	cd ${WRKSRC} && ${SETENV} ${LXENV} ${SH} ./configure ${LXCONFIGURE} \
	    --with-config-base-dir=${PREFIX}/share/qcom/ && \
	    ${SETENV} ${LXENV} ${MAKE_CMD}

do-install:
	cd ${WRKDIR}/yaml-${YAML_VERSION}/src && ${SETENV} ${LXENV} \
	    ${MAKE_CMD} install-libLTLIBRARIES DESTDIR=${STAGEDIR}
	# The libraries and the DSP daemons, not systemd's or udev's files.
	cd ${WRKSRC}/src && ${SETENV} ${LXENV} ${MAKE_CMD} install \
	    DESTDIR=${STAGEDIR}
	${RM} ${STAGEDIR}${LXPREFIX}/lib/*.la
	${MKDIR} ${STAGEDIR}${PREFIX}/${QCOM_DSP}
	cd ${WRKSRC}/radxa/radxa-firmware-sc8280xp/usr/${QCOM_DSP} && \
	    ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/${QCOM_DSP}
	# The compute DSP's own firmware, which qcom_adsp(4) loads from here.
	${MKDIR} ${STAGEDIR}/boot/firmware/qcom/sc8280xp
	${INSTALL_DATA} \
	    ${WRKSRC}/radxa/radxa-firmware-sc8280xp/lib/firmware/qcom/sc8280xp/qccdsp8280.mbn \
	    ${STAGEDIR}/boot/firmware/qcom/sc8280xp
	${MKDIR} ${STAGEDIR}${PREFIX}/share/qcom/conf.d
	${INSTALL_DATA} ${FILESDIR}/radxa-dragon-q8b.yaml \
	    ${STAGEDIR}${PREFIX}/share/qcom/conf.d/

.include <bsd.port.mk>
