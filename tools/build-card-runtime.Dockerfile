# Same ABI and build dependencies as engine/Dockerfile, frozen for publication.
FROM debian:bullseye@sha256:6f519a81440354a85eb592c5f32109ab80605f6b892455983a6f618bf87fabe9
ENV SOURCE_DATE_EPOCH=1789611180 TZ=UTC LC_ALL=C
RUN printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260824T000000Z/ bullseye main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260824T000000Z/ bullseye-security main\n' > /etc/apt/sources.list \
 && apt-get -o Acquire::Retries=3 update && apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 python3-pip libasound2-dev ca-certificates git \
      libegl-dev libgles-dev libudev-dev libdbus-1-dev zlib1g-dev \
 && printf '%s\n' 'scons==4.8.1 --hash=sha256:a4c3b434330e2d7d975002fd6783284ba348bf394db94c8f83fdc5bf69cdb8d7' >/tmp/scons.req \
 && pip3 install --no-cache-dir --no-deps --only-binary=:all: --require-hashes -r /tmp/scons.req \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /godot
