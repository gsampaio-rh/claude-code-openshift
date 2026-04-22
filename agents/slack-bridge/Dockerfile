FROM registry.access.redhat.com/ubi9/python-312

USER 1001

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

CMD ["python", "src/bridge.py"]
