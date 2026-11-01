# Build environment for the BaseOS Godot template and RetroArch: glibc 2.31 AArch64,
# like slot's device builds. The EGL/GLES/udev headers are for RetroArch.
FROM debian:bullseye
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-pip libasound2-dev ca-certificates git \
      libegl-dev libgles-dev libudev-dev zlib1g-dev \
    && pip3 install --no-cache-dir scons==4.8.1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /godot
