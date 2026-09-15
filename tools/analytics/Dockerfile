FROM python:3.12-slim
WORKDIR /worker
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY sync.py .
USER 65534:65534
CMD ["python", "sync.py"]
