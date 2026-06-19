FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG ANDROID_CMDLINE_TOOLS_ZIP=commandlinetools-linux-14742923_latest.zip

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:/home/vscode/.pub-cache/bin:${PATH}"

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    curl \
    git \
    libgtk-3-dev \
    liblzma-dev \
    make \
    ninja-build \
    openjdk-17-jdk \
    pkg-config \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" "${FLUTTER_HOME}" \
  && chown -R vscode:vscode "${ANDROID_HOME}" "${FLUTTER_HOME}"

USER vscode

# Bootstrap Flutter so Dart is available to install FVM.
RUN git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
  && git config --global --add safe.directory "${FLUTTER_HOME}" \
  && flutter config --no-analytics \
  && flutter precache --android \
  && dart pub global activate fvm

# Android SDK command-line tools.
RUN curl -fsSL "https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS_ZIP}" -o /tmp/android-tools.zip \
  && unzip -q /tmp/android-tools.zip -d /tmp/android-tools \
  && mv /tmp/android-tools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" \
  && rm -rf /tmp/android-tools /tmp/android-tools.zip \
  && yes | sdkmanager --licenses \
  && sdkmanager \
      "platform-tools" \
      "platforms;android-36" \
      "build-tools;36.0.0" \
  && flutter config --android-sdk "${ANDROID_HOME}"