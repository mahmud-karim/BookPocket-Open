from pathlib import Path
from pydantic import BaseModel, Field
import os
import secrets

class Config(BaseModel):
    data_dir: Path = Field(default_factory=lambda: Path(os.environ.get("LOCALAPPDATA", Path.home() / ".local/share")) / "BookPocketOpen")
    admin_token: str = Field(default_factory=lambda: secrets.token_urlsafe(32), repr=False)
    port: int = 8783
    studio_port: int = 8782
    public_url: str = "https://localhost:8783"
    dev: bool = False
    studio_dir: Path | None = None
    voicestudio_url: str | None = None
    max_import_bytes: int = 100 * 1024 * 1024
    certificate_sha256: str | None = None
    ffmpeg: str = "ffmpeg"

class Pronunciation(BaseModel):
    term: str = Field(min_length=1, max_length=256)
    replacement: str = Field(max_length=1024)
    enabled: bool = True

class GenerationRequest(BaseModel):
    request_id: str = Field(min_length=1, max_length=128)
    book_id: str
    segment_ids: list[str] = Field(min_length=1, max_length=100000)
    engine: str
    voice_id: str
    language: str = "en"
    pronunciation_rules: list[Pronunciation] = Field(default_factory=list, max_length=1000)
    announce_chapters: bool = False
    cast: dict[str, str] = Field(default_factory=dict)
    narration_plan: list["NarrationSpan"] = Field(default_factory=list)

class NarrationSpan(BaseModel):
    segment_id: str
    start_offset: int = Field(ge=0)
    end_offset: int = Field(gt=0)
    voice_id: str

GenerationRequest.model_rebuild()

class PairRequest(BaseModel):
    code: str = Field(min_length=8, max_length=64)
    device_name: str = Field(min_length=1, max_length=120)

class ExportRequest(BaseModel):
    format: str = Field(pattern="^(m4b|mp3|project)$")
