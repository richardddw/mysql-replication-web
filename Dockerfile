# Dockerfile
FROM python:3.11-slim

# 安装 mysql-client（包含 mysql 和 mysqldump）
RUN apt-get update && \
    apt-get install -y default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY scripts ./scripts

RUN chmod +x scripts/mysql_replication.sh

EXPOSE 8000
ENV MYSQL_SSL_MODE=PREFERRED
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
