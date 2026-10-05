from pathlib import Path
from pydantic import BaseModel, Field, model_validator
from typing import Literal
import os
import secrets

class Config(BaseModel):
    data_dir: Path = Field(default_factory=lambda: Path(os.environ.get("LOCALAPPDATA", Path.home() / ".local/share")) / "BookPocketOpen")
    admin_token: str = Field(default_factory=lambda: secrets.token_urlsafe(32), repr=False)
    port: int = 8783
    studio_port: int = 8782
    public_url: str = "https://localhost:8783"
    public_tls_mode: Literal["pinned", "system"] = "pinned"
    phone_gateway_port: int | None = Field(default=None, ge=1, le=65535, strict=True)
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

class PronunciationSettings(BaseModel):
    pronunciation_rules: list[Pronunciation] = Field(max_length=1000)
    expected_revision: int = Field(ge=0, strict=True)

class SourceRange(BaseModel):
    segment_id: str
    start_offset: int = Field(ge=0, strict=True)
    end_offset: int = Field(gt=0, strict=True)

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
    narration_mode: Literal["single", "full_cast"] = "single"
    source_ranges: list[SourceRange] = Field(default_factory=list, max_length=100000)
    take_id: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    @model_validator(mode="before")
    @classmethod
    def infer_legacy_mode(cls, value):
        if isinstance(value, dict):
            value = {**value, "narration_mode": narration_mode(value)}
        return value

class NarrationSpan(BaseModel):
    segment_id: str
    start_offset: int = Field(ge=0, strict=True)
    end_offset: int = Field(gt=0, strict=True)
    voice_id: str

GenerationRequest.model_rebuild()


def narration_mode(value, fallback="single"):
    inferred = "full_cast" if value.get("cast") or value.get("narration_plan") or value.get("cast_spans") else fallback
    mode = value.get("narration_mode", inferred)
    if not isinstance(mode, str) or mode not in {"single", "full_cast"} or (mode == "single" and inferred == "full_cast"):
        raise ValueError("Cast narration requires narration_mode full_cast")
    return mode


def job_metadata(job, request):
    mode = narration_mode(request)
    return {**job, "narration_mode": mode, "narration_plan": request.get("narration_plan", []), "cast": request.get("cast", {}),
            "assets": [{**asset, "narration_mode": narration_mode(asset, mode)} for asset in job.get("assets", [])]}


def validate_narration_plan(plan, segment_ids, lengths, source_ranges=()):
    if not isinstance(plan, list) or len(plan) > 100000:
        raise ValueError("Narration plan must be a list containing at most 100,000 intervals")
    for value in plan:
        if (not isinstance(value, dict) or not {"segment_id", "start_offset", "end_offset", "voice_id"} <= value.keys()
                or not isinstance(value["segment_id"], str) or not isinstance(value["voice_id"], str) or not value["voice_id"]
                or type(value["start_offset"]) is not int or type(value["end_offset"]) is not int):
            raise ValueError("Each narration span requires a segment, voice and integer scalar bounds")
    scopes = {scope["segment_id"]: (scope["start_offset"], scope["end_offset"]) for scope in source_ranges}
    previous = {}
    selected = set(segment_ids)
    for value in sorted(plan, key=lambda span: (span["segment_id"], span["start_offset"])):
        identity, start, end = value["segment_id"], value["start_offset"], value["end_offset"]
        low, high = scopes.get(identity, (0, lengths.get(identity, 0)))
        if identity not in selected or not low <= start < end <= high or start < previous.get(identity, low):
            raise ValueError("Narration spans must be non-overlapping scalar ranges inside the selected source ranges")
        previous[identity] = end


def validate_source_ranges(ranges, segment_ids, lengths):
    """Validate persisted or wire source scopes without changing source identity."""
    if not isinstance(ranges, list) or len(ranges) > 100000:
        raise ValueError("Source ranges must be a list containing at most 100,000 intervals")
    if not ranges: return
    for value in ranges:
        if (not isinstance(value, dict) or not {"segment_id", "start_offset", "end_offset"} <= value.keys()
                or not isinstance(value["segment_id"], str) or not value["segment_id"]):
            raise ValueError("Each source range requires a segment_id, start_offset, and end_offset")
    identities = [value["segment_id"] for value in ranges]
    if len(identities) != len(set(identities)) or set(identities) != set(segment_ids):
        raise ValueError("Source ranges must cover every selected segment exactly once")
    for value in ranges:
        start, end = value["start_offset"], value["end_offset"]
        if type(start) is not int or type(end) is not int or not 0 <= start < end <= lengths.get(value["segment_id"], 0):
            raise ValueError("Source ranges must be nonempty Unicode scalar intervals inside their original segments")

class PairRequest(BaseModel):
    code: str = Field(min_length=8, max_length=64)
    device_name: str = Field(min_length=1, max_length=120)

class ExportRequest(BaseModel):
    format: str = Field(pattern="^(m4b|mp3|project)$")
    include_voice_references: bool = False
