# Phase 1 Setup Guide

## Prerequisites
- Python 3.10.11
- Flutter 3.44.8+
- PostgreSQL (for production; SQLite used in development/testing)

## Backend Setup

```bash
cd new_app/backend

# Create virtual environment
python -m venv .venv
.venv\Scripts\activate  # Windows

# Install dependencies
pip install -e ".[dev]"

# Run tests
python -m pytest tests/ -v

# Start development server
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# Run linter
ruff check app/ tests/

# Run type checker
mypy app/
```

## Flutter Setup

```bash
cd new_app

# Get dependencies
flutter pub get

# Run tests
flutter test test/unit/ test/widget/

# Run analyzer
dart analyze lib/

# Run app (Windows)
flutter run -d windows
```

## Environment Variables

Copy `.env.example` to `.env` and configure:

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_ENV` | Environment (dev/prod/test) | dev |
| `DATABASE_URL` | PostgreSQL connection string | sqlite:///./app.db |
| `JWT_SECRET_KEY` | Secret for JWT signing | (must set) |
| `JWT_ALGORITHM` | JWT algorithm | HS256 |
| `JWT_ACCESS_TOKEN_EXPIRE_MINUTES` | Token TTL | 480 |

## First Run

1. Start PostgreSQL (or use SQLite for dev)
2. Run backend: `uvicorn app.main:app --reload`
3. Visit API docs: http://localhost:8000/docs
4. Check health: http://localhost:8000/health
5. Run Flutter app: `flutter run -d windows`
