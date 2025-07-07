FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GRADLE_VERSION=8.14.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang cmake git make ninja-build pkg-config \
    libgmp-dev libssl-dev libjsoncpp-dev zlib1g-dev \
    openjdk-21-jdk-headless curl unzip ca-certificates \
    bison lsb-release git sudo python3-pip nano libgtest-dev curl autopoint gettext \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:${PATH}"

RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o gradle.zip \
    && unzip -q gradle.zip -d /opt \
    && rm gradle.zip
ENV GRADLE_HOME="/opt/gradle-${GRADLE_VERSION}"
ENV PATH="${GRADLE_HOME}/bin:${PATH}"

WORKDIR /workspace
RUN git clone https://github.com/lallo-unitn/kotlin-multiplatform-openabe.git .

RUN chmod +x gradlew linuxBuildLinuxX86-64*.sh

RUN gradle wrapper --gradle-version ${GRADLE_VERSION} --distribution-type bin --no-daemon \
    && ./linuxBuildLinuxX86-64.sh --no-daemon