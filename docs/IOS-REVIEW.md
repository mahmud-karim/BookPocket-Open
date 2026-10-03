# Native iOS review

Paul Hudson's [SwiftUI Pro skill](https://github.com/twostraws/SwiftUI-Agent-Skill/tree/be297ff80dddec529af1f9b1f1f114aab6c9d11c) is a useful review guide for this app. The [original post](https://x.com/twostraws/status/2105613129602285716) links to his [explanation](https://www.hackingwithswift.com/articles/282/swiftui-agent-skill-claude-codex-ai). The referenced skill is MIT licensed; this repository does not redistribute it or run its installation command.

The focused review used its accessibility, design and performance references at commit `be297ff80dddec529af1f9b1f1f114aab6c9d11c`. Product requirements take precedence over generic defaults: keep iOS 18 support, the existing Readium integration and the approved Obsidian design. Do not add dependencies or rewrite working navigation merely to match a newer template.

For changes to Listen or the reader:

- Keep Listen's playback controls on one screen. Verify compact portrait and landscape layouts, chapter selection and native-tab access with actual playback.
- Give button labels a real tappable area of at least 44 by 44 points, rather than adding empty space outside the button. Apple documents this minimum in its [design tips](https://developer.apple.com/design/tips/).
- Verify enlarged text using the native content-size setting. Check both the UIKit trait and SwiftUI environment before asserting layout; a launch flag alone is not evidence that text enlarged.
- Give icon controls and timeline values meaningful accessibility labels. Preserve numeric values separately so transport tests still verify actual elapsed playback and seeking.
- Follow Apple's [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility). Simulator geometry and labels do not prove physical VoiceOver, Bluetooth or locked-screen behavior.
- Avoid unnecessary work on playback ticks. Any caching change must preserve downloaded-file integrity checks and correct chapter/take selection.

The guide informs review; it does not replace compilation, native tests, screenshot inspection, package checks or physical-device validation. Record measured outcomes and limitations in [VERIFICATION.md](VERIFICATION.md).
