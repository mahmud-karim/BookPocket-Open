# Cast production and playback recovery

## Your last audiobook

Listen saves the selected book, narrator, exact generated take, Page or Chapter scope, complete recording position and playback speed. Restarting restores that selection paused; it never starts speaking automatically. Offline playback requires the same verified downloaded parts. Missing or damaged audio reports unavailable instead of substituting a newer take.

The mini-player's **X** pauses playback and hides the bar. Listen retains the selected audiobook and position. The bar stays hidden across tabs and app restarts until you explicitly play again.

## Clear failed production attempts

In **Studio → Production queue**, failed and cancelled attempts offer **Delete**. Confirm the particular entry. The companion must be reachable; a failed deletion retains the entry and its local audio. Completed recordings and source books are separate. To remove a completed recording, use its existing Saved audio actions.

## Build the cast as you read

For Full cast, analyze the surrounding chapter before generating a page, or the selected chapter before generating its complete audio. Completed chapter analysis is reused, and later chapters add characters without replacing earlier reviewed assignments or selected voices. Names and aliases reuse the same character when unambiguous. Ambiguous names and uncertain speakers require review; model output is not guaranteed correct.

The Cast studio provides **Analyze chapter**, **Reanalyze chapter** and **Analyze entire book**. The first two work on the selected chapter. Whole-book analysis remains an explicit action. Page generation requires voices and reviewed speakers only for its selected source range; an unused character does not block that page.

Beside a character, choose an existing voice, **Create voice**, or explicitly **Use narrator**. Create voice imports and trims a reference recording, asks for its exact transcript for OmniVoice, and assigns the returned voice to that character while preserving cast edits. Character voices use the narrator's engine. **Audition** generates a short sample on the paired PC with that actual voice; it is separate from previewing the imported reference and does not create a book queue entry. Save the cast and review its dialogue assignments before generating.

The PC needs a configured analysis model and narration engine. The personal installation uses Gemini 3.8 Flash through the configured Antigravity CLI for speaker analysis, with explicit hosted consent; OmniVoice generates speech locally. The PC must remain awake and online.

## Review unclear dialogue

In the reader, open **⋯ → Manage audiobook**, select **Full cast**, and choose the chapter. **Analyze chapter** asks for hosted consent, then shows actual processed-passage counts and Reading, Identifying speakers and Saving stages. You can return to reading and reopen the accepted job without submitting it again. Processing every passage does not mean the cast is ready: missing voices and speaker reviews remain separate steps.

Open **Characters & voices** to assign or create voices. Open **Speaker review** to check the original highlighted words and surrounding text. Choose who is speaking, then choose their voice or **Create voice**. A new character can be added directly from the review.

Use **Save & next** to save that assignment on the PC and continue. If different speakers share the passage, select their exact words and assign each speaker explicitly. **Use narrator for remaining words** is optional; turn it on only when the rest is narrator prose. No quotation edit or book rewrite is needed. The app keeps your choices if the connection fails or another cast edit creates a conflict.

After all relevant passages have saved speakers and voices, generation becomes available. Reviews elsewhere in the chapter do not block a page that excludes those words. Successful analysis is reused while reviewing. Kyon single narration remains available independently of full-cast review.

## Playback and audiobook setup

**Read aloud** contains the chapter and Page/Chapter selectors, playback source, recording choice, complete timeline, skip controls, speed and sleep timer. Missing or undownloaded audio has disabled playback and an explicit setup action. The top toolbar uses the selected reading-page color; the player extends to the bottom edge.

**Manage audiobook** owns setup, progress, saved recordings and generation. Page generation uses the exact captured words from when setup opened. Selecting a different chapter changes analysis, review and recordings together and permits canonical chapter generation; open that chapter in the reader to capture one of its pages. If the captured page is ready while other chapter passages need work, **Generate page audio** remains available. Generation never starts playback automatically.

The parser supports ordinary contractions, leading elisions such as **’Course**, and balanced nested quotations. Truly malformed or ambiguous passages require your explicit speaker choice. Model suggestions also require review; quotation syntax alone cannot establish the correct character.

## Physical iPhone review check

Open a passage needing attention, confirm that its exact words match the book, choose a speaker and voice, and save. Verify the next unclear passage opens and that completing all relevant reviews enables generation. Test a failed connection while saving: the choices must remain. Confirm a page outside the unclear words can generate without reviewing unrelated passages. These checks exercise the physical device and your actual book separately from Simulator fixtures.

## Physical iPhone playback check

Update the existing LiveContainer app while retaining its data. Play an expendable downloaded page, change speed and seek into a later passage. Close the mini-player, restart, and confirm Listen restores the same Page/Chapter selection paused at the saved position. Test offline, then explicitly play and verify the mini-player reappears.

Cancel a failed-entry deletion once, then confirm it with the PC reachable. Confirm other takes remain. Repeat with the PC unavailable: the failed entry must remain.

For Full cast, analyze one chapter, correct one speaker and choose a voice, then analyze another chapter. Confirm the first edit survives and recurring character aliases share their voice. On a page containing a missing character voice, create it, audition it, save and generate the page. Review actual speakers and pronunciation; Simulator transport fixtures establish app behavior, not model quality or physical-device playback.
