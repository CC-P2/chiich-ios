# Native CHIICH receiver AI

This overlay targets Element X 27cdd980dcce083b939935521fdcc9a754e18244 and Matrix Rust SDK 26.10.24. It uses the existing authenticated Synapse receiver-v1 module. Provider base URL, models, credentials, durable billing claims and encrypted results stay on the existing backend. There is no sender/composer interception.

## Native extension boundary

The pinned Rust SDK ClientProtocol does not expose a generic authenticated HTTP request for custom Synapse modules. ClientProxy provides one narrowly typed bridge to GET `/_synapse/client/chiich/receiver-ai/status`, POST `/assist`, and raw native-decrypted audio POST `/transcribe/<requestID>`. The only origins are `https://matrix.chiich.one` and the existing `https://chiich-matrix.onrender.com`. The bridge reads its current SDK session internally and checks account, device, access token and homeserver again after the response. No credential getter is added to UI code.

URLSession is ephemeral, rejects redirects, has finite timeouts and reads at most 200 KB of response bytes. Exact HTTP 401 JSON `M_UNKNOWN_TOKEN` is forwarded to the existing `receivedAuthError(isSoftLogout:)` callback only after the same-session check. Other 401/403/provider errors disable AI without replacing the native login/logout flow. There is no token refresh or paid-request retry in this bridge.

## Receiver behavior

Only visible, remote, decrypted, incoming native text/audio/voice events in normal room/thread timelines start processing. Same-language text is rewritten; foreign text is translated from its original; an unknown language uses the existing combined backend operation. Incoming audio is downloaded/decrypted through MediaProvider, with the configured native content scanner respected. Known sizes are checked before download and actual bytes before ASR; the existing native media download is not a new streaming downloader. ASR retains the native player and shows captions below it. Only a known foreign original transcript is translated; transcripts are never rewritten. Translation failure keeps a successful original transcript.

Native text/media models, outgoing events, message sending, reply/copy/forward data and player controls remain unchanged. The native message menu reveals original text or original transcript from local presentation state without an HTTP request. The header uses the shared CHIICH brand mark and real service availability, with RU/ZH/EN target language controls. Unsupported/unavailable processing leaves normal Matrix rendering.

Account-owned services and visibility owners scope all data. Native edit event IDs and timestamps prevent stale timeline owners from rolling back a newer revision. Retired source hashes and redaction tombstones prevent known stale sources from reappearing. Rendering checks the current original-content fingerprint, so a stale native row cannot show another revision's processed text. Temporary undecryption suspends processing without creating a redaction tombstone. Visible and active source identities are pinned during metadata eviction.

## Claims and bounds

The native namespace is `chiich-receiver-ios-v1`. It is distinct from the web namespace: web/native cost deduplication is not claimed. Native request IDs derive from account, room, remote event, revision, original source and operation slot/target language. The assist slot is independent of the local language classifier: classifier changes can cause the backend to reject a payload conflict, but cannot create a second paid slot for the same source and target. ASR has one language-independent original-audio slot.

Before any potentially paid HTTP request, an atomic protected file stores its opaque ID. No token or message text is written there. Successful responses remove the pending ID; interrupted/uncertain requests remain blocked across relaunches. A successful-result request after relaunch uses the same ID, so the existing backend can only return its encrypted cached result or a terminal failure; expired/pending/uncertain server claims are never purchased again. Results are held only in bounded memory. No automatic retry is made, including after explicit status refresh.

Bounds: queue 24; result cache 64 and 500,000 UTF-16 units; source metadata 512 with visible/active pinning; each redaction/superseded-source ledger 4,096; persistent unsettled claims 512; text input 12,000 UTF-16 units; result 24,000; audio 25,000,000 bytes. Exhausted or unavailable claim storage disables new AI calls. A full revision ledger fails closed for that account service until a fresh session service is created. These conservative limits preserve ordinary chat.

## Verification

`CHIICHReceiverAIRequestTests` and `CHIICHReceiverAIServiceTests` use synthetic Matrix/AI data and a fake durable-cache gateway. They cover routes, payload bounds, deterministic IDs, same/foreign text, ASR/no voice rewrite, original toggling, partial voice success, missing provider, outgoing exclusion, uncertain-call relaunch, successful cache replay, classification changes, edits, redactions, stale owners, session invalidation, bounded pagination and exact Matrix soft-logout parsing. Linux SwiftFormat and SwiftLint checks are source checks only; compilation, unit execution and previews require the macOS simulator workflow. No paid provider or physical-iPhone acceptance test is claimed by this source change.
