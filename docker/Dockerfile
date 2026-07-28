FROM ubuntu:24.04

ARG RUNNER_VERSION
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq git sudo ca-certificates build-essential libicu-dev gnupg \
    unzip zip wget xz-utils tar gzip shellcheck locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Bootstrap Node.js (setup-node will override with the exact version)
ARG NODE_MAJOR=22
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN mkdir -p /home/runner/.npm /home/runner/pw-browsers \
    && chown -R runner:runner /home/runner/.npm /home/runner/pw-browsers

USER runner
WORKDIR /home/runner

# actions/runner tarballs are named x64/arm64, not Docker's amd64/arm64
RUN case "${TARGETARCH}" in \
        amd64) runner_arch=x64 ;; \
        arm64) runner_arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH: '${TARGETARCH}' (empty = BuildKit disabled)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
    && tar xzf actions-runner.tar.gz \
    && rm actions-runner.tar.gz

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
