from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()


class PromptRequest(BaseModel):
    prompt: str


class PromptResponse(BaseModel):
    response: str


@router.post("/ask", response_model=PromptResponse)
async def ask(body: PromptRequest):
    # Placeholder — wire up an AI SDK here when you have an API key
    return PromptResponse(response=f"Echo: {body.prompt}")
