# Cast production and playback recovery

## Your last audiobook

Listen saves the selected book, narrator, exact generated take, Page or Chapter scope, complete recording position and playback speed. Restarting restores that selection paused; it never starts speaking automatically. Offline playback requires the same verified downloaded parts. Missing or damaged audio reports unavailable instead of substituting a newer take.

The mini-player's **X** pauses playback and hides the bar. Listen retains the selected audiobook and position. The bar stays hidden across tabs and app restarts until you explicitly play again.

## Clear failed production attempts

In **Studio → Production queue**, failed and cancelled attempts offer **Delete**. Confirm the particular entry. The companion must be reachable; a failed deletion retains the entry and its local audio. Completed recordings and source books are separate. To remove a completed recording, use its existing Saved audio actions.

## Build the cast as you read

For Full cast, generating a page analyzes its surrounding chapter. Generating a chapter analyzes that chapter. Completed chapter analysis is reused, and later chapters add characters without replacing earlier reviewed assignments or selected voices. Names and aliases reuse the same character when unambiguous. Ambiguous names and uncertain speakers require review; model output is not guaranteed correct.

The Cast studio provides **Analyze chapter**, **Reanalyze chapter** and **Analyze entire book**. The first two work on the selected chapter. Whole-book analysis remains an explicit action. Automatic page preparation only asks about characters used in the selected source range; an unused character does not block that page.

Beside a character, choose an existing voice, **Create voice**, or explicitly **Use narrator**. Create voice imports and trims a reference recording, asks for its exact transcript for OmniVoice, and assigns the returned voice to that character while preserving cast edits. Character voices use the narrator's engine. **Audition** generates a short sample on the paired PC with that actual voice; it is separate from previewing the imported reference and does not create a book queue entry. Save the cast and review its dialogue assignments before generating.

The PC needs a configured analysis model and narration engine. The personal installation uses an existing local loopback model with CPU inference; this may take time for dialogue-heavy chapters. Book text stays local unless hosted analysis is explicitly enabled. The PC must remain awake and online.

## Physical iPhone check

Update the existing LiveContainer app while retaining its data. Play an expendable downloaded page, change speed and seek into a later passage. Close the mini-player, restart, and confirm Listen restores the same Page/Chapter selection paused at the saved position. Test offline, then explicitly play and verify the mini-player reappears.

Cancel a failed-entry deletion once, then confirm it with the PC reachable. Confirm other takes remain. Repeat with the PC unavailable: the failed entry must remain.

For Full cast, analyze one chapter, correct one speaker and choose a voice, then analyze another chapter. Confirm the first edit survives and recurring character aliases share their voice. On a page containing a missing character voice, create it, audition it, save and generate the page. Review actual speakers and pronunciation; Simulator transport fixtures establish app behavior, not model quality or physical-device playback.
