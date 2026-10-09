PORTNAME=	qcom-iris-firmware
PORTVERSION=	0.2.42
CATEGORIES=	multimedia

MAINTAINER=	kanej1973@gmail.com
COMMENT=	Firmware for the Radxa Dragon Q8B's video codec (Qualcomm Iris)
WWW=		https://github.com/radxa-pkg/radxa-firmware

# Radxa ships the image without terms of its own (the repository's
# GPLv3 covers its packaging): build it for local use, mirror nothing.
LICENSE=	RADXAFW
LICENSE_NAME=	Radxa firmware, terms not stated
LICENSE_TEXT=	Qualcomm's video firmware as Radxa distributes it, with no \
		license of its own: packaged for local use only.
LICENSE_PERMS=	auto-accept

ONLY_FOR_ARCHS=	aarch64
ONLY_FOR_ARCHS_REASON=	the Dragon Q8B's SC8280XP is an aarch64 SoC

USE_GITHUB=	yes
GH_ACCOUNT=	radxa-pkg
GH_PROJECT=	radxa-firmware

NO_ARCH=	yes
NO_BUILD=	yes

# Where LinuxKPI's request_firmware() finds it for qcom_iris (vpu-kmod).
FWDIR=		boot/firmware/qcom/vpu
PLIST_FILES=	/${FWDIR}/vpu20_p4_gen2_s6.mbn

do-install:
	${MKDIR} ${STAGEDIR}/${FWDIR}
	${INSTALL_DATA} \
	    ${WRKSRC}/radxa-firmware-sc8280xp/lib/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn \
	    ${STAGEDIR}/${FWDIR}

.include <bsd.port.mk>
