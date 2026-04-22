FROM registry.access.redhat.com/ubi9/nodejs-22-minimal

USER 0
RUN microdnf install -y git && microdnf clean all
USER 1001

WORKDIR /opt/app-root/src
RUN npm install claude-task-viewer@latest

ENV PORT=3457 \
    HOST=0.0.0.0 \
    CLAUDE_DIR=/data/.claude

EXPOSE 3457

CMD ["npx", "claude-task-viewer", "--dir", "/data/.claude"]
