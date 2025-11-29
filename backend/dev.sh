#!/usr/bin/env bash
set -e

# Always run from the backend directory
cd "$(dirname "$0")"

# Create virtualenv if it doesn't exist
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

# Activate virtualenv
. .venv/bin/activate

# Ensure dependencies (including openai) are installed/updated
pip install --upgrade pip
pip install -r requirements.txt

# Use SQLite for local dev
export DATABASE_URL="sqlite:///./dev.db"
export APP_DEBUG="true"
export FRONTEND_ORIGIN=${FRONTEND_ORIGIN:-http://localhost:3001}
export BACKEND_HOST=${BACKEND_HOST:-127.0.0.1}
export BACKEND_PORT=${BACKEND_PORT:-8000}

echo "Starting backend on $BACKEND_HOST:$BACKEND_PORT"

exec uvicorn app.main:app --reload --host "$BACKEND_HOST" --port "$BACKEND_PORT"






