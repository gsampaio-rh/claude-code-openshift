FROM registry.access.redhat.com/ubi9/nodejs-22

USER 0
RUN dnf install -y git && dnf clean all

USER 1001
WORKDIR /home/default

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/default/.local/bin:$PATH"

CMD ["sleep", "infinity"]
