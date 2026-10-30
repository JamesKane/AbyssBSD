# The AbyssBSD desktop (PHASE17 P17.1): every program of desktop/, built with
# SwiftPM, and the look it reads at run time.
#
# The distfile is not fetched: the release pipeline makes it with
# `git archive` of the monorepo's desktop/ at the release commit and puts it in
# poudriere's distfiles cache, with ABYSS_RELEASE naming it (2026.10.02.3ca6aa3).

PORTNAME=	abyss-desktop
DISTVERSION=	${ABYSS_RELEASE}
CATEGORIES=	x11
MASTER_SITES=	# none: placed in DISTDIR by the pipeline

MAINTAINER=	kanej1973@gmail.com
COMMENT=	Mac OS X 10.2-style desktop on Wayland, written in Swift
WWW=		https://github.com/JamesKane/AbyssBSD

LICENSE=	BSD2CLAUSE

ONLY_FOR_ARCHS=	amd64
ONLY_FOR_ARCHS_REASON=	lang/swift6 is packaged for amd64 only (MIGRATION §5)

BUILD_DEPENDS=	${LOCALBASE}/swift6/bin/swift:lang/swift6
LIB_DEPENDS=	libcairo.so:graphics/cairo \
		libfontconfig.so:x11-fonts/fontconfig \
		libfreetype.so:print/freetype2 \
		libharfbuzz.so:print/harfbuzz \
		libpixman-1.so:x11/pixman \
		libwayland-client.so:graphics/wayland \
		libwlroots-0.20.so:x11-toolkits/wlroots020 \
		libxkbcommon.so:x11/libxkbcommon

USES=		pkgconfig tar:xz

ABYSS_RELEASE?=	0
WRKSRC=		${WRKDIR}/desktop

# The products of desktop/abyss/mk/desktop-files.sh's BINARIES.
ABYSS_PROGRAMS=	undertow anchor abyssctl abyss-idle AquaDemo abyss-portal \
		abyss-dbus abyss-theme abyss-install abyss-installctl abyssopen \
		abyssgrab abyssnotify ventsctl fathom abyss-settings \
		abyss-settingsctl abyss-appgen abyss-loginwindow abyss-loginctl \
		abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab abyss-fetch

# SwiftPM writes caches under $HOME and resolves nothing: Package.swift has no
# remote dependencies, so the build needs no network.
do-build:
	cd ${WRKSRC} && ${SETENV} HOME=${WRKDIR} ${LOCALBASE}/swift6/bin/swift build \
		-c release --disable-sandbox --scratch-path ${WRKDIR}/swiftpm \
		-j ${MAKE_JOBS_NUMBER}

do-install:
.for p in ${ABYSS_PROGRAMS}
	${INSTALL_PROGRAM} ${WRKDIR}/swiftpm/release/${p} ${STAGEDIR}${PREFIX}/bin/
.endfor
	${MKDIR} ${STAGEDIR}${DATADIR}
	cd ${WRKSRC} && ${COPYTREE_SHARE} "themes fonts" ${STAGEDIR}${DATADIR}

post-install:
.for p in ${ABYSS_PROGRAMS}
	${ECHO_CMD} bin/${p} >> ${TMPPLIST}
.endfor
	cd ${STAGEDIR}${PREFIX} && ${FIND} share/abyss -type f | ${SORT} >> ${TMPPLIST}

.include <bsd.port.mk>
