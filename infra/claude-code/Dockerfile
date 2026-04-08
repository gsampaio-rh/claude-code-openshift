FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0
RUN dnf install -y git && dnf clean all

USER 1001

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/opt/app-root/src/.local/bin:$PATH"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-logged /usr/local/bin/claude-logged

WORKDIR /opt/app-root/src

USER 0
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-logged
USER 1001

CMD ["/usr/local/bin/entrypoint.sh"]
