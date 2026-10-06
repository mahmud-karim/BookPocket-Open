import pytest
from bookpocket_companion.quote_scanner import scan_dialogue


@pytest.mark.parametrize('elision', ['’Course', '’cause', '’Twas', "'Course", '’90s', '’fessed'])
def test_leading_elision_preserves_original_outer_span(elision):
    text = f'🧭 Mira said, “{elision}, we can keep the lantern.”'
    units, issues = scan_dialogue([{'segment_id': 's', 'text': text}])
    assert not issues and len(units) == 1
    unit = units[0]
    assert unit['source_text'] == text[text.index('“'):]
    assert text[unit['start_offset']:unit['end_offset']] == unit['source_text']


@pytest.mark.parametrize('quote', ['“She said ‘pilots’ maps.”', '“She said ‘the pilots’ maps are ready’.”',
                                  '«She said “Go ‘north’ now.”»', '“She said ‘go’.”', '"She said \'go\'."'])
def test_nested_quotes_are_one_outer_speaker_range(quote):
    units, issues = scan_dialogue([{'segment_id': 's', 'text': quote}])
    assert not issues and len(units) == 1
    assert units[0]['source_text'] == quote


def test_ambiguous_paragraph_does_not_discard_clean_original_dialogue():
    clean = 'Mira said, “’Course, the lantern is ready.”'
    unclear = 'Rowan said, “Keep walking. 🧭'
    units, issues = scan_dialogue([{'segment_id': 'clean', 'text': clean}, {'segment_id': 'unclear', 'text': unclear}])
    assert len(units) == len(issues) == 1
    assert units[0]['segment_id'] == 'clean'
    assert issues[0]['segment_id'] == 'unclear'
    assert issues[0]['start_offset'] == 0 and issues[0]['end_offset'] == len(unclear)
    assert issues[0]['reason'] == 'ambiguous_quotation'


@pytest.mark.parametrize('text', ['“Missing close', '“Bad ‘nested” close’', 'MIRA: Walk north.', '— Walk north.'])
def test_unsupported_marks_are_actionable_original_review_ranges(text):
    units, issues = scan_dialogue([{'segment_id': 's', 'text': text}])
    assert not units and len(issues) == 1
    assert 'review' in issues[0]['message']
    assert (issues[0]['start_offset'], issues[0]['end_offset']) == (0, len(text))
