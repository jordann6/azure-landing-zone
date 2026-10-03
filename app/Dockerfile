FROM python:3.12-slim-bookworm

# Microsoft ODBC Driver 18: supports Entra managed identity authentication
# (Authentication=ActiveDirectoryMsi), so the app never holds a SQL password.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg2 unixodbc ca-certificates \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list -o /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
 && apt-get purge -y curl gnupg2 \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
COPY static/ static/

# Non-root, so the app listens on 8080 rather than a privileged port.
RUN useradd --uid 10001 --no-create-home appuser
USER 10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/livez')"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers"]
