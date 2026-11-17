# Linux x86_64 build of the RDKit C++ libraries + Java (SWIG) wrapper + InChI, targeting RHEL 9.
# No Python wrappers. Driven by ../build-linux.sh, which stages the source into the build context
# as ./src and ./smoke.
#
# AlmaLinux 9 is binary-compatible with RHEL 9 (glibc 2.34, gcc 11, libstdc++ from gcc 11), so the
# result runs on RHEL 9. RHEL 9's own Boost (1.75) and SWIG (4.1) are older than RDKit's minimums
# (Boost 1.81, SWIG 4.2), so both are built from source here. Boost is linked statically (-fPIC) so
# the shared RDKit libraries and libGraphMolWrap.so do not depend on a Boost runtime.
ARG BASE_IMAGE=almalinux:9

# Stage "deps" = toolchain + SWIG + Boost only (independent of the RDKit source, so it can be cached
# on its own: build-linux.sh builds it first with --target deps when DEPS_CACHE_DIR is set).
FROM ${BASE_IMAGE} AS deps
ARG JOBS=8
ARG BOOST_VERSION=1.92.0
ARG SWIG_VERSION=4.2.1

# crb = CodeReady Builder (needed for some -devel packages). Full (non-headless) OpenJDK so that
# CMake's JNI lookup finds libjawt.
RUN dnf -y install dnf-plugins-core && dnf config-manager --set-enabled crb \
 && dnf -y install gcc gcc-c++ make cmake git wget tar bzip2 xz unzip findutils which file binutils \
      java-17-openjdk java-17-openjdk-devel \
      pcre2-devel zlib-devel bzip2-devel freetype-devel \
 && dnf clean all
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk
ENV PATH=/opt/swig/bin:${PATH}

# SWIG (>= 4.2 required by RDKit)
RUN cd /tmp \
 && wget -q -O swig.tar.gz https://downloads.sourceforge.net/project/swig/swig/swig-${SWIG_VERSION}/swig-${SWIG_VERSION}.tar.gz \
 && tar xzf swig.tar.gz && cd swig-${SWIG_VERSION} \
 && ./configure --prefix=/opt/swig --without-alllang >/dev/null && make -j${JOBS} >/dev/null && make install >/dev/null \
 && cd / && rm -rf /tmp/swig* && swig -version

# Boost (>= 1.81 required by RDKit): static, PIC, only the compiled libs RDKit links
RUN cd /tmp \
 && BOOST_US=$(echo ${BOOST_VERSION} | tr . _) \
 && wget -q -O boost.tar.bz2 https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_US}.tar.bz2 \
 && tar xjf boost.tar.bz2 && cd boost_${BOOST_US} \
 && ./bootstrap.sh --prefix=/opt/boost --with-libraries=serialization,iostreams,system,filesystem >/dev/null \
 && ./b2 -j${JOBS} link=static variant=release threading=multi runtime-link=shared \
      cxxflags=-fPIC cflags=-fPIC install >/dev/null \
 && cd / && rm -rf /tmp/boost*

FROM deps AS build
ARG JOBS=8
# Fail the build if the Java wrapper needs a newer glibc than RHEL 9 provides (empty = no check).
ARG MAX_GLIBC=2.34

COPY src /src
RUN cmake -S /src -B /build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/boost \
      -DBoost_USE_STATIC_LIBS=ON \
      -DRDK_BUILD_PYTHON_WRAPPERS=OFF \
      -DRDK_BUILD_SWIG_WRAPPERS=ON \
      -DRDK_BUILD_SWIG_JAVA_WRAPPER=ON \
      -DRDK_BUILD_INCHI_SUPPORT=ON \
      -DRDK_BUILD_CHEMDRAW_SUPPORT=OFF \
      -DRDK_BUILD_CPP_TESTS=OFF \
      -DRDK_INSTALL_INTREE=OFF \
      -DCMAKE_INSTALL_PREFIX=/opt/rdkit
RUN cmake --build /build --parallel ${JOBS}
RUN cmake --install /build

# Collect the Java deliverables (the wrapper writes into the source tree) and record portability info.
RUN mkdir /dist \
 && cp /src/Code/JavaWrappers/gmwrapper/org.RDKit.jar /src/Code/JavaWrappers/gmwrapper/libGraphMolWrap.so /dist/ \
 && ldd /dist/libGraphMolWrap.so > /dist/ldd.txt \
 && (objdump -T /dist/libGraphMolWrap.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 > /dist/min-glibc.txt) \
 && echo "needs $(cat /dist/min-glibc.txt)" && cat /dist/ldd.txt \
 && if [ -n "${MAX_GLIBC}" ]; then \
      need=$(sed 's/GLIBC_//' /dist/min-glibc.txt); \
      [ "$(printf '%s\n%s\n' "${MAX_GLIBC}" "$need" | sort -V | tail -1)" = "${MAX_GLIBC}" ] \
        || { echo "ERROR: needs glibc $need but MAX_GLIBC=${MAX_GLIBC}"; exit 1; }; \
    fi

# Smoke test on Linux (JDK 17 here)
COPY smoke /smoke
RUN mkdir /smoke-out && javac -d /smoke-out -cp /dist/org.RDKit.jar /smoke/*.java \
 && for t in Smoke InchiSmoke; do java -Djava.library.path=/dist -cp /smoke-out:/dist/org.RDKit.jar $t; done

FROM scratch AS export
COPY --from=build /opt/rdkit /install
COPY --from=build /dist /java-dist
