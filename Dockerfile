FROM ubuntu:24.04

ARG  GRADLE_VERSION=8.14.3
ARG  DEBIAN_FRONTEND=noninteractive
ARG  KOTLIN_VERSION=1.9.23

# --------------------------------------------------------------------------- #
# 0. System tool-chain & libraries                                            #
# --------------------------------------------------------------------------- #
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang cmake git make ninja-build pkg-config            \
    flex  bison  libfl-dev                                                 \
    libgmp-dev                                                             \
    libssl-dev libjsoncpp-dev zlib1g-dev                                   \
    openjdk-21-jdk-headless                                                \
    curl unzip ca-certificates                                             \
 && rm -rf /var/lib/apt/lists/*

# Small helper: copy GMP headers to /usr/local so the cross-compiler that
# Kotlin/Native vendors inside ~/.konan finds them without -I flags.
RUN for hdr in gmp.h gmpxx.h ; do                                       \
        cp  "$(dpkg -L libgmp-dev | grep "/${hdr}$" | head -n1)"        \
            /usr/local/include/ ;                                       \
    done

# --------------------------------------------------------------------------- #
# 1. Build & install RELIC (OpenABE’s big crypto dependency)                  #
# --------------------------------------------------------------------------- #
RUN git clone --depth 1 https://github.com/relic-toolkit/relic.git /tmp/relic \
 && cmake  -S /tmp/relic        -B /tmp/relic/build                          \
           -DCMAKE_BUILD_TYPE=Release                                        \
           -DCMAKE_INSTALL_PREFIX=/usr/local                                 \
           -DRELIC_GMP=ON  -DRELIC_SHARED=ON  -DRELIC_TESTS=OFF              \
 && cmake --build /tmp/relic/build --target install -j$(nproc)               \
 && rm -rf /tmp/relic

#  OpenABE’s makefiles expect the names librelic_ec.{a,so}
RUN for ext in so a; do ln -sf /usr/local/lib/librelic.${ext} \
                            /usr/local/lib/librelic_ec.${ext}; done

#  Same story for Flex and GMP when we later pack the static wrapper lib
RUN ln -sf /usr/lib/x86_64-linux-gnu/libfl.a      /usr/local/lib/libfl.a  && \
    for ext in so a; do ln -sf /usr/lib/x86_64-linux-gnu/libgmp.${ext}    \
                             /usr/local/lib/libgmp.${ext};              done && \
    cp /usr/include/FlexLexer.h /usr/local/include/

# --------------------------------------------------------------------------- #
# 2. Gradle – install once, reuse in every layer                              #
# --------------------------------------------------------------------------- #
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="/opt/gradle-${GRADLE_VERSION}/bin:${JAVA_HOME}/bin:${PATH}"

RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    -o /tmp/gradle.zip && unzip -q /tmp/gradle.zip -d /opt && rm /tmp/gradle.zip

# --------------------------------------------------------------------------- #
# 3. Project sources                                                          #
# --------------------------------------------------------------------------- #
ARGS BALLS = 1
WORKDIR /workspace
RUN git clone https://github.com/lallo-unitn/kotlin-multiplatform-openabe.git . \
 && git submodule update --init --recursive

###############################################################################
#  BUILD SECTION – every major artefact gets its own layer                    #
###############################################################################

# --------------------------------------------------------------------------- #
# 3-A  Kotlin common API – downloads Gradle wrapper + all Maven deps          #
# --------------------------------------------------------------------------- #
RUN gradle wrapper               \
        --gradle-version ${GRADLE_VERSION} \
        --distribution-type bin  \
        --no-daemon              && \
    chmod +x gradlew             && \
    ./gradlew :multiplatform-crypto-api:build \
             --no-daemon --stacktrace

# --------------------------------------------------------------------------- #
# 3-B  OpenABE native library                                                 #
#       (1) configure, (2) compile deps, (3) compile src                      #
# --------------------------------------------------------------------------- #
# The helper scripts live in openabeWrapper/ – we simply drive them one by one
WORKDIR /workspace/openabeWrapper
RUN chmod +x configureOpenABELinuxX86-64.sh makeOpenABELinuxX86-64.sh && \
    ./configureOpenABELinuxX86-64.sh && \
    ./makeOpenABELinuxX86-64.sh

# --------------------------------------------------------------------------- #
# 3-C  C++ wrapper around OpenABE                                             #
# --------------------------------------------------------------------------- #
RUN chmod +x configureWrapperLinuxX86-64.sh makeWrapperLinuxX86-64.sh  && \
    ./configureWrapperLinuxX86-64.sh && \
    ./makeWrapperLinuxX86-64.sh

WORKDIR /workspace/openabeWrapper

RUN dest=../multiplatform-crypto-libopenabe-bindings/src/jvmMain/resources \
 && mkdir -p "${dest}"                                                     \
 && for lib in librelic.so librelic_ec.so libopenabe.so libwrapper.so ; do \
        for dir in openabe/deps/root/lib openabe/root/lib wrapper ; do      \
            if [ -f "${dir}/${lib}" ]; then                                 \
                cp "${dir}/${lib}" "${dest}/dynamic-linux-x86-64-${lib}" ;  \
                echo "✓ staged ${lib} from ${dir}" ;                        \
                break ;                                                     \
            fi ;                                                            \
        done ;                                                              \
    done                                                                    \
 && cp /usr/lib/x86_64-linux-gnu/libgmp.so*    "${dest}/"                   \
 && cp /usr/lib/x86_64-linux-gnu/libgmpxx.so*  "${dest}/"                   \
 && cp /usr/lib/x86_64-linux-gnu/libfl.so*     "${dest}/"                   \
 && echo "✓ staged system-provided GMP and Flex shared objects"

RUN test -f wrapper/libwrapperNoDeps.a \
 && ln -sf libwrapperNoDeps.a wrapper/libwrapper.a \
 && echo "✓ linked libwrapper.a → libwrapperNoDeps.a"
# --------------------------------------------------------------------------- #
# 3-E  Kotlin/Native bindings (libopenabe-bindings)                           #
# --------------------------------------------------------------------------- #
WORKDIR /workspace

RUN set -e ; \
    echo "forcing Kotlin → $KOTLIN_VERSION" ; \
    # 2-A  gradle/libs.versions.toml (if the project uses version-catalogs)
    if [ -f gradle/libs.versions.toml ]; then \
        sed -i -E "s|kotlin[[:space:]]*=[[:space:]]*\"[0-9]+\.[0-9]+\.[0-9]+\"|kotlin = \"$KOTLIN_VERSION\"|" \
               gradle/libs.versions.toml ; \
    fi ; \
    # 2-B  every plugins { kotlin("…") version "…" } line in *.gradle.kts
    grep -rl --exclude-dir=.git --include='*.gradle.kts' \
        'kotlin("multiplatform") version' | while read -r f ; do \
          sed -i -E "s|(kotlin\\(\"[a-zA-Z0-9-]+\"\\)[^\"]*version[[:space:]]+\")[0-9]+\.[0-9]+\.[0-9]+|\\1$KOTLIN_VERSION|" "$f" ; \
    done ; \
    # 2-C  buildSrc build-logic (the same pattern, if present)
    if grep -qr 'kotlin("multiplatform") version' buildSrc 2>/dev/null; then \
        grep -rl 'kotlin("multiplatform") version' buildSrc --include='*.gradle.kts' | while read -r f ; do \
            sed -i -E "s|(kotlin\\(\"[a-zA-Z0-9-]+\"\\)[^\"]*version[[:space:]]+\")[0-9]+\.[0-9]+\.[0-9]+|\\1$KOTLIN_VERSION|" "$f" ; \
        done ; \
    fi ; \
    echo "Kotlin plugin pinned to $KOTLIN_VERSION everywhere"

RUN ./gradlew :multiplatform-crypto-libopenabe-bindings:build \
               --no-daemon --stacktrace