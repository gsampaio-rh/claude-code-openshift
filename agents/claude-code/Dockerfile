FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0
RUN dnf install -y git python3.12 python3.12-pip && dnf clean all
RUN curl -fsSL -o /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 && \
    chmod +x /usr/local/bin/ttyd

USER 1001

RUN curl -fsSL https://claude.ai/install.sh | bash
RUN git clone --depth 1 https://github.com/gsampaio-rh/rules-skills.git /opt/app-root/rules-skills
RUN python3.12 -m pip install --user --no-cache-dir 'mlflow>=3.10' 'opentelemetry-exporter-otlp-proto-http'
ENV PATH="/opt/app-root/src/.local/bin:$PATH"

COPY --chown=1001:0 mcp/ /opt/app-root/mcp/
RUN cd /opt/app-root/mcp && npm install --omit=dev

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-logged /usr/local/bin/claude-logged
COPY hooks/ /opt/app-root/hooks/

WORKDIR /opt/app-root/src

USER 0
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-logged /opt/app-root/hooks/*.sh && \
    chmod -R g+w /opt/app-root/src/.claude || true
USER 1001

CMD ["/usr/local/bin/entrypoint.sh"]
