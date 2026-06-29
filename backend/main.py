from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from routers import ai, map  # noqa: F401 – 'map' shadows builtin, intentional

app = FastAPI(title="CEA API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ai.router, prefix="/ai", tags=["ai"])
app.include_router(map.router, prefix="/map", tags=["map"])


@app.get("/ping")
async def ping():
    return {"status": "ok"}
