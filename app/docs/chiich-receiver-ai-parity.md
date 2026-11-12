# Native receiver AI parity — 2026-11-04

This overlay extends the released Element X build 1.0.0 (4). The native SDK,
active Matrix session, original messages, native player and receiver-only policy
remain authoritative. No composer/send processing, account migration or provider
credential is added.

## Audio preparation and safe retry

Native media download is unpaid preparation. Leaving a voice message before
download completion creates no attempted-operation marker; returning can start
its first ASR. Paid results still survive scrolling. Unsupported or oversized
media stays native and does not enter an automatic preparation loop.

Only the exact authenticated HTTP 429 response with errcode
M_CHIICH_AI_AI_BUSY, error AI_BUSY and boolean retryable=true permits a retry.
It is issued before the server creates a paid claim. The same payload and ID are
retried at most three times, after 500, 1500 and 3000 ms. Its local pending marker
is released only after that certified response. Cancellation, exhausted retry,
session change and disabled AI stop the sequence.

Every other failure retains uncertain paid markers across relaunch. In
particular, generic 429, rate limit, missing provider, invalid responses and
network ambiguity do not trigger a paid retry.

## Shared preferences through the pinned SDK

The existing Matrix account-data event one.chiich.receiver_ai stores enabled and
language. Native reads and writes use SDK ClientProtocol.accountData(eventType:)
and setAccountData(eventType:content:) from Matrix Rust SDK 26.10.24. The ClientProxy
bridge validates the same account/device/session before and after the SDK call;
it adds no separate authentication or credential getter.

The existing web setting wins over legacy native defaults. If the event is
absent after native initial sync, the previous per-account UserDefaults choice is
migrated. An empty SDK cache before first sync must not overwrite the old web
choice or enable paid processing using a default. Explicit offline changes are
persisted and merged by changed field with the next account setting. Writes are
serialized; a delayed local SDK sync echo cannot undo the acknowledged choice.
Failed writes retain their pending fields, and logout rejects late results.

The pinned AccountDataEventType observer only exposes standard Matrix types and
has no custom-event case. Native sync/foreground callbacks therefore refresh
through the supported SDK getter. While active, a cancellable 15-second loop
reads only that local SDK store; it adds no network polling or parallel /sync.
Backgrounding/logout stops the loop.

The target language accepts the same valid language-code contract as the
existing backend. The native searchable language sheet uses Foundation's ISO
language list and retains any valid existing selected code. The previous
RU/ZH/EN-only restriction and forced English fallback for other valid languages
are removed. Interface translations still use the native locale resources.

## Reusing existing web/native results

Native IDs retain the chiich-receiver-ios-v1 namespace and all existing
uncertain local claims. Simply switching to web IDs would bypass those claims;
web revision/media JSON signatures also differ from native signatures.

When the owned gateway advertises capabilities.cacheLookup, native first calls
its read-only /cache endpoint. Original text and target language determine the
bounded equivalent-payload lookup; only original text opts into the old web
rewrite_or_translate/und operation. Audio lookup uses the exact receiver-v1
MIME-plus-bytes SHA-256 fingerprint. Audio-transcript translation never opts into
the combined rewriting operation.

Ready results are reused without a provider request. Pending, uncertain and
expired results block a new purchase. An invalid response, read failure or cache
corruption never falls back to paid work. After a confirmed miss, opt-in assist
requests or /transcribe-shared retain the existing native ID. The companion
backend rechecks reuse under its existing atomic claim lock, closing the race
between lookup and purchase without changing old clients' routes or payloads.

If the optional capability is absent during rolling deployment, native preserves
the old endpoint behavior with the same IDs and persistent claims. Shared result
reuse activates only when the backend explicitly supports it.

## Verification boundary

New synthetic native cases cover delayed audio download and scrolling, bounded
busy retries, cancellation, restart after unpaid rejection, existing uncertain
claims, additional languages, cache hits/misses/blocked claims/failures, exact
Python-compatible audio fingerprint and preservation of original transcripts.
CHIICHReceiverAIPreferencesTests covers migration, first-sync gating, offline
restart, cross-device field merge, delayed SDK echoes, rapid serialized changes,
malformed settings and logout during a pending read.

These tests require the pinned macOS/Xcode simulator workflow. No production
Matrix/AI call or physical-iPhone acceptance is claimed by source preparation.
The companion backend's 47 SQL/crypto/synthetic-provider tests passed locally;
runtime build, upload, tester distribution and device acceptance remain distinct.
