# Physical iPhone preview check

These checks require the actual iPhone. Simulator and package checks do not count as passing them. Record the phone model, iOS version, LiveContainer version, app version, and any failure with its exact step.

For iOS 0.1.13 and Windows Companion 0.1.9, stop VoiceStudio, keep the companion
running, and refresh the phone's Studio inventory. Generate a short page with
the imported companion-managed Kyon voice, download it and play it. Repeat for
a chapter, then try the downloaded take in airplane mode. Existing external
recordings must remain selectable. This version removes the invalid explicit
AirPlay option from the playback audio session; confirm downloaded speech starts
on the physical iPhone, then check AirPlay and Bluetooth separately. Simulator
success does not establish that the reported OSStatus -50 is resolved on-device.

## Public HTTPS connection

With iOS 0.1.11 and Companion 0.1.7 or later, configure [Funnel](FUNNEL.md) and
pair using the public-address QR. Disable Tailscale and Wi-Fi on the iPhone,
leaving cellular internet enabled. Refresh the companion, generate one short
page with Kyon, download and play it. Confirm the selected source and narrator,
then enable airplane mode and play the downloaded take again. Keep the PC and
voice engine running during generation. An external VPS smoke proves public
reachability and API behavior; it does not pass this physical-device check.

With an existing LAN pairing and iOS 0.1.12 or later, use cellular to open
**Studio → … → Companion connection**. Enter the PC's public HTTPS address
with its path prefix and leave the optional fingerprint empty. Verify and save;
no new pairing code should be needed. Relaunch and refresh to confirm the
new address persisted and existing books/audio remain. Try an unreachable
address and an address belonging to another companion: verification must fail
without replacing the working connection.

## Install and read offline

Download the release IPA to Files. In an existing working LiveContainer installation, use its plus button to import the IPA and launch Book Pocket Open. The app requires iOS 18 or newer. Follow the project's [official installation guide](https://livecontainer.github.io/docs/installation) if LiveContainer itself needs setup; the unsigned guest IPA is not an App Store installation.

Import the original Lantern EPUB from this repository's fixtures, then a book you normally read. Check visible text, Contents, Search, bookmarks, selected-text highlights, and dark/cream/white reading surfaces. Increase the font, rotate the phone, close the app, and reopen it. The saved source location should survive those changes. Enable airplane mode and reopen the book. Try Read aloud without the PC.

## Pair and download

Launch the installed Windows companion with the phone and PC on the same network. Open Devices in the desktop studio, create a pairing code, and scan its QR from the phone's Studio tab. Approve the named phone on the PC. Relaunch the phone app and refresh; the saved pairing should still work without entering a token.

Generate the short original fixture on the PC. Download the book and completed narration to the phone. Interrupt a download once, relaunch, and retry it; completed verified files should be reused. Disconnect the PC and enable airplane mode. Confirm downloaded narration still plays and highlights the original source. Legacy recordings must retain their no-synchronized-text label.

With iOS 0.1.7 or later, export a short completed production as a project on the PC and import it on the phone. Repeat the import; the original book and take should not duplicate. Confirm existing downloaded recordings still play. If an import fails or is interrupted, retry the same archive and check that no incomplete take becomes playable. A validated original book may remain available to read after the audio import fails. This phone check is separate from the automated corrupt-file and database-failure tests.

## Reader page and chapter narration

For the unified reader/player update, keep the paired PC and its external OmniVoice service running. Open a text page and tap **Read aloud**. Opening the panel and changing narrator must not start speech. Choose **On-device** and press Play; it should work without the PC. Pause it, then choose **Kyon**. With no matching downloaded take, playback must be disabled. Tap **Generate** → **Current page**; iOS 0.1.12 starts preparation and generation in the compact player. Open narration details to compare the preview with the visible words, including a paragraph that continues onto the next screen. Confirm the downloaded result uses the uniquely named Kyon voice and highlights the same source.

Choose **Generate** → **Current chapter**, check the preview's start/end against Contents, and try a chapter containing an intervening illustration resource. Change text size, capture another page, and verify the new selection follows the reflowed page. Close and reopen the player while the PC generates; pause/resume and retry a failed job. Finished audio should download and play without duplicating completed passages. Pause a downloaded take, manually open another chapter, and confirm the reader stays there, including after a repeated pause or audio interruption. A downloaded chapter should be available from the pages it covers, while a page excerpt must not enable an unrelated page. In airplane mode, reopen the player and confirm matching downloaded narration still works.

Choose **Full cast**. Kyon-only audio must not enable its playback. Without a saved reviewed cast, open **Set up cast**, choose its narrator and character voices, review the dialogue and save. Generate a page that cuts through a reviewed assignment; audio must contain only the captured words and use the selected cast inside that range. Generate a narrator-only page as Full cast too; its take must remain distinct from Kyon. Verify the chapter selector and explicit alternate takes, another book's exclusion, and disabled playback when audio is missing or corrupt. Check the compact player in portrait, landscape and the largest accessibility text size without scrolling its controls; long previews and cast details may open separately.

## Playback and hardware

In iOS 0.1.5, open **Listen** with on-device speech and downloaded narration. Confirm all player controls fit without scrolling in portrait and landscape. Tap the chapter row, select a different chapter, and check playback and the saved reading position. Generate and download two chapters separately, plus an alternate page excerpt within one chapter. Disconnect the PC and enable airplane mode. The chapter selector should offer both chapters and explicitly distinguish their downloaded takes and excerpts. Choose each in turn and check that playback starts the selected recording from its beginning. A partially downloaded chapter must not claim full coverage, missing files must not be offered, and audio from another book must stay out of this selector. Automatic passage playback must remain within the selected take. Open the tray to select or remove a downloaded recording.

For iOS 0.1.6 or later, enable the largest accessibility text size in iPhone Settings. Check Listen in portrait and landscape, access every playback control and the chapter selector without scrolling, and return through each native tab. Check the reader's page arrows and speech action, then the mini-player pause/resume button. With VoiceOver enabled, confirm those controls announce their actions and the timeline announces elapsed time and total duration. Simulator layout checks do not count as physical VoiceOver confirmation.

With a sufficiently long downloaded recording, test pause/resume, seek, speed, sleep timer, Bluetooth controls, lock-screen controls, a call or other audio interruption, and Bluetooth disconnection. Then play for at least one hour with the screen locked. Record whether it continued, whether controls worked, and whether the final reading/audio position reopened correctly.

The application remains a development preview until these device gates have evidence. A failed check should be reported and repaired before promoting the release.

## Cast edits during analysis

With iOS 0.1.8 and Companion 0.1.4 or later, start speaker analysis on an original fixture. While it runs, rename a character, remove an alias, select a voice, delete an assignment and add a reviewed selection containing an emoji. Close and reopen the cast editor while the PC continues analysis. It should resume polling, retain the local changes, and add only suggestions outside protected ranges. Save after reviewing the result, then reopen and confirm the saved cast. Interrupt the phone's connection during polling, reconnect and retry the analysis refresh. Unsaved drafts survive editor dismissal while the app stays open; they are not promised across app termination.
