FROM debian:trixie-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sudo ca-certificates git curl \
 && rm -rf /var/lib/apt/lists/*

# Provision libinput >= 1.29 from the Debian testing suite (trixie-stable
# ships an older version that does not satisfy Umbriel's build requirement).
# The narrow pin keeps everything else on stable.
RUN echo 'deb http://deb.debian.org/debian testing main' \
      > /etc/apt/sources.list.d/testing.list \
 && printf 'Package: libinput* libevdev* libwacom*\nPin: release a=testing\nPin-Priority: 900\n' \
      > /etc/apt/preferences.d/libinput-testing.pref \
 && apt-get update \
 && apt-get install -y --no-install-recommends libinput-dev \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash test \
 && echo 'test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-test-nopasswd \
 && chmod 0440 /etc/sudoers.d/90-test-nopasswd

USER test
WORKDIR /home/test/umbriel-noctalia-debian-script
COPY --chown=test:test . /home/test/umbriel-noctalia-debian-script
