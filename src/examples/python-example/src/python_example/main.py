"""Minimal FastAPI app — the kind of dev server llm-docker's `/run` endpoint
spins up. Bind to 0.0.0.0 so containers can reach it via host.docker.internal."""

from fastapi import FastAPI

app = FastAPI(title="python-example")


@app.get("/")
async def root() -> dict[str, str]:
    return {"hello": "from python-example", "stack": "fastapi"}


@app.get("/health")
async def health() -> dict[str, bool]:
    return {"ok": True}
