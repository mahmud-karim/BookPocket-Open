"""Original Unicode quote ranges; ambiguous paragraphs stay explicitly reviewable."""
import re

_PAIRS = {'“': '”', '"': '"', '«': '»', '„': '“'}
_INNER = {'‘': '’', "'": "'", '‹': '›'}
_ELISIONS = {'bout', 'cause', 'cept', 'course', 'em', 'fessed', 'gainst', 'kay', 'nother',
             'round', 'scuse', 'til', 'tis', 'twas', 'tween', 'twere', 'twould', 'un', 'uns'}


def apostrophe(text, offset):
    if text[offset] not in {"'", '’'}: return False
    before, after = text[:offset], text[offset+1:]
    if before and after and before[-1].isalnum() and after[0].isalnum(): return True
    if re.search(r'\b[^\W\d_]+s$', before, re.IGNORECASE) and re.match(r'\s+[^\W\d_]', after): return True
    # Leading elisions are words, including the right curly mark in ’Course.
    # Do not classify arbitrary opening single quotes as elisions.
    if not before or not before[-1].isalnum():
        word = re.match(r'([^\W\d_]+|\d{2}(?:s)?)', after, re.UNICODE)
        if word and (word[0].casefold() in _ELISIONS or word[0][0].isdigit()):
            if text[offset] == "'" and re.match(r"[^\s']*'", after): return False
            return True
    if re.search(r'\b[^\W\d_]+in$', before, re.IGNORECASE) and re.match(r'\s+[^\W\d_]', after): return True
    return False


def scan_dialogue(segments):
    units, issues = [], []
    for segment in segments:
        text, identity = segment['text'], segment['segment_id']
        stack, start, local, error = [], None, [], None
        for offset, char in enumerate(text):
            if apostrophe(text, offset):
                # A closing nested single quote wins over the possessive or
                # dropped-g heuristic unless another matching close follows
                # before the outer close. Word-internal and leading elisions
                # remain apostrophes even within quoted dialogue.
                nested_close = len(stack) > 1 and char == stack[-1][1]
                trailing_word = offset and text[offset-1].isalnum() and offset+1 < len(text) and text[offset+1].isspace()
                if not (nested_close and trailing_word): continue
                remainder = text[offset+1:]
                next_inner, next_outer = remainder.find(char), remainder.find(stack[-2][1])
                if next_inner >= 0 and (next_outer < 0 or next_inner < next_outer): continue
            if stack:
                opening, closing = stack[-1]
                if char == closing:
                    # Symmetric nested double quotes have a visible opening
                    # boundary, e.g. "She said "go."".
                    nested = char == '"' and offset and text[offset-1].isspace() and offset+1 < len(text) and text[offset+1].isalnum()
                    if nested: stack.append((char, char)); continue
                    stack.pop()
                    if not stack:
                        local.append({'segment_id': identity, 'start_offset': start, 'end_offset': offset+1,
                                      'source_text': text[start:offset+1]})
                        start = None
                elif char in _PAIRS or char in _INNER:
                    stack.append((char, (_PAIRS | _INNER)[char]))
                elif char in {'”', '»', '’', '›'}:
                    error = 'Mismatched nested quotation marks need a speaker review'; break
            elif char in _PAIRS:
                start = offset
                stack.append((char, _PAIRS[char]))
            elif char in {'‘', '‹', "'"}:
                error = 'Single-quoted dialogue needs a speaker review'; break
            elif char in {'”', '»', '’', '›'}:
                error = 'Unmatched closing quotation mark needs a speaker review'; break
        if stack: error = error or 'Unbalanced or multi-paragraph quotation needs a speaker review'
        if not error and not local and re.match(r'^\s*(?:[A-Z][A-Z0-9 _.-]{1,80}:\s+|[—–-]\s*\S)', text):
            error = 'Unquoted script or dash dialogue needs a speaker review'
        if error:
            if text:
                issues.append({'segment_id': identity, 'start_offset': 0, 'end_offset': len(text),
                               'reason': 'ambiguous_quotation', 'message': error})
        else:
            units.extend(local)
    for index, unit in enumerate(units): unit['utterance_id'] = f'u{index:05d}'
    return units, issues
