# Use an existing VoiceStudio voice

For generation without VoiceStudio, use [companion-managed OmniVoice](OMNIVOICE.md).
The external setup below remains optional. The iPhone prefers a ready managed
Kyon voice while retaining existing external recordings.

Book Pocket can use profiles from a separately installed VoiceStudio service through its optional external adapter. The existing profile and its reference audio stay in VoiceStudio; Book Pocket does not recreate the clone.

## Connect the PC companion

1. Start VoiceStudio and confirm that its OmniVoice engine and the desired voice profile are available.
2. Close Book Pocket's PC companion using its tray menu. Preserve its data folder and TLS identity.
3. In `%LOCALAPPDATA%\BookPocketOpen\config.json`, add `"voicestudio_url": "http://127.0.0.1:3900"` to the existing JSON object. Use the actual local VoiceStudio address if it differs. Keep existing fields such as `public_url` and `ffmpeg`.
4. Reopen Book Pocket from its desktop shortcut. Open **Voices** in the PC studio. **VoiceStudio (external)** should show **Ready**, and the service's named profiles should appear.

If creating this configuration file for the first time, also include `public_url` with the companion's current HTTPS address from its pairing details. Saving only the voice-service URL would leave version 0.1.0 using its default localhost phone address.

When starting the companion from a terminal instead, pass `--voicestudio-url http://127.0.0.1:3900` to the existing `serve` command. The saved configuration is preferable for ordinary desktop launches.

Keep VoiceStudio and the PC companion running while generating narration. A short sample verifies that the selected profile actually synthesizes; an inventory response alone does not establish voice quality. The adapter explicitly requests OmniVoice and does not silently switch engines.

## Generate from the iPhone

In the unified iOS 0.1.10 reader with PC Companion 0.1.6 or later, open a book and tap **Read aloud**. Choose **Kyon** in the player. Selecting a narrator does not start playback. With no matching downloaded audio, Play and skip controls remain disabled. Tap **Generate** and choose **Current page** or **Current chapter**. The narration details preview the captured original words and resolve the uniquely named **Kyon** profile from the external OmniVoice service. Tap **Generate with Kyon**. When generation finishes, use **Download & play**; the app verifies the files before starting the selected take.

The page is captured when you select its generation scope, including partial paragraphs. A chapter follows table-of-contents boundaries across intervening EPUB resources. If a book's visible text or chapter boundaries cannot be matched exactly, the app explains the problem before requesting audio. It never expands a page request into whole paragraphs. After changing pages or reading appearance, choose Generate again to capture a new selection.

The player's details reopen matching jobs and explicit alternate takes for this book. Generation continues on the PC if you close the panel; pause, resume, cancel and retry controls remain available. Keep both the companion and VoiceStudio running during generation. Finished downloads remain playable offline. A downloaded chapter can cover the page you're reading; an excerpt cannot enable an unrelated page. An older companion requires an update before accepting the explicit narration mode.

Choose **Full cast** to use the book's saved narrator, character voices and reviewed dialogue ranges. Open **Set up cast** in details if these are missing. Generate offers the same page/chapter choices and uses only the captured original source. Full-cast takes remain distinct from single-narrator Kyon takes, including pages containing only narrator prose. Changing the narrator or take never silently substitutes another recording.

For other existing voice profiles or broader selections, the Studio flow remains available:

1. Open **Studio → Refresh → Create narration**.
2. Choose a book from your library, then tap **Send book to companion**. This also retrieves the companion's matching book manifest for a book already on the PC.
3. Select the existing profile under **Narrator**.
4. Under **Generate**, choose a readable chapter or **Entire book**. For a preview, enable **Select individual passages** and choose a short passage. Cover/image sections may contain no text to generate.
5. Tap **Generate narration**. The production queue shows actual progress.
6. When the recording is ready, tap **Download** in the production queue. Play it from **On this device** in Studio, or from Listen.

Choose **On-device** in the reader player and press Play to start Apple's speech without the PC. The player keeps transport, speed, sleep timer and chapter selection together on one screen. Exact previews, generation progress and cast details open separately. Downloaded recordings can play without the PC once their checksums have been verified and they are stored on the phone.

In iOS 0.1.5, **Listen** keeps the player controls on one screen. Tap the chapter row to select a chapter for on-device reading, or browse downloaded narration across this book. Separately generated chapters and alternate takes remain separate choices with narrator and take details. Only complete local chapter coverage is labelled **Full chapter**; page selections and partial downloads are labelled **Excerpt**. Selecting a recording starts it from the beginning. Automatic passage playback stays within that take. The tray button in the upper-right corner opens your downloaded recordings.

If preparation says the PC is offline or unreachable, open Book Pocket Open on the PC and confirm the phone can reach its paired address. LAN addresses require the same Wi-Fi; private Tailscale addresses require the phone's Tailscale connection. A configured [Funnel address](FUNNEL.md) uses ordinary internet without a phone VPN, with iOS 0.1.11 and Companion 0.1.7 or later. Start VoiceStudio as well, then tap **Refresh connection & takes** in the player details. Reading and downloaded audio remain available while the PC is offline. A certificate error requires checking the saved companion identity; do not bypass certificate validation.

## Generate from the PC

Open a book's **Create audiobook** view. Set **Voice engine** to **VoiceStudio (external)**, choose **Narrator**, and set **Read** to **This chapter**, **The whole book**, or **Selected passages**. Click the matching generate button. Finished productions appear in **Listen** and in the paired phone's production queue.

To create or revise a VoiceStudio profile, use VoiceStudio's own tools, then refresh Book Pocket's voice collection. The external adapter exposes existing service profiles; Book Pocket's **Add voice** form is for its managed cloning engines.
