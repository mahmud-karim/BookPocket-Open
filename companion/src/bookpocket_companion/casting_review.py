"""Durable exact-source review with atomic speaker/voice choices and retry identity."""
import json
import uuid
from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field
from .quote_scanner import scan_dialogue
from .store import canonical, digest
from .casting import Character


class ReviewRange(BaseModel):
    start_offset: int = Field(ge=0, strict=True)
    end_offset: int = Field(gt=0, strict=True)
    character_id: str = Field(min_length=1, max_length=100)


class ReviewResolution(BaseModel):
    request_id: uuid.UUID
    expected_revision: int = Field(ge=0, strict=True)
    character_id: str = Field(min_length=1, max_length=100)
    voice_id: str | None = None
    new_character: Character | None = None
    ranges: list[ReviewRange] | None = Field(default=None, min_length=1, max_length=1000)


def reviewed_cover(issue, cast):
    position = issue['start_offset']
    for a in sorted(cast.assignments, key=lambda a: a.start_offset):
        if a.segment_id != issue['segment_id'] or a.end_offset <= position: continue
        if not a.reviewed or a.start_offset > position: continue
        position = a.end_offset
        if position >= issue['end_offset']: return True
    return False


class CastReview:
    def __init__(self, store, get_book):
        self.store, self.get_book = store, get_book
        with store.db() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS cast_review_meta(book_id TEXT PRIMARY KEY,revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS cast_review_issues(id TEXT PRIMARY KEY,book_id TEXT NOT NULL,source_sha256 TEXT NOT NULL,data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS cast_review_requests(request_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,book_id TEXT NOT NULL,issue_id TEXT NOT NULL);''')

    def cast(self, db, book_id):
        from .casting import Cast, Character
        row = db.execute('SELECT data FROM casts WHERE book_id=?', (book_id,)).fetchone()
        return Cast.model_validate_json(row[0]) if row else Cast(characters=[Character(id='narrator', name='Narrator')])

    def revision(self, db, book_id):
        row = db.execute('SELECT revision FROM cast_review_meta WHERE book_id=?', (book_id,)).fetchone()
        return row[0] if row else 0

    def changed(self, db, book_id):
        db.execute('INSERT INTO cast_review_meta VALUES(?,1) ON CONFLICT(book_id) DO UPDATE SET revision=revision+1', (book_id,))

    def put_issue(self, db, book, chapter_id, value, issue_id=None):
        chapter = next(c for c in book['chapters'] if c['id'] == chapter_id)
        segment = next(s for s in chapter['segments'] if s['id'] == value['segment_id'])
        low, high = value['start_offset'], value['end_offset']
        if not 0 <= low < high <= len(segment['text']): raise ValueError('Review issue must identify an original source range')
        row = {**value, 'chapter_id': chapter_id, 'source_text': segment['text'][low:high]}
        row['id'] = issue_id or 'review:' + digest(canonical([book['id'], book['source_sha256'], chapter_id, value['segment_id'], low, high, value['reason']]))[:40]
        previous = db.execute('SELECT data FROM cast_review_issues WHERE id=?', (row['id'],)).fetchone()
        if not previous:
            db.execute('INSERT INTO cast_review_issues VALUES(?,?,?,?)', (row['id'], book['id'], book['source_sha256'], canonical(row)))
            self.changed(db, book['id'])

    def publish(self, db, book, chapter_id, cast, structural=()):
        for issue in structural: self.put_issue(db, book, chapter_id, issue)
        chapter_segments = {s['id'] for c in book['chapters'] if c['id'] == chapter_id for s in c['segments']}
        existing = [json.loads(r[0]) for r in db.execute('SELECT data FROM cast_review_issues WHERE book_id=? AND source_sha256=?', (book['id'], book['source_sha256']))]
        for a in cast.assignments:
            if a.reviewed or a.segment_id not in chapter_segments: continue
            covered = next((i for i in existing if i['segment_id'] == a.segment_id and i['start_offset'] <= a.start_offset and i['end_offset'] >= a.end_offset), None)
            if covered:
                if covered['reason'] in {'missing_assignment', 'analysis_failed'} and (covered['start_offset'], covered['end_offset']) == (a.start_offset, a.end_offset):
                    updated = {**covered, 'reason': 'unreviewed_assignment', 'message': 'Confirm who is speaking and choose their voice.', 'suggested_character_id': a.character_id}
                    if updated != covered:
                        db.execute('UPDATE cast_review_issues SET data=? WHERE id=?', (canonical(updated), covered['id']))
                        self.changed(db, book['id'])
                continue
            self.put_issue(db, book, chapter_id, {'segment_id': a.segment_id, 'start_offset': a.start_offset, 'end_offset': a.end_offset,
                           'reason': 'unreviewed_assignment', 'message': 'Confirm who is speaking and choose their voice.',
                           'suggested_character_id': a.character_id}, 'assignment:' + a.id)

    def sync(self, db, book, cast):
        from .casting import PROMPT_VERSION
        processed, failed_current = set(), set()
        for r in db.execute('SELECT data FROM analyses'):
            job = json.loads(r[0])
            if job.get('book_id') == book['id'] and job.get('source_sha256', book['source_sha256']) == book['source_sha256']:
                if job.get('status') not in {'queued', 'running'}:
                    processed.update(job.get('chapter_ids') or [c['id'] for c in book['chapters']])
                else:
                    processed.update(state['chapter_id'] for state in job.get('chapter_statuses', []) if state.get('status') in {'completed', 'failed'})
                if job.get('prompt_version') == PROMPT_VERSION:
                    for state in job.get('chapter_statuses', []):
                        if state.get('status') == 'failed': failed_current.add(state['chapter_id'])
                        elif state.get('status') == 'completed': failed_current.discard(state['chapter_id'])
        for chapter in book['chapters']:
            self.publish(db, book, chapter['id'], cast)
            if chapter['id'] not in processed: continue
            units, structural = scan_dialogue([{'segment_id': s['id'], 'text': s['text']} for s in chapter['segments'] if s.get('kind') != 'heading'])
            self.publish(db, book, chapter['id'], cast, structural)
            # Older failed analysis has no saved suggestions. Expose every
            # missing utterance for genuine manual coverage, never a ready flag.
            existing = [json.loads(r[0]) for r in db.execute('SELECT data FROM cast_review_issues WHERE book_id=? AND source_sha256=?', (book['id'], book['source_sha256']))]
            for unit in units:
                if any(a.segment_id == unit['segment_id'] and a.start_offset <= unit['start_offset'] and a.end_offset >= unit['end_offset'] for a in cast.assignments): continue
                covered = next((i for i in existing if i['segment_id'] == unit['segment_id'] and i['start_offset'] <= unit['start_offset'] and i['end_offset'] >= unit['end_offset']), None)
                reason = 'analysis_failed' if chapter['id'] in failed_current else 'missing_assignment'
                message = 'Automatic speaker analysis failed. Choose the speaker for this original passage.' if reason == 'analysis_failed' else 'Choose the speaker for this original passage.'
                if covered:
                    if covered['reason'] == 'missing_assignment' and reason == 'analysis_failed':
                        db.execute('UPDATE cast_review_issues SET data=? WHERE id=?', (canonical({**covered, 'reason': reason, 'message': message}), covered['id']))
                        self.changed(db, book['id'])
                    continue
                self.put_issue(db, book, chapter['id'], {k: unit[k] for k in ('segment_id','start_offset','end_offset')} |
                               {'reason': reason, 'message': message})

    def issues(self, db, book, cast):
        result = []
        for r in db.execute('SELECT data FROM cast_review_issues WHERE book_id=? AND source_sha256=? ORDER BY rowid', (book['id'], book['source_sha256'])):
            issue = json.loads(r[0])
            issue['status'] = 'resolved' if reviewed_cover(issue, cast) else 'pending'
            result.append(issue)
        return result

    def chapter_status(self, db, book, chapter_id, cast=None):
        cast = cast or self.cast(db, book['id'])
        issues = [i for i in self.issues(db, book, cast) if i['chapter_id'] == chapter_id]
        chapter = next(c for c in book['chapters'] if c['id'] == chapter_id)
        units, structural = scan_dialogue([{'segment_id': s['id'], 'text': s['text']} for s in chapter['segments'] if s.get('kind') != 'heading'])
        expected = [*units, *structural]
        manual = bool(expected) and all(reviewed_cover(span, cast) for span in expected)
        pending = sum(i['status'] == 'pending' for i in issues)
        return {'manual_ready': manual and not pending, 'pending_review_count': pending, 'review_required': bool(pending)}

    def guard(self, db, book, request):
        if request['narration_mode'] != 'full_cast': return
        cast = self.cast(db, book['id'])
        self.sync(db, book, cast)
        lengths = {s['id']: len(s['text']) for c in book['chapters'] for s in c['segments']}
        scopes = {r['segment_id']: (r['start_offset'], r['end_offset']) for r in request.get('source_ranges', [])}
        for issue in self.issues(db, book, cast):
            if issue['status'] != 'pending' or issue['segment_id'] not in request['segment_ids']: continue
            low, high = scopes.get(issue['segment_id'], (0, lengths[issue['segment_id']]))
            if issue['start_offset'] < high and low < issue['end_offset']:
                raise HTTPException(409, 'Review the unclear passages and confirm their speakers before generating full cast audio')


def register_cast_review(app, store, auth, get_book, get_voice):
    from .casting import Assignment, Character, validate_cast, character_identity
    review = app.state.cast_review

    @app.get('/v1/books/{identity}/review-issues', dependencies=[Depends(auth)])
    def get_issues(identity: str, chapter_id: str | None = None):
        book = get_book(identity)
        if chapter_id is not None and chapter_id not in {c['id'] for c in book['chapters']}: raise HTTPException(400, 'Select a chapter belonging to this original book')
        with store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            cast = review.cast(db, identity)
            review.sync(db, book, cast)
            issues = review.issues(db, book, cast)
            return {'book_id': identity, 'source_sha256': book['source_sha256'], 'revision': review.revision(db, identity),
                    'issues': [i for i in issues if chapter_id is None or i['chapter_id'] == chapter_id]}

    @app.post('/v1/books/{identity}/review-issues/{issue_id}/resolve', dependencies=[Depends(auth)])
    def resolve(identity: str, issue_id: str, body: ReviewResolution):
        book = get_book(identity)
        fingerprint = digest(canonical({'book_id': identity, 'issue_id': issue_id, **body.model_dump(mode='json')}))
        with store.db() as db:
            previous = db.execute('SELECT fingerprint FROM cast_review_requests WHERE request_id=?', (str(body.request_id),)).fetchone()
        # Avoid requiring a voice inventory after a lost response. The real
        # transaction rechecks retry identity before any changed data is saved.
        available = {}
        if not previous:
            with store.db() as db:
                snapshot = review.cast(db, identity)
            voice_ids = {c.voice_id for c in snapshot.characters if c.voice_id}
            if body.voice_id: voice_ids.add(body.voice_id)
            for voice_id in voice_ids:
                try: available[voice_id] = get_voice(voice_id)
                except HTTPException as exc:
                    if exc.status_code != 404: raise
        selected_voice = available.get(body.voice_id)
        with store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            if not db.execute('SELECT 1 FROM books WHERE id=?', (identity,)).fetchone(): raise HTTPException(404, 'Book not found')
            cast = review.cast(db, identity)
            review.sync(db, book, cast)
            issues = review.issues(db, book, cast)
            issue = next((i for i in issues if i['id'] == issue_id), None)
            if issue is None: raise HTTPException(404, 'Review passage not found in this original book')
            previous = db.execute('SELECT fingerprint FROM cast_review_requests WHERE request_id=?', (str(body.request_id),)).fetchone()
            if previous:
                if previous[0] != fingerprint: raise HTTPException(409, 'This review request ID was used with different speaker or voice choices')
                return {'revision': review.revision(db, identity), 'issue': issue, 'cast': cast.model_dump()}
            if review.revision(db, identity) != body.expected_revision: raise HTTPException(409, 'Casting changed while this passage was open; refresh the review and keep your choices')
            characters = {c.id: c for c in cast.characters}
            if body.new_character is not None:
                try: character = body.new_character.model_copy(deep=True)
                except ValueError as exc: raise HTTPException(422, 'Enter a valid new speaker') from exc
                if character.id != body.character_id: raise HTTPException(400, 'New speaker ID must match the selected speaker')
                if character.id in characters: raise HTTPException(409, 'That speaker already exists; select the saved speaker')
                names = {character_identity(n) for n in [character.name, *character.aliases] if n.strip()}
                if any(names & {character_identity(n) for n in [c.name,*c.aliases] if n.strip()} for c in characters.values()): raise HTTPException(409, 'That speaker name or alias already belongs to a saved speaker')
                character.voice_id = None
                characters[character.id] = character
            if body.character_id not in characters: raise HTTPException(400, 'Select a saved speaker or create a new one')
            if body.voice_id:
                if selected_voice is None: raise HTTPException(409, 'Refresh the available voices before saving')
                if selected_voice.get('kind') == 'clone' and not db.execute('SELECT 1 FROM voices WHERE id=?', (body.voice_id,)).fetchone(): raise HTTPException(409, 'That voice was deleted; choose another voice')
                characters[body.character_id].voice_id = body.voice_id
            ranges = body.ranges or [ReviewRange(start_offset=issue['start_offset'], end_offset=issue['end_offset'], character_id=body.character_id)]
            ranges = sorted(ranges, key=lambda r: r.start_offset)
            position = issue['start_offset']
            if body.character_id not in {r.character_id for r in ranges}: raise HTTPException(400, 'The selected speaker must appear in the reviewed passage')
            for r in ranges:
                if r.character_id not in characters or r.start_offset != position or not position < r.end_offset <= issue['end_offset']:
                    raise HTTPException(400, 'Explicit reviewed ranges must cover this original passage completely without gaps or overlaps')
                position = r.end_offset
            if position != issue['end_offset']: raise HTTPException(400, 'Assign the remaining original words explicitly, including any narrator prose')
            narrator = characters.get('narrator')
            narrator_voice = available.get(narrator.voice_id) if narrator else None
            if not narrator_voice: raise HTTPException(409, 'Choose an available narrator voice before reviewing full cast passages')
            for character_id in {r.character_id for r in ranges} | {'narrator'}:
                voice = available.get(characters[character_id].voice_id)
                if not voice: raise HTTPException(409, 'Choose an available voice for every speaker in this reviewed passage')
                if voice['engine'] != narrator_voice['engine']: raise HTTPException(409, 'All reviewed speaker voices must use the narrator voice engine')
                if voice.get('kind') == 'clone' and not db.execute('SELECT 1 FROM voices WHERE id=?', (voice['id'],)).fetchone():
                    raise HTTPException(409, 'A selected voice was deleted; choose another available voice')
            for a in cast.assignments:
                if a.reviewed and a.segment_id == issue['segment_id'] and a.start_offset < issue['end_offset'] and issue['start_offset'] < a.end_offset:
                    if any(r.start_offset < a.end_offset and a.start_offset < r.end_offset and r.character_id != a.character_id for r in ranges):
                        raise HTTPException(409, 'Keep the previously reviewed speaker choices when assigning the remaining words')
            retained = []
            for a in cast.assignments:
                if a.segment_id != issue['segment_id'] or a.end_offset <= issue['start_offset'] or a.start_offset >= issue['end_offset']:
                    retained.append(a); continue
                if a.start_offset < issue['start_offset']: retained.append(a.model_copy(update={'end_offset': issue['start_offset']}))
                if a.end_offset > issue['end_offset']: retained.append(a.model_copy(update={'id': str(uuid.uuid4()), 'start_offset': issue['end_offset']}))
            cast.characters = list(characters.values())
            cast.assignments = retained + [Assignment(segment_id=issue['segment_id'], start_offset=r.start_offset, end_offset=r.end_offset,
                                                     character_id=r.character_id, confidence=1, reviewed=True) for r in ranges]
            try: validate_cast(cast, book)
            except ValueError as exc: raise HTTPException(400, str(exc)) from exc
            db.execute('INSERT OR REPLACE INTO casts VALUES(?,?)', (identity, canonical(cast.model_dump())))
            review.changed(db, identity)
            db.execute('INSERT INTO cast_review_requests VALUES(?,?,?,?)', (str(body.request_id), fingerprint, identity, issue_id))
            current_issue = next(i for i in review.issues(db, book, cast) if i['id'] == issue_id)
            return {'revision': review.revision(db, identity), 'issue': current_issue, 'cast': cast.model_dump()}
