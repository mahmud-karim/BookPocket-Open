# Start the companion from iPhone

With iOS 0.1.15 and the optional Pocket Hub receiver configured, open **Connection**. When the saved PC cannot be verified, tap **Start companion**. The phone uses its existing pairing and HTTPS address. It waits for authenticated companion access before showing **Connected / Live**. An acknowledgement alone never establishes connectivity.

Windows must be awake and online. Pocket Hub's background supervisor and the HTTPS tunnel must be running. Closing the Pocket Hub window leaves the supervisor and receiver running. This starts an application; it does not wake a sleeping or powered-off computer. Already-running narration is not restarted by the button.

The optional receiver is original Apache-2.0 code in `scripts/pocket_hub_receiver.py`. It runs in the companion's bundled Python environment and does not load speech models. Pocket Hub must register the fixed `bookopen` service for the installed companion launcher, and supervise the receiver as a separate service. Use the exact installed executable/script identity and persistent intentional-stop/recovery behavior; repeated Start must not reset an enabled service's failure backoff.

The fixed companion launch must enable the phone gateway on 8785 with system TLS mode and the verified public URL. Keep these as verified local launch settings when the background process cannot see persisted settings. Do not take them from the phone's Start request. Companion readiness should check both the studio and phone listeners; a working studio alone does not establish phone access.

Before switching the public mount, verify that the native supervisor and receiver see the existing paired profile, including device and library records. [Packaged Windows launch environments can virtualize LocalAppData](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes); identical displayed paths can therefore expose different stores. Use read-only counts and fingerprints, without logging credentials or source text. An empty store with a passing public health check is not a working paired companion. Resolve profile access explicitly and preserve existing data before enabling the receiver's public route.

Configure the companion's real physical data directory explicitly when needed. Keep the render data directory and its parents free of symbolic links and junctions, as required by the existing render-workspace safeguards. Do not loosen those safeguards to make a background launch succeed.

Run the receiver under Pocket Hub with:

```powershell
& "$env:LOCALAPPDATA\Programs\BookPocketOpen\runtime\pythonw.exe" -I `
  "$receiverScript" --hub-exe "$hubExecutable"
```

`$receiverScript` and `$hubExecutable` identify the verified local receiver file and Pocket Hub executable. The receiver defaults to loopback port 8786 and the companion's existing user-local data directory. It forwards ordinary canonical phone routes to loopback 8785. Once its local receiver and companion health checks pass, change only the existing book mount's proxy target:

```powershell
tailscale funnel --bg --https=10000 --set-path=/bookpocket http://127.0.0.1:8786
```

Inspect Funnel routes first and preserve other applications' mounts. Restore the previous target (8785) to disable this integration without changing pairing. Keep the companion's saved gateway settings intact.

The receiver reads device credential hashes from the existing SQLite store in read-only mode, including live revocations. It cannot issue new credentials or accept a client-selected executable, path, action or app. Browser origins, remote direct peers, noncanonical routes, unknown/revoked devices and desktop admin paths are rejected. Control requests have bounded bodies, serialized dispatch, per-device limits and short-lived replay handling. Ordinary uploads and raw downloads remain streamed, with range/checksum headers preserved. No books, voice samples, model weights, authentication stores or personal Pocket Hub configuration belong in public source.

If the receiver or public tunnel is unreachable, the app reports that Pocket Hub could not be reached. If the installed PC lacks the receiver, the app explains that it is required. A failed or unverified start keeps the saved pairing and downloads; use Refresh after resolving the PC connection. See [connection controls](CONNECTION.md), [Funnel setup](FUNNEL.md) and [device checks](DEVICE-CHECK.md).
