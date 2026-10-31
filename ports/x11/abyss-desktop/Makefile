# The AbyssBSD desktop (PHASE17 P17.1): every program of desktop/, built with
# Cargo, and the look it reads at run time.
#
# The distfile is not fetched: the release pipeline makes it with
# `git archive` of the monorepo's desktop/ at the release commit, puts it in
# poudriere's distfiles cache with ABYSS_RELEASE naming it
# (2026.10.31.55247473), and runs `make makesum` so distinfo records it
# beside the crates. Only the crates are fetched, from crates.io.

PORTNAME=	abyss-desktop
DISTVERSION=	${ABYSS_RELEASE}
CATEGORIES=	x11
MASTER_SITES=	# none: placed in DISTDIR by the pipeline
DISTFILES=	${DISTNAME}${EXTRACT_SUFX}

MAINTAINER=	kanej1973@gmail.com
COMMENT=	Themeable desktop on Wayland, written in Rust
WWW=		https://github.com/JamesKane/AbyssBSD

LICENSE=	BSD2CLAUSE

LIB_DEPENDS=	libcairo.so:graphics/cairo \
		libfontconfig.so:x11-fonts/fontconfig \
		libfreetype.so:print/freetype2 \
		libharfbuzz.so:print/harfbuzz \
		libpixman-1.so:x11/pixman \
		libwayland-client.so:graphics/wayland \
		libwlroots-0.20.so:x11-toolkits/wlroots020 \
		libxkbcommon.so:x11/libxkbcommon

USES=		cargo pkgconfig tar:xz

ABYSS_RELEASE?=	0
WRKSRC=		${WRKDIR}/desktop

# Cargo.lock's crates from crates.io (`make cargo-crates`). Everything else
# in the workspace is a path dependency inside the distfile.
CARGO_CRATES=	cc-1.10.0 \
		find-msvc-tools-0.1.15 \
		libc-0.2.191 \
		shlex-2.0.1

# One build of the whole workspace; the install picks the programs out of it,
# because `cargo install` takes one package at a time.
CARGO_BUILD_ARGS=	--workspace --bins
CARGO_INSTALL=	no

# The products of desktop/abyss/mk/desktop-files.sh's BINARIES.
ABYSS_PROGRAMS=	undertow anchor abyssctl abyss-idle AquaDemo abyss-portal \
		abyss-dbus abyss-theme abyss-install abyss-installctl abyssopen \
		abyssgrab abyssnotify ventsctl fathom abyss-settings \
		abyss-settingsctl abyss-appgen abyss-loginwindow abyss-loginctl \
		abyss-jaild abyss-jail abyss-model abyss-agent abyss-vocab abyss-fetch

do-install:
.for p in ${ABYSS_PROGRAMS}
	${INSTALL_PROGRAM} ${CARGO_TARGET_DIR}/release/${p} ${STAGEDIR}${PREFIX}/bin/
.endfor
	${MKDIR} ${STAGEDIR}${DATADIR}
	cd ${WRKSRC} && ${COPYTREE_SHARE} "themes fonts" ${STAGEDIR}${DATADIR}

post-install:
.for p in ${ABYSS_PROGRAMS}
	${ECHO_CMD} bin/${p} >> ${TMPPLIST}
.endfor
	cd ${STAGEDIR}${PREFIX} && ${FIND} share/abyss -type f | ${SORT} >> ${TMPPLIST}

.include <bsd.port.mk>
