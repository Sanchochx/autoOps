# syntax=docker/dockerfile:1
# Self-hosted GitHub Actions runner (US-CICD-003). Built on the host by scripts/provision/75_runner.sh from the
# official actions/runner release, pinned by version and SHA-256 (the build fails on a mismatch). Build context:
# infra/runner.
#   docker build -t autoops-runner infra/runner
# Upgrading the runner = bump RUNNER_VERSION and RUNNER_SHA256 together (the sum is in the release notes) and rebuild:
# the runner's self-update is disabled because the root filesystem is read-only at run time.
ARG UBUNTU_VERSION=24.04

# ── Stage 1: download and verify ─────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION} AS fetch

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum --check --strict - \
    && mkdir /opt/actions-runner \
    && tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner \
    && chmod -R a+rX /opt/actions-runner

# ── Stage 2: runtime ─────────────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION} AS runtime

# Unprivileged user. There is deliberately no sudo and no Docker client: the runner must never reach the Docker
# socket (root on the host). Handing work over to the host is designed in US-CICD-004.
RUN groupadd --system --gid 10001 runner \
    && useradd --system --uid 10001 --gid runner --home-dir /home/runner --create-home --shell /bin/bash runner

# Pristine, root-owned copy of the runner. The entrypoint refreshes the working copy from it on every start, so
# whatever a job changed in the binaries does not survive a restart.
COPY --from=fetch /opt/actions-runner /opt/actions-runner

# The runner's own dependency installer, plus the only tools the deploy job needs.
RUN apt-get update \
    && /opt/actions-runner/bin/installdependencies.sh \
    && apt-get install -y --no-install-recommends ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/*

# Working copy and credentials (.runner, .credentials*): a named volume mounted here inherits this owner on first use.
RUN install -d -o runner -g runner -m 0700 /home/runner/runner

COPY --chmod=0755 entrypoint.sh /usr/local/bin/runner-entrypoint.sh

USER runner
WORKDIR /home/runner/runner

ENTRYPOINT ["/usr/local/bin/runner-entrypoint.sh"]
