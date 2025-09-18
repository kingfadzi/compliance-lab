FROM python:3.11-slim

# Security: Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Install dependencies
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Security: Change ownership and switch to non-root user
RUN chown -R appuser:appuser /app
USER appuser

# Expose HTTPS port
EXPOSE 443

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('https://localhost:443/health', verify=False)" || exit 1

# Start application
CMD ["python", "app.py"]