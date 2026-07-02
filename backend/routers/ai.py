import os
import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from dotenv import load_dotenv

load_dotenv()

router = APIRouter()

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_URL = "https://api.openai.com/v1/chat/completions"


class PromptRequest(BaseModel):
    prompt: str


class PromptResponse(BaseModel):
    response: str


@router.post("/ask", response_model=PromptResponse)
async def ask(body: PromptRequest):
    if not body.prompt.strip():
        raise HTTPException(status_code=400, detail="Prompt cannot be empty")
    if not OPENAI_API_KEY:
        raise HTTPException(status_code=500, detail="OPENAI_API_KEY is not set")

    payload = {
        "model": OPENAI_MODEL,
        "messages": [{"role": "user", "content": body.prompt}],
    }

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            OPENAI_URL,
            headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
            json=payload,
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"OpenAI error: {resp.text}")

    data = resp.json()
    try:
        text = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        raise HTTPException(status_code=502, detail="Unexpected OpenAI response")

    return PromptResponse(response=text)
