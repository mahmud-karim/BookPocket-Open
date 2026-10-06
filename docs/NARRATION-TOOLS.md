# Word highlighting, pronunciation and recording removal

Available in [iOS 0.1.18/build 19](https://github.com/mahmud-karim/BookPocket-Open/releases/tag/v0.1.18-preview.1) with [Windows companion 0.1.10](https://github.com/mahmud-karim/BookPocket-Open/releases/tag/windows-v0.1.10-preview.1). Published packages were downloaded again and independently verified. Physical iPhone synchronization and voice quality remain device checks.

On-device read aloud follows the system's spoken-word callbacks. Kyon and full-cast recordings follow measured word timings. New English recordings receive acoustic alignment when the companion's local alignment model is ready. For an older passage-timed recording, select the saved take and open its narration details, then choose **Enable word highlighting**. The PC prepares timings for the existing audio; the waveform and continuous playback duration stay unchanged. Refresh after preparation, then use the downloaded recording offline.

Alignment uses the exact text and pronunciation settings with which the recording was made. It preserves the original words, including when one written name is spoken as several words. Silent gaps have no word highlight. An alignment failure retains the recording and reports the reason. The app never pretends evenly spaced estimated word times are measured synchronization.

The optional English acoustic model is [facebook/wav2vec2-base-960h](https://huggingface.co/facebook/wav2vec2-base-960h), pinned at revision `22aad52d435eb6dbaf354bdad9b0da84ce7d6156`. Its model card declares Apache-2.0. Setup downloads the model separately and verifies its pinned file hashes before use. Alignment runs locally; no recording is uploaded to an alignment service.

## Fix a pronunciation

Select a written word in the reader and choose its pronunciation action, or open **Pronunciation** from the reader/narration menu. Enter the **Written word or phrase** and **Speak as** respelling. For example, keep `Mira` in the book and try `Mee-rah` for speech.

Use the explicitly labelled **On-device preview** to compare your draft with an Apple voice, optionally in a test sentence. This tests the respelling without saving it; it is not a Kyon voice preview. Save the correction to the phone, and edit, enable/disable or remove it in **Saved corrections**. Phone drafts survive offline use and inventory refresh.

Enabled saved corrections are included in new PC audio requests. Choose **Regenerate page or chapter** to hear a correction with Kyon or the saved cast. Existing audio stays unchanged until regenerated; alternate recordings remain separate takes.

**Save corrections to PC** shares the list with the companion. If another device changed the list, the phone keeps its draft and offers an explicit choice to load the PC list or keep the phone draft. Loading the PC list replaces the draft; it is never silently overwritten by refresh.

## Remove a clip

Open **Saved audio** and use the chosen recording's actions. Confirm the recording identity before removing it.

- **Remove download** removes that take's phone copy while leaving the PC take available to download again. It works offline.
- **Delete generated take** removes the entire selected take from the PC and phone. It requires the companion; failure preserves the phone's verified copy. Other takes and the source book remain.

Backend assets shared by other recordings are retained. A finishing generation or delayed retry cannot restore a deleted take. If Windows temporarily holds a deleted download file open, cleanup is retried durably after the handle closes.
