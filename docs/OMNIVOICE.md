# Companion-managed OmniVoice

In the Windows studio, open Settings and install OmniVoice. The companion creates
its own Python environment, downloads a pinned model and tokenizer snapshot,
verifies the downloaded files, and performs a real speech test before showing
Ready. A supported NVIDIA driver uses CUDA; other machines use CPU. Installation
requires several gigabytes and internet access. Generation uses the local model.
VoiceStudio is not required.

Windows Companion 0.1.9 adds this engine. Use iOS 0.1.13 or later for the reader's
managed Kyon option. After upgrading the iPhone, refresh Studio, open your book,
tap Read aloud, choose Kyon, then Generate and Current page or Current chapter.
Download the finished take to play it offline. Keep the companion running on
the PC while it generates. An existing paired Funnel address works without a
phone VPN; neither a new address nor re-pairing is required for this update.

Open Voices, import reference audio, select OmniVoice, and enter the exact words
spoken in that reference. Name the voice Kyon to use the iPhone's Kyon narrator
option. Other imported voices can be assigned in Cast Studio. References and
transcripts stay in the companion's private data folder. The adapter does not
download a speech recognition model or reuse serialized VoiceStudio prompts.

The iPhone prefers a ready companion-managed Kyon voice. Existing downloaded
VoiceStudio recordings retain their original provenance and remain usable.
An existing external VoiceStudio configuration can still be used independently;
voice IDs and cached takes are never silently changed between engines.

The [official OmniVoice source](https://github.com/k2-fsa/OmniVoice) is Apache-2.0.
Its [pretrained weights](https://huggingface.co/k2-fsa/OmniVoice) are CC-BY-NC,
and the bundled Higgs tokenizer has additional community terms. These downloads
are optional and are not relicensed as Apache-2.0 by this application. Consult the
downloaded README and audio_tokenizer/LICENSE before using or redistributing them.
Kokoro and Qwen3 remain the public baseline for separate model choices.

Source revision: `08be0b4ccbac3e13e374e86fbfead4b4cac343e2`.
Model revision: `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`.
English is the currently exposed, tested language. Clone prompts are created from
reference audio and its transcript inside the managed process. Every output
passes the existing PCM, timing and checksum validation before becoming a take.
