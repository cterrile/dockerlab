FROM ghcr.io/dagucloud/dagu:2.8.2

USER root

ENV ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/collections
ENV PATH="/opt/ansible/bin:${PATH}"

COPY stacks/dagu/scripts/write-ssh-key.py /usr/local/bin/write-ssh-key.py
COPY ansible/requirements.yml /tmp/ansible-requirements.yml

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
    && mkdir -p /opt/ansible/collections \
    && /opt/ansible/bin/ansible-galaxy collection install \
        -r /tmp/ansible-requirements.yml \
        -p /opt/ansible/collections \
    && chown -R 1000:1000 /opt/ansible/collections \
    && rm /tmp/ansible-requirements.yml \
    && curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | bash \
    && apt-get install -y infisical \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/custom-init.d /workspace \
    && printf '%s\n' \
        '#!/bin/sh' \
        'mkdir -p /workspace' \
        'chown -R "${PUID}:${PGID}" /workspace' \
        > /etc/custom-init.d/01-workspace-perms.sh \
    && chmod +x /etc/custom-init.d/01-workspace-perms.sh \
    && ln -sf /opt/ansible/bin/ansible /usr/local/bin/ansible \
    && ln -sf /opt/ansible/bin/ansible-playbook /usr/local/bin/ansible-playbook \
    && ln -sf /opt/ansible/bin/ansible-galaxy /usr/local/bin/ansible-galaxy \
    && chmod +x /usr/local/bin/write-ssh-key.py
