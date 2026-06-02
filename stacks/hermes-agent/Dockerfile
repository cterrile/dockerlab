FROM nousresearch/hermes-agent:latest

USER root

ENV OPENCODE_DISABLE_AUTOUPDATE=true

RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
    && install -m 755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && rm -rf /root/.opencode \
    && opencode --version
