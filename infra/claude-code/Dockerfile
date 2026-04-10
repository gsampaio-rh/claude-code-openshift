FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0
RUN dnf install -y git python3.12 python3.12-pip && dnf clean all

USER 1001

RUN curl -fsSL https://claude.ai/install.sh | bash
RUN python3.12 -m pip install --user --no-cache-dir 'mlflow>=3.10' 'opentelemetry-exporter-otlp-proto-http'
ENV PATH="/opt/app-root/src/.local/bin:$PATH"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-logged /usr/local/bin/claude-logged
# set-trace-tags.py is kept in-repo but not copied — disabled for PoC (ADR-020)

WORKDIR /opt/app-root/src

USER 0
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-logged && \
    chmod -R g+w /opt/app-root/src/.claude || true
USER 1001

CMD ["/usr/local/bin/entrypoint.sh"]
