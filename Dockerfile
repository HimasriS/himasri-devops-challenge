FROM python:3.9-slim@sha256:2d97f6910b16bd338d3060f261f53f144965f755599aab1acda1e13cf1731b1b

WORKDIR /app

# Create a non-root system user (fixes: container ran as root)
RUN addgroup --system appgroup && adduser --system --ingroup appgroup --no-create-home appuser

# Upgrade pip, setuptools, and wheel to patched versions
# This fixes CVE-2026-24049 (wheel) and CVE-2026-23949 (jaraco.context via setuptools)
RUN pip install --no-cache-dir --upgrade pip setuptools==80.7.1 wheel==0.46.2

COPY app/requirements.txt .
RUN pip install -r requirements.txt

COPY app/ /app/

# Give the non-root user ownership of the app directory
RUN chown -R appuser:appgroup /app

# Switch to non-root user before running the app
USER appuser

# Port 8080 does not require root privileges (port 80 does)
EXPOSE 8080

CMD ["python", "main.py"]
