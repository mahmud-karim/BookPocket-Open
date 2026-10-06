# Google cast analysis through Antigravity

The Windows companion can use the official Antigravity CLI and its signed-in Google account to identify speakers. OmniVoice remains the local speech generator. Reading, saved audio, pairing and character voices remain independent of the analysis provider.

Install [Antigravity CLI](https://antigravity.google/docs/cli/install/) separately and run `agy` once on the same Windows account as the companion to sign in. Use `agy models` to check model availability. Google AI Pro includes access subject to model and weekly usage limits; this integration does not use a Gemini API key or require API billing. The adapter rejects enabled `useG1Credits`; an absent setting uses the CLI's documented false default, preventing subscription exhaustion from automatically using AI credits.

In the Windows studio, open **Settings → Cast analysis model**, choose **Google · Antigravity CLI**, and save. This preview pins `gemini-3.8-flash-high`, the tested Flash model. An empty executable field finds the installed `agy` automatically. A custom installation requires an absolute native executable path.

On the iPhone, open the book's cast editor, enable **Allow configured hosted analysis**, and choose **Analyze chapter**. Use **Reanalyze chapter** to replace old model suggestions after changing provider; saved human corrections and voice assignments remain authoritative. Analysis sends the requested chapters and nearby context, along with the accumulated character names and aliases, to Google. It does not send audio, reference recordings or the entire library. The current iPhone build already supports these controls.

Results pass the existing exact-source and character validation before they are saved. The current review policy still asks you to confirm every model suggestion. Switching providers improves the available analysis service; it does not remove that review step. Missing voices require choosing an existing voice or **Create voice**.

The companion runs a dedicated agent in an isolated temporary workspace. Supported workspace hooks deny tool execution, and a small public bootstrap turn verifies the active policy before book text is sent. It disables slash-command expansion and rejects global executable hooks/plugins or enabled credit fallback. Prompts travel through stdin rather than command-line arguments. Antigravity itself retains its normal account conversation history; this is a hosted service, not offline processing. Authentication failures, exhausted quota, invalid results and timeouts produce explicit errors. There is no automatic fallback to a local model or a paid API.

Upstream references: [headless and structured output](https://antigravity.google/docs/cli/headless/), [custom agents](https://antigravity.google/docs/subagents/), [plans and quota](https://antigravity.google/docs/plans), [CLI settings](https://antigravity.google/docs/cli/reference/).
