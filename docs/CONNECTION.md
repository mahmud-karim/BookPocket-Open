# PC connection on iPhone

Open **Connection** in the bottom navigation, alongside Library, Listen and Studio.

- **Connected / Live** means the saved PC responded and accepted this phone's device credential. A saved pairing or public health response alone does not establish a connection.
- **Unavailable** means the PC could not be verified. Keep the Windows companion running and check the saved address. Reading and downloaded narration remain available.
- **Disconnect** pauses new requests from this phone and keeps the pairing, address and downloads. The setting survives closing the app. Existing PC generation continues; an already-started request can finish.
- **Connect** resumes the saved connection and checks it without requesting a new pairing code.
- **Edit connection details** opens the existing address editor. The replacement address must pass HTTPS verification and authenticated device access before it replaces the saved address. Public HTTPS uses system certificate validation; a local connection uses the certificate fingerprint supplied by the PC.
- **Forget this PC** removes the saved local pairing and its Keychain credential after confirmation. It works offline and keeps imported books and downloaded narration. It does not revoke the old device record on the PC; use Studio's existing Revoke this device action if server revocation is intended. Pair again to reconnect.

An unpaired phone shows **Pair a companion**, using the existing QR or manual pairing flow. The PC must approve a new pairing request.

The standard phone layout fits the controls above the native four-tab menu. Large accessibility text and landscape can scroll this settings screen. Listen retains its separate one-screen transport layout.

An existing public Funnel address continues to work away from home without a phone VPN. The Windows companion and Funnel must remain running. See [Funnel setup](FUNNEL.md).
