# Page and chapter audio

Open a book and tap **Read aloud**. Choose **On-device**, **Kyon**, or **Full cast**. Kyon and Full cast keep their recordings separate.

For PC voices, **Page** checks the visible words and **Chapter** checks the complete current chapter. Missing audio disables Play. **Generate** asks whether to generate the current page or current chapter; it captures the original text from the open book.

The upcoming 0.1.17 update gives each selected page or chapter recording one continuous timeline. Its release is pending final native verification; see [verification status](VERIFICATION.md). The time below its seek bar shows elapsed time on the left and the complete recording duration on the right, including all of its downloaded passages. Seeking and the 15-second controls cross passage boundaries. The same selected recording and timeline continue in Listen and lock-screen controls. Existing generated page/chapter recordings use their downloaded parts together; no regeneration is needed to join those parts.

Separate saved takes remain explicit choices and are never mixed together. A selected recording needs all of its required files before playback. If a wider older recording has no exact timing at a visible page boundary, choose its saved clip or complete chapter, or generate the current page. The app does not estimate a page boundary from text length or include neighboring chapter words.

**Saved audio** lists recordings in the current chapter even when a complete chapter has not been generated. The summary reports page clips separately from chapter availability. Clips are ordered by their original text position, with alternate takes retained as separate choices.

When several takes match the page, the player says **Choose a matching take** and waits for an explicit selection in Saved audio. This is different from missing audio; it prevents silently switching between alternate recordings.

- **Ready offline** means the complete recording has matching, verified local files.
- **On PC** means generation finished, but a complete verified download is not available on this phone. **Download** saves the files without starting playback. A failed download leaves the recording unavailable offline.
- Selecting a recording closes the browser and selects that take. Press **Play** to start it. A selected excerpt is labelled **Saved page clip** so it cannot be mistaken for the entire current page.
- A missing full chapter does not hide existing clips. Its separate section offers **Generate audio…**, which opens the page/chapter choice.

Changing font size can move words between visible pages. Saved clips stay tied to their original words and remain available in Saved audio; they are not identified by a temporary screen page number. A clip that no longer covers every visible word will not automatically become the current-page take.

The player overlays the reading surface without repaginating the book. Its charcoal background extends to the screen bottom, with no separate strip beneath it. The ordinary player does not scroll; the Saved audio list can scroll. Larger accessibility text uses the existing full-height player presentation.

Generation needs the paired Windows companion. Downloaded audio remains playable offline. See [Connection](CONNECTION.md), [remote access through Funnel](FUNNEL.md), and [Start companion](COMPANION-START.md).
