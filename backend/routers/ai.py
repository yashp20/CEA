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

# The AI's persona and instructions — sent with every request so it knows
# who it is and how to answer. Edit this to change CEA's behaviour.
SYSTEM_PROMPT = """You are CEA, a friendly AI assistant built into an \
accessibility app for people with disabilities (vision, hearing, mobility, \
cognitive needs, and allergies).

How to respond:
- Be warm, concise, and direct. Prefer short, clear answers and step-by-step \
instructions.
- Actually try to help with the request. Do NOT tell the user to "check \
online", "consult an app", or "contact support" unless it is truly necessary.
- If a task needs an action you can't perform yet (like ordering food or \
booking a ride), explain clearly what you would do and what info you'd need, \
rather than refusing.
- Keep accessibility in mind: avoid describing things by color alone, and \
write in plain, easy-to-read language."""


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
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": body.prompt},
        ],
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
