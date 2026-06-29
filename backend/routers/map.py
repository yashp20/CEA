from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()


class Location(BaseModel):
    latitude: float
    longitude: float
    label: str


@router.get("/pins", response_model=list[Location])
async def get_pins():
    # Replace with real data source
    return [
        Location(latitude=40.7128, longitude=-74.0060, label="New York"),
        Location(latitude=34.0522, longitude=-118.2437, label="Los Angeles"),
    ]
