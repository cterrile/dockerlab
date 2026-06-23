FROM nousresearch/hermes-agent:v2026.6.19

USER root

ENV OPENCODE_DISABLE_AUTOUPDATE=true

RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
    && install -m 755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && rm -rf /root/.opencode \
    && opencode --version
