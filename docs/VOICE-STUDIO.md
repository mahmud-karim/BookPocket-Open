# Use an existing VoiceStudio voice

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

In iOS 0.1.3 with PC Companion 0.1.1 or later, open a book and tap the **waveform plus** button in the reader's top bar. Choose **Generate current page** or **Generate current chapter**. The narration panel previews the captured original words and uses the uniquely named **Kyon** profile from the external OmniVoice service. Tap **Generate with Kyon**. With **Play when ready** enabled, the app downloads the finished audio and starts it in the reader; you can also use **Download & play in reader**.

The page is captured before the panel opens, including partial paragraphs. A chapter follows table-of-contents boundaries across intervening EPUB resources. If a book's visible text or chapter boundaries cannot be matched exactly, the app explains the problem before requesting audio. It never expands a page request into whole paragraphs. Reopen the panel after changing pages or reading appearance to capture a new selection.

**Recent narration** reopens the latest page/chapter job for this book. Generation continues on the PC if you close the panel; pause, resume, cancel and retry controls remain available. Keep both the companion and VoiceStudio running during generation. Finished downloads remain playable offline. An older companion requires an update before it can generate exact page ranges.

For other existing voice profiles or broader selections, the Studio flow remains available:

1. Open **Studio → Refresh → Create narration**.
2. Choose a book from your library, then tap **Send book to companion**. This also retrieves the companion's matching book manifest for a book already on the PC.
3. Select the existing profile under **Narrator**.
4. Under **Generate**, choose a readable chapter or **Entire book**. For a preview, enable **Select individual passages** and choose a short passage. Cover/image sections may contain no text to generate.
5. Tap **Generate narration**. The production queue shows actual progress.
6. When the recording is ready, tap **Download** in the production queue. Play it from **On this device** in Studio, or from Listen.

The reader's **Use on-device voice** menu action starts Apple's speech. Its bottom playback button pauses or resumes the active narration, including downloaded PC audio. Downloaded recordings can play without the PC once their checksums have been verified and they are stored on the phone.

In iOS 0.1.4, **Listen** keeps the player controls on one screen. Tap the chapter row to select a chapter for on-device reading, or a chapter with downloaded audio in the current take. A page-only take offers only its available portion. The tray button in the upper-right corner opens your downloaded recordings.

If preparation says the PC is offline or unreachable, open Book Pocket Open on the PC and confirm the devices can reach the paired address over the same Wi-Fi or your configured Tailscale connection. Start VoiceStudio as well, then tap **Refresh connection** in the narration panel. Reading and downloaded audio remain available while the PC is offline. A certificate error requires checking the saved companion identity; do not bypass certificate validation.

## Generate from the PC

Open a book's **Create audiobook** view. Set **Voice engine** to **VoiceStudio (external)**, choose **Narrator**, and set **Read** to **This chapter**, **The whole book**, or **Selected passages**. Click the matching generate button. Finished productions appear in **Listen** and in the paired phone's production queue.

To create or revise a VoiceStudio profile, use VoiceStudio's own tools, then refresh Book Pocket's voice collection. The external adapter exposes existing service profiles; Book Pocket's **Add voice** form is for its managed cloning engines.
