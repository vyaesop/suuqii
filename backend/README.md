# Suuqii backend

FastAPI + async SQLAlchemy + Neon Postgres.

## Run locally

```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # or `.venv\Scripts\activate` on PS
pip install -e ".[dev]"
cp .env.example .env                                 # set DATABASE_URL + JWT_SECRET
alembic upgrade head
uvicorn app.main:app --reload
```

Open `http://localhost:8000/docs` for the OpenAPI explorer.

## Layout

```
app/
├── main.py             # FastAPI app factory
├── core/               # config, security, deps, errors
├── db/                 # SQLAlchemy base + session
├── models/             # ORM tables
├── schemas/            # Pydantic DTOs
├── services/           # business logic (sync_service, shift_service, ...)
└── api/v1/             # FastAPI routers per feature
```

## Tests

```bash
pytest
```
Uses `testcontainers[postgres]` to spin up an isolated DB per test session.

## Deploy (Vercel)

```bash
vercel link
vercel env pull .env
alembic upgrade head        # against the production DB
vercel deploy --prod
```

See [../docs/14-deployment.md](../docs/14-deployment.md) for the full path.
