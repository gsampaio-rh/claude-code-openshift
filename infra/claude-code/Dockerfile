FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0
RUN dnf install -y git && dnf clean all

USER 1001

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/opt/app-root/src/.local/bin:$PATH"

WORKDIR /opt/app-root/src
CMD ["sleep", "infinity"]
