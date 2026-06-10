# P1: Download and extract runner binaries
FROM ubuntu:24.04 AS builder

ARG RUNNER_VERSION="2.334.0"
ARG TARGETARCH

RUN apt-get update && apt-get install -y curl tar

WORKDIR /actions-runner

RUN if [ "$TARGETARCH" = "amd64" ]; then ARCH="x64"; else ARCH="$TARGETARCH"; fi && \
    curl -o runner.tar.gz -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz" && \
    tar xzf ./runner.tar.gz && \
    rm runner.tar.gz

# P2: Final image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERRAFORM_VERSION=1.14.9
ENV ANSIBLE_VERSION=11.3.0
ENV ANSIBLE_CORE_VERSION=2.18.6

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    jq \
    tar \
    unzip \
    gnupg \
    ca-certificates \
    openssh-client \
    software-properties-common \
    lsb-release \
    python3-pip \
    python3-venv \
    libicu-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y "terraform=${TERRAFORM_VERSION}*" \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages "ansible==${ANSIBLE_VERSION}" "ansible-core==${ANSIBLE_CORE_VERSION}"

RUN useradd -m runner && \
    usermod -aG sudo runner && \
    echo "%sudo ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/runner
COPY --from=builder --chown=runner:runner /actions-runner .
COPY --chown=runner:runner entrypoint.sh .
RUN chmod +x entrypoint.sh

USER runner

ENTRYPOINT ["./entrypoint.sh"]
