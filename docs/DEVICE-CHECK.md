# Physical iPhone preview check

These checks require the actual iPhone. Simulator and package checks do not count as passing them. Record the phone model, iOS version, LiveContainer version, app version, and any failure with its exact step.

## Install and read offline

Download the release IPA to Files. In an existing working LiveContainer installation, use its plus button to import the IPA and launch Book Pocket Open. The app requires iOS 18 or newer. Follow the project's [official installation guide](https://livecontainer.github.io/docs/installation) if LiveContainer itself needs setup; the unsigned guest IPA is not an App Store installation.

Import the original Lantern EPUB from this repository's fixtures, then a book you normally read. Check visible text, Contents, Search, bookmarks, selected-text highlights, and dark/cream/white reading surfaces. Increase the font, rotate the phone, close the app, and reopen it. The saved source location should survive those changes. Enable airplane mode and reopen the book. Try Read aloud without the PC.

## Pair and download

Launch the installed Windows companion with the phone and PC on the same network. Open Devices in the desktop studio, create a pairing code, and scan its QR from the phone's Studio tab. Approve the named phone on the PC. Relaunch the phone app and refresh; the saved pairing should still work without entering a token.

Generate the short original fixture on the PC. Download the book and completed narration to the phone. Interrupt a download once, relaunch, and retry it; completed verified files should be reused. Disconnect the PC and enable airplane mode. Confirm downloaded narration still plays and highlights the original source. Legacy recordings must retain their no-synchronized-text label.

## Playback and hardware

With a sufficiently long downloaded recording, test pause/resume, seek, speed, sleep timer, Bluetooth controls, lock-screen controls, a call or other audio interruption, and Bluetooth disconnection. Then play for at least one hour with the screen locked. Record whether it continued, whether controls worked, and whether the final reading/audio position reopened correctly.

The application remains a development preview until these device gates have evidence. A failed check should be reported and repaired before promoting the release.
