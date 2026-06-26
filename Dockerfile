FROM python:3.10-slim

# Install system build dependencies required for compiling ML wheels
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and install
COPY backend/requirements.txt .

# Install dependencies in two stages to optimize memory usage
RUN grep -v "prophet" requirements.txt > requirements_no_prophet.txt && \
    pip install --no-cache-dir -r requirements_no_prophet.txt && \
    rm requirements_no_prophet.txt

RUN pip install --no-cache-dir prophet==1.3.0

# Pre-install CmdStan during the build so it is ready at runtime
RUN python -c "import cmdstanpy; cmdstanpy.install_cmdstan(compiler=False)" || true

# Copy backend source
COPY backend/ ./backend/

# Expose port
EXPOSE 8000

# Start server
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
