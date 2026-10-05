"""Original CTC Viterbi forced alignment; no speech-text guessing or interpolation."""
import math
import re
import unicodedata


def english_number(value):
    ones = ('zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen').split()
    tens = ('zero ten twenty thirty forty fifty sixty seventy eighty ninety').split()
    if value < 20: return ones[value]
    if value < 100: return tens[value // 10] + (' ' + ones[value % 10] if value % 10 else '')
    if value < 1000: return ones[value // 100] + ' hundred' + (' ' + english_number(value % 100) if value % 100 else '')
    for scale, name in ((10**12, 'trillion'), (10**9, 'billion'), (10**6, 'million'), (1000, 'thousand')):
        if value >= scale: return english_number(value // scale) + ' ' + name + (' ' + english_number(value % scale) if value % scale else '')


def lexical_words(text):
    """Preserve scalar source spans, including accents, contractions and numbers."""
    result = []
    for match in re.finditer(r"(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?!\w)|[^\W_]+(?:['’][^\W_]+)*", text, re.UNICODE):
        original = match.group()
        numeric = original.replace(',', '')
        if numeric.isascii() and re.fullmatch(r'\d+(?:\.\d+)?', numeric):
            integer, _, fraction = numeric.partition('.')
            if len(integer) > 12 or len(fraction) > 12: raise ValueError('An unusually long number needs a pronunciation correction before alignment')
            normalized = english_number(int(integer))
            if fraction: normalized += ' point ' + ' '.join(english_number(int(digit)) for digit in fraction)
        else:
            normalized = unicodedata.normalize('NFKD', original.replace('’', "'")).encode('ascii', 'ignore').decode().upper()
        if not normalized or re.search(r"[^A-Z' ]", normalized.upper()):
            raise ValueError('Word alignment currently supports English words; add a pronunciation correction for unsupported text')
        result.append((match.start(), match.end(), normalized.upper()))
    if not result: raise ValueError('No English words were found to align')
    return result


def force_align(log_probs, targets, blank=0):
    """Most likely full CTC path, with mandatory blank between repeated labels.

    Input is actual per-frame acoustic log probabilities. Memory is bounded by
    frames * states byte backpointers; only two score rows are retained.
    """
    import numpy as np
    probabilities = np.asarray(log_probs, dtype=np.float32)
    if probabilities.ndim != 2 or not np.isfinite(probabilities).all(): raise ValueError('Invalid acoustic emissions')
    frames, vocabulary = probabilities.shape
    if not targets or any(type(t) is not int or t == blank or not 0 <= t < vocabulary for t in targets): raise ValueError('Invalid CTC transcript')
    labels = np.full(2 * len(targets) + 1, blank, dtype=np.int64)
    labels[1::2] = targets
    states = len(labels)
    if frames * states > 40_000_000: raise ValueError('Passage is too large for bounded word alignment')
    scores = np.full(states, -np.inf, dtype=np.float32)
    scores[0] = probabilities[0, blank]
    scores[1] = probabilities[0, targets[0]]
    trace = np.zeros((frames, states), dtype=np.uint8)
    skip = np.zeros(states, dtype=bool)
    skip[2:] = (labels[2:] != blank) & (labels[2:] != labels[:-2])
    for frame in range(1, frames):
        stay = scores
        step = np.concatenate(([-np.inf], scores[:-1]))
        jump = np.concatenate(([-np.inf, -np.inf], scores[:-2]))
        jump[~skip] = -np.inf
        choices = np.stack((stay, step, jump))
        selected = np.argmax(choices, axis=0)
        trace[frame] = selected
        scores = choices[selected, np.arange(states)] + probabilities[frame, labels]
    state = states - 1 if scores[-1] >= scores[-2] else states - 2
    if not math.isfinite(float(scores[state])): raise ValueError('Audio is too short for the supplied words')
    path = np.empty(frames, dtype=np.int64)
    for frame in range(frames - 1, -1, -1):
        path[frame] = state
        if frame: state -= int(trace[frame, state])
    if state not in {0, 1}: raise ValueError('Incomplete forced alignment')
    spans = []
    for index, target in enumerate(targets):
        hits = np.flatnonzero(path == 2 * index + 1)
        if not len(hits): raise ValueError('A supplied character could not be aligned')
        confidence = float(np.exp(probabilities[hits, target]).mean())
        spans.append((int(hits[0]), int(hits[-1]) + 1, confidence))
    return spans
