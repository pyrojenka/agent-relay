FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first so code-only changes don't invalidate this layer.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY . .
RUN uv sync --frozen --no-dev

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

# uvicorn defaults to 127.0.0.1, which is unreachable from outside the
# container; bind 0.0.0.0 so -p port publishing works.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
