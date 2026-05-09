FROM python:3.9-slim@sha256:2d97f6910b16bd338d3060f261f53f144965f755599aab1acda1e13cf1731b1b

WORKDIR /app

# Create a non-root system user (fixes: container ran as root)
RUN addgroup --system appgroup && adduser --system --ingroup appgroup --no-create-home appuser

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
