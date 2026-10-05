"""CPU acoustic model process, executed in an installed isolated interpreter."""
import json
import math
import sys
from contextlib import redirect_stdout
from pathlib import Path
from ctc_alignment import force_align, lexical_words

model = processor = None


def align(data):
    global model, processor
    import numpy as np
    import torch
    import soundfile as sf
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
    if data.get('language', 'en') != 'en': raise ValueError('Word alignment currently supports English')
    if model is None:
        # Alignment is CPU work; never claim the synthesis GPU while decoding.
        torch.set_num_threads(min(4, torch.get_num_threads()))
        processor = Wav2Vec2Processor.from_pretrained(data['model'], local_files_only=True)
        model = Wav2Vec2ForCTC.from_pretrained(data['model'], local_files_only=True, use_safetensors=True).eval()
    if data.get('probe'): return {'validated_model': True}
    audio, sample_rate = sf.read(data['audio'], dtype='float32', always_2d=False)
    if sample_rate != 16000 or audio.ndim != 1 or not 160 <= len(audio) <= 16000 * 120:
        raise ValueError('Alignment requires mono 16 kHz audio up to two minutes per passage')
    if not np.isfinite(audio).all() or float(np.max(np.abs(audio))) < 0.0001:
        raise ValueError('The recording contains no speech to align')
    words = lexical_words(data['text'])
    text = '|'.join(value[2].replace(' ', '|') for value in words)
    vocabulary = processor.tokenizer.get_vocab()
    if any(letter not in vocabulary for letter in text): raise ValueError('Unsupported characters in spoken pronunciation')
    targets = [vocabulary[letter] for letter in text]
    inputs = processor(audio, sampling_rate=16000, return_tensors='pt').input_values
    with torch.inference_mode(): emissions = model(inputs).logits[0].log_softmax(-1).numpy()
    aligned = force_align(emissions, targets, processor.tokenizer.pad_token_id)
    cursor, result = 0, []
    seconds_per_frame = len(audio) / 16000 / len(emissions)
    for start, end, normalized in words:
        length = len(normalized)
        characters = aligned[cursor:cursor + length]
        confidence = math.exp(sum(math.log(max(value[2], 1e-12)) for value in characters) / len(characters))
        # Silence or unrelated speech must not become a claimed word track.
        if confidence < .08 or any(value[2] < .005 for value in characters):
            raise ValueError('The supplied words do not confidently match the recording')
        result.append({'text': data['text'][start:end], 'start': characters[0][0] * seconds_per_frame,
                       'end': characters[-1][1] * seconds_per_frame, 'confidence': confidence})
        cursor += length + 1
    return {'words': result}


def main():
    for line in sys.stdin:
        try:
            data = json.loads(line)
            with redirect_stdout(sys.stderr): result = align(data)
            print(json.dumps({'ok': True, **result}), flush=True)
        except Exception as exc:
            print(json.dumps({'ok': False, 'error': str(exc)[:1500]}), flush=True)
            if data.get('probe'): raise


if __name__ == '__main__': main()
