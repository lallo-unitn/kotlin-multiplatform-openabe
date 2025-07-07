FROM ubuntu:24.04

ARG GRADLE_VERSION=8.14.3
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang cmake git make ninja-build pkg-config \
    flex bison libfl-dev \
    libgmp-dev \
    libssl-dev libjsoncpp-dev zlib1g-dev \
    openjdk-21-jdk-headless curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/include/x86_64-linux-gnu/gmp.h   /usr/local/include/gmp.h  && \
    ln -sf /usr/include/x86_64-linux-gnu/gmpxx.h /usr/local/include/gmpxx.h

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="/opt/gradle-${GRADLE_VERSION}/bin:${JAVA_HOME}/bin:${PATH}"

RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    -o gradle.zip && unzip -q gradle.zip -d /opt && rm gradle.zip

WORKDIR /workspace
RUN git clone https://github.com/lallo-unitn/kotlin-multiplatform-openabe.git . \
    && git submodule update --init --recursive

RUN chmod +x gradlew linuxBuildLinuxX86-64*.sh && \
    gradle wrapper --gradle-version ${GRADLE_VERSION} --distribution-type bin --no-daemon \

RUN ./linuxBuildLinuxX86-64.sh --no-daemon