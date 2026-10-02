PORTNAME=	qairt
DISTVERSION=	2.51.0.260929
CATEGORIES=	misc linux

MAINTAINER=	kanej1973@gmail.com
COMMENT=	Qualcomm AI Runtime (QNN) for the NPU, under the Linux layer
WWW=		https://softwarecenter.qualcomm.com/

LICENSE=	QUALCOMM_AI_STACK
LICENSE_NAME=	Qualcomm AI Stack License
LICENSE_TEXT=	See LICENSE.pdf in the QAIRT SDK
LICENSE_PERMS=	no-dist-mirror no-dist-sell no-pkg-mirror no-pkg-sell \
		auto-accept

ONLY_FOR_ARCHS=	aarch64
ONLY_FOR_ARCHS_REASON=	runs on Qualcomm aarch64 SoCs' NPUs

# The SDK may not be redistributed on its own (its licence, section 1):
# each user builds this from their own download, unzipped.
NO_PACKAGE=	Qualcomm's AI Stack License allows no standalone redistribution

RUN_DEPENDS=	linux-fastrpc>0:misc/linux-fastrpc

USES=		linux:rl9
# QNN's libraries need libstdc++ and libatomic, which come with these.
USE_LINUX=	devtools
USE_RC_SUBR=	qnn
SUB_FILES=	htp_netrun.json qnn-wrapper
SUB_LIST=	LINUX_FASTRPC=${PREFIX}/lib/linux-fastrpc
PLIST_FILES=	bin/qnn

NO_BUILD=	yes
NO_WRKSUBDIR=	yes

OPTIONS_DEFINE=	CONVERTERS
OPTIONS_DEFAULT=	CONVERTERS
CONVERTERS_DESC=	Model converters and quantizer (Python 3.12 included)

# The unzipped SDK, as Qualcomm's site gives it: QAIRT_SDK=/path/to/it.
QAIRT_SDK?=
QAIRT_BUILD_ID=	260929181845
QAIRT_HTP_SHA256=	baa31f182d2cc5fdde167a89181d064f6fc6de3d900b7cbf2b35186395c6bb57
QAIRT_HOST=	aarch64-ubuntu-gcc9.4
QNN=		${PREFIX}/qnn

.if empty(QAIRT_SDK) || !exists(${QAIRT_SDK}/sdk.yaml)
IGNORE=		needs Qualcomm's QAIRT SDK ${DISTVERSION}: download it from \
		${WWW} (its licence is yours to accept), unzip it, and build \
		with QAIRT_SDK=/path/to/qairt/${DISTVERSION}
.endif

# The converters: a relocatable Python 3.12 for aarch64 Linux (the SDK's
# native modules are built for 3.12), and the packages they import, at the
# versions QAIRT was tested with where it names them.
PBS_RELEASE=	20261001
PBS_PYTHON=	cpython-3.12.15+${PBS_RELEASE}-aarch64-unknown-linux-gnu-install_only.tar.gz
WHEELS=		numpy-1.26.4-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl:numpy \
		onnx-1.17.0-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl:onnx \
		protobuf-7.36.2-cp310-abi3-manylinux2014_aarch64.whl:protobuf \
		pyyaml-6.0.3-cp312-cp312-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl:pyyaml \
		pillow-10.2.0-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl:pillow \
		markupsafe-3.0.3-cp312-cp312-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl:markupsafe \
		packaging-24.0-py3-none-any.whl:packaging \
		aenum-3.1.15-py3-none-any.whl:aenum \
		typing_extensions-4.14.0-py3-none-any.whl:typing \
		absl_py-2.1.0-py3-none-any.whl:absl \
		six-1.16.0-py2.py3-none-any.whl:six \
		Mako-1.2.0-py3-none-any.whl:mako \
		tabulate-0.9.0-py3-none-any.whl:tabulate \
		attrs-23.2.0-py3-none-any.whl:attrs \
		setuptools-84.0.0-py3-none-any.whl:setuptools
PYPI=		https://files.pythonhosted.org/packages/
CONVERTERS_MASTER_SITES= \
	https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/:pbs \
	${PYPI}79/f8/97f10e6755e2a7d027ca783f63044d5b1bc1ae7acb12afe6a9b4286eac17/:numpy \
	${PYPI}f0/6c/f040652277f514ecd81b7251841f96caa5538365af7df07f86c6018cda2b/:onnx \
	${PYPI}b6/ea/91fdf7c2b8bbd49cde056f00a9df6773532987e1c00fe2830b895af95c7e/:protobuf \
	${PYPI}ed/23/7a778b6bd0b9a8039df8b1b1d80e2e2ad78aa04171592c8a5c43a56a6af4/:pyyaml \
	${PYPI}ab/72/e6a8887c0ce6c94cd0b74fef495a81f4ea4c742242de4bc1943abbd21f92/:pillow \
	${PYPI}1e/2c/799f4742efc39633a1b54a92eec4082e4f815314869865d876824c257c1e/:markupsafe \
	${PYPI}49/df/1fceb2f8900f8639e278b056416d49134fb8d84c5942ffaa01ad34782422/:packaging \
	${PYPI}d0/fa/ca0c66b388624ba9dbbf35aab3a9f326bfdf5e56a7237fe8f1b600da6864/:aenum \
	${PYPI}69/e0/552843e0d356fbb5256d21449fa957fa4eff3bbc135a74a691ee70c7c5da/:typing \
	${PYPI}a2/ad/e0d3c824784ff121c03cc031f944bc7e139a8f1870ffd2845cc2dd76f6c4/:absl \
	${PYPI}d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/:six \
	${PYPI}6e/01/45ab9f723a93e0ca75fba4d2c266bb041120cb4215eab94f7c78743ac7ed/:mako \
	${PYPI}40/44/4a5f08c96eb108af5cb50b41f76142f0afa346dfa99d5296fe7202a11854/:tabulate \
	${PYPI}e0/44/827b2a91a5816512fcaf3cc4ebc465ccd5d598c45cefa6703fcf4a79018f/:attrs \
	${PYPI}95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/:setuptools
CONVERTERS_DISTFILES=	${PBS_PYTHON}:pbs ${WHEELS}
CONVERTERS_TOOLS=	qairt-converter qairt-quantizer qnn-onnx-converter \
			qnn-model-lib-generator

# Nothing to extract from distfiles: the SDK is a directory, and the
# converters' files are unpacked straight into the stage at install.
EXTRACT_ONLY=

do-extract:
	@${MKDIR} ${WRKDIR}
	@${GREP} -qx 'version: ${DISTVERSION:R}' ${QAIRT_SDK}/sdk.yaml && \
	    ${GREP} -qx 'build_id: ${QAIRT_BUILD_ID}' ${QAIRT_SDK}/sdk.yaml || \
	    { ${ECHO_MSG} "${QAIRT_SDK} is not QAIRT ${DISTVERSION}"; ${FALSE}; }
	@[ "$$(${SHA256} -q ${QAIRT_SDK}/lib/${QAIRT_HOST}/libQnnHtp.so)" = \
	    "${QAIRT_HTP_SHA256}" ] || \
	    { ${ECHO_MSG} "${QAIRT_SDK}: libQnnHtp.so differs"; ${FALSE}; }

do-install:
	${MKDIR} ${STAGEDIR}${QNN}/bin ${STAGEDIR}${QNN}/lib \
	    ${STAGEDIR}${QNN}/dsp ${STAGEDIR}${QNN}/etc
	# The Linux aarch64 tools and libraries, and the v68 DSP libraries.
	cd ${QAIRT_SDK}/bin/${QAIRT_HOST} && ${COPYTREE_BIN} . ${STAGEDIR}${QNN}/bin
	cd ${QAIRT_SDK}/lib/${QAIRT_HOST} && ${COPYTREE_SHARE} . ${STAGEDIR}${QNN}/lib
	cd ${QAIRT_SDK}/lib/hexagon-v68/unsigned && \
	    ${COPYTREE_SHARE} . ${STAGEDIR}${QNN}/dsp
	${INSTALL_SCRIPT} ${WRKDIR}/qnn-wrapper ${STAGEDIR}${QNN}/bin/qnn
	${RLN} ${STAGEDIR}${QNN}/bin/qnn ${STAGEDIR}${PREFIX}/bin/qnn
	${INSTALL_DATA} ${FILESDIR}/htp_config.json ${WRKDIR}/htp_netrun.json \
	    ${STAGEDIR}${QNN}/etc

do-install-CONVERTERS-on:
	# The SDK's Python tools and modules, but their x86-64 and Windows
	# builds.
	${MKDIR} ${STAGEDIR}${QNN}/sdk/lib ${STAGEDIR}${QNN}/sdk/bin/aarch64-linux
	cd ${QAIRT_SDK}/lib && ${TAR} -cf - --exclude linux-x86_64 \
	    --exclude '*windows*' python | ${TAR} -xf - -C ${STAGEDIR}${QNN}/sdk/lib
.for t in ${CONVERTERS_TOOLS}
	${INSTALL_SCRIPT} ${QAIRT_SDK}/bin/x86_64-linux-clang/${t} \
	    ${STAGEDIR}${QNN}/sdk/bin/aarch64-linux
.endfor
	${TAR} -xzf ${DISTDIR}/${PBS_PYTHON} -C ${STAGEDIR}${QNN}
	# Wheels are zip archives: unpacked into site-packages, they are
	# installed, with nothing Linux run to do it.
.for w in ${WHEELS:C/:[^:]*$//}
	cd ${STAGEDIR}${QNN}/python/lib/python3.12/site-packages && \
	    ${TAR} -xf ${DISTDIR}/${w}
.endfor
	# The SDK's scripts, and Python's own, are for this Python, which the
	# qnn command runs them with: say so in their first lines.
	cd ${STAGEDIR}${QNN} && ${GREP} -rlE '^#![[:space:]]*/usr/bin/env python3?[[:space:]]*$$' \
	    sdk python | \
	    ${XARGS} ${SED} -i '' -E \
	    '1s|^#![[:space:]]*/usr/bin/env python3?[[:space:]]*$$|#!${QNN}/python/bin/python3.12|'

post-install:
	# The SDK's zip leaves its files 0777; and directories that held only
	# what was left out are empty.
	${CHMOD} -R go-w ${STAGEDIR}${QNN}
	${FIND} ${STAGEDIR}${QNN} -type d -empty -delete
	# Thousands of files: the plist is what was staged.
	cd ${STAGEDIR}${PREFIX} && ${FIND} qnn -type f -o -type l | \
	    ${SORT} >> ${TMPPLIST}

.include <bsd.port.mk>
