FROM debian:trixie-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sudo ca-certificates git curl \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash test \
 && echo 'test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-test-nopasswd \
 && chmod 0440 /etc/sudoers.d/90-test-nopasswd

USER test
WORKDIR /home/test/umbriel-noctalia-debian-script
COPY --chown=test:test . /home/test/umbriel-noctalia-debian-script
