# Use the iPhone companion without a phone VPN

Tailscale Funnel publishes an HTTPS address for the phone API. The iPhone uses
its ordinary internet connection. The PC must remain awake with Tailscale,
Book Pocket Open and the selected narration engine running.

Use companion 0.1.8 or later and iOS 0.1.11 or later. Public HTTPS uses the
system certificate authority store; the private LAN listener keeps its saved
certificate. Device pairing and bearer authentication still apply.

## Configure the PC

Inspect `tailscale funnel status` first. Preserve other applications' routes.
The example below adds a separate path on port 10000, which is one of Funnel's
supported public ports. Replace the placeholder `companion.example` with the hostname
shown by Tailscale. Ensure this mount path is not already used.

Stop Book Pocket Open through its tray icon, then start its installed launcher
with these arguments once (the connection settings persist):

```powershell
& "$env:LOCALAPPDATA\Programs\BookPocketOpen\runtime\pythonw.exe" -I `
  "$env:LOCALAPPDATA\Programs\BookPocketOpen\launcher.py" `
  --phone-gateway-port 8785 --public-tls-mode system `
  --public-url https://companion.example:10000/bookpocket

tailscale funnel --bg --https=10000 --set-path=/bookpocket http://127.0.0.1:8785
```

Funnel strips the mount prefix before forwarding the request. The dedicated
listener accepts only the phone API. It excludes Studio, admin operations,
API documentation and browser-origin requests. Do not point Funnel at the
Studio listener or the narration engine itself.

## Connect the phone

In PC Studio, open Devices and create a new connection code. In the iPhone's
Connection tab, choose **Pair a companion**, scan the QR code and approve that request on the PC (older versions also provide pairing in Studio). The QR carries
the public HTTPS address without the private LAN certificate fingerprint.
For an existing pairing with the same PC, iOS 0.1.12 or later can switch addresses
while away from home. Open **Connection → Edit connection details** in iOS 0.1.14 or later (older versions use **Studio → … → Companion connection**), enter the
public HTTPS address including its mount path, and leave the certificate
fingerprint empty for a public certificate. Clear the old fingerprint if it is
filled in. Choose **Verify & save address**. The app
checks the existing device credential at the new address before saving it;
books, downloads and pairing remain intact. A failed check retains the old
connection. Changing the address does not require a new pairing code or PC
approval. This requires an existing valid pairing with that PC.

For a first pairing, create a fresh code in the PC Studio, enter its public
address and code on the phone, and approve the pending request on the PC.
The code expires after ten minutes. Older iOS versions need to pair again;
update the app before attempting to switch an unreachable LAN address.

Test with phone Wi-Fi and Tailscale disabled, using cellular: refresh the
connection, generate one short page with Kyon, download it and play it. Once
downloaded, audio remains available offline. A simulator pass is not a
substitute for this physical-device check.

## Disable the public connection

Remove only this mount; do not reset the entire Funnel configuration:

```powershell
tailscale funnel --https=10000 --set-path=/bookpocket off
```

Restart the companion with `--phone-gateway-port 0` to disable its saved
gateway listener. To return to LAN pairing, also supply `--public-tls-mode
pinned` and the PC's LAN HTTPS address. Never remove certificate verification
or device authentication to resolve a connection error.
