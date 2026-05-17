FROM ghcr.io/dagucloud/dagu:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        openssh-client \
        rsync \
        git \
        curl \
        gnupg \
        ca-certificates \
    && python3 -m venv /opt/ansible \
    && /opt/ansible/bin/pip install --no-cache-dir \
        ansible-core \
        jmespath \
    && /opt/ansible/bin/ansible-galaxy collection install \
        community.docker \
        ansible.posix \
    && curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | bash \
    && apt-get install -y infisical \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global --add safe.directory /home/deploy/dockerlab

ENV PATH="/opt/ansible/bin:${PATH}"
