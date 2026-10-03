"""Independent metadata boundary checks; never start the endurance observer/model."""
import copy
import re

import pytest
from test_release_tools import module


@pytest.fixture
def timing_case():
    # Emoji before later words makes Unicode scalar positions differ from UTF-16.
    segment = {"text": "Mira 🧭 heard 12 café bells."}
    timings = [{"start": index * .25, "end": index * .25 + .2,
                "start_offset": word.start(), "end_offset": word.end()}
               for index, word in enumerate(re.finditer(r"\w+", segment["text"]))]
    asset = {"duration": 1.5, "source_start": 0, "source_end": len(segment["text"]),
             "alignment": "word", "timings": timings}
    return segment, asset


@pytest.mark.parametrize("alignment", ["word", "sentence"])
def test_realistic_word_and_sentence_ranges_cover_original_unicode_source(timing_case, alignment):
    segment, asset = timing_case
    asset["alignment"] = alignment
    if alignment == "sentence":
        asset["timings"] = [{"start": .05, "end": 1.45, "start_offset": 0, "end_offset": len(segment["text"])}]
    before = copy.deepcopy((segment, asset))
    module("audit_render_timings").validate_timing(segment, asset)
    assert (segment, asset) == before, "Timing validation must not rewrite observed metadata"


@pytest.mark.parametrize("duration", [float("nan"), float("inf"), -float("inf"), 0, -1])
def test_rejects_nonfinite_or_nonpositive_recording_duration(timing_case, duration):
    segment, asset = timing_case
    asset["duration"] = duration
    with pytest.raises(AssertionError, match="Invalid asset duration"):
        module("audit_render_timings").validate_timing(segment, asset)


@pytest.mark.parametrize("field", ["start", "end"])
@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf")])
def test_rejects_nonfinite_audio_timestamps(timing_case, field, value):
    segment, asset = timing_case
    asset["timings"][0][field] = value
    with pytest.raises(AssertionError, match="Nonfinite audio timing"):
        module("audit_render_timings").validate_timing(segment, asset)


@pytest.mark.parametrize("start,end", [(-.001, .2), (.2, .1), (0, 1.501)])
def test_rejects_negative_reversed_or_out_of_duration_audio(timing_case, start, end):
    segment, asset = timing_case
    asset["timings"][0].update(start=start, end=end)
    with pytest.raises(AssertionError, match="Timing outside audio"):
        module("audit_render_timings").validate_timing(segment, asset)


@pytest.mark.parametrize("overlap,allowed", [(.05, True), (.051, False)])
def test_model_overlap_has_an_explicit_fifty_millisecond_boundary(overlap, allowed):
    segment = {"text": "One two"}
    asset = {"duration": 1, "source_start": 0, "source_end": 7, "alignment": "word", "timings": [
        {"start": 0, "end": .5, "start_offset": 0, "end_offset": 3},
        {"start": .5 - overlap, "end": 1, "start_offset": 4, "end_offset": 7},
    ]}
    validate = module("audit_render_timings").validate_timing
    if allowed:
        validate(segment, asset)
    else:
        with pytest.raises(AssertionError, match="Nonmonotonic audio timing"):
            validate(segment, asset)


def test_rejects_source_offsets_that_move_back_into_previous_word(timing_case):
    segment, asset = timing_case
    asset["timings"][1]["start_offset"] = 1
    with pytest.raises(AssertionError, match="Nonmonotonic source timing"):
        module("audit_render_timings").validate_timing(segment, asset)


def test_rejects_omitted_source_word_even_when_remaining_intervals_are_valid(timing_case):
    segment, asset = timing_case
    asset["timings"].pop(2)  # Omit the numeric word "12"; all other ranges remain valid and ordered.
    with pytest.raises(AssertionError, match="Uncovered source letters or numbers: 2"):
        module("audit_render_timings").validate_timing(segment, asset)


def test_rejects_missing_timing_metadata(timing_case):
    segment, asset = timing_case
    asset["timings"] = []
    with pytest.raises(AssertionError, match="Missing timing metadata"):
        module("audit_render_timings").validate_timing(segment, asset)
