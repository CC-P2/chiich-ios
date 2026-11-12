# CHIICH for iOS — Element X base

Separate native client, authorized by the owner on 2026-11-01. The current
Element Web 1.12.32 at chiich.one stays deployed and working alongside it.

## Pinned source

- Official Element X iOS `release/26.10.8`, commit
  `27cdd980dcce083b939935521fdcc9a754e18244`.
- Matrix Rust SDK 26.10.24, exact upstream pin retained.
- Native SwiftUI interface, native composer/media/sync/session/keychain lifecycle.
- Own existing server `https://matrix.chiich.one`, identity `chat.chiich.one`.
- Existing Synapse Apple/Google SSO via the SDK's `startSsoLogin`/`SsoHandler`.
- No MAS migration or new account database; the native return allowlist change
  is recorded separately in `NATIVE-EXPERIENCE.md`.

`upstream.lock.json` records source and patch checksums. The upstream tree is not
duplicated into this web repository: preparation applies the exact reviewed
patches to the exact upstream source. The complete derived tree is generated
locally or in CI, preserving upstream copyright and licenses.

## Prepare and build

Python 3.12+ and Git are needed for source preparation. Xcode 27 on an Apple
Silicon Mac is required for the pinned native project (iOS 18.5 minimum).

For source inspection, without Xcode:

```sh
python3 src/element-x-ios/prepare.py --output .build/chiich-ios
```

For an actual build, use a clean checkout of the pinned public upstream, hydrate
its native development media with Git LFS, then apply our source configuration:

```sh
git clone --no-recurse-submodules https://github.com/element-hq/element-x-ios.git .build/chiich-ios
git -C .build/chiich-ios checkout --detach 27cdd980dcce083b939935521fdcc9a754e18244
git -C .build/chiich-ios lfs pull --include='Components/DevelopmentAssets/Media/**' --exclude=''
python3 src/element-x-ios/prepare.py --source .build/chiich-ios
cd .build/chiich-ios
brew install xcodegen swiftgen sourcery
xcodegen
xcodebuild -project ElementX.xcodeproj -scheme ElementX -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath ../DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Archive preparation leaves upstream Git LFS pointers unchanged. Use the Git
checkout route above for builds/tests needing development media. The private
Enterprise submodule is optional and is never fetched.

## Delivery status and limits

The current installed trial is **1.0.0 (2)**, from source `448076e3090c620c56046ae1179d153d77ede388`.
Its [simulator run](https://github.com/CC-P2/chiich/actions/runs/41435471619)
passed 46 native tests (55 executions), and its
[signed upload](https://github.com/CC-P2/chiich/actions/runs/41438674556)
succeeded on 2026-11-02. On 2026-11-03, build 2 was assigned to the existing
internal TestFlight group and showed Testing. The owner then confirmed the app
works on the iPhone. This is acceptance of that trial, not of subsequent changes.

The manual device archive/signing/upload workflow is documented in
`TESTFLIGHT.md`. Its default mode compiles the device target without credentials.
The configured signing assets belong to the owner's Apple team. Push remains
disabled in this trial; see `BUILD-NOTES.md` for service-specific limits.

The next native change ports the approved design, receiver-only AI and a shorter
login entry. Its behavior and separate acceptance status are recorded in
`NATIVE-EXPERIENCE.md`. The subsequent owner-authorized feature port is recorded
in `FEATURE-PARITY.md`: receiver-AI recovery/shared settings/cache, public names
and native invitations, direct picker sending and native password UIA. Existing
server aliases, accounts and rooms remain intact. The current profile supports
the invitation custom-scheme fallback; APNs and Universal Links require the
Apple provisioning prerequisites described in that document.

Required acceptance: a real iPhone, Apple and Google login returning to the same
Matrix account, cancellation/retry/session restoration, messages and photo/video
playback with another test account. Synthetic tests or a simulator build do not
prove these scenarios. Backups of the current web/server code are retained at
least through 2026-11-08; these refs are not database backups.

Upstream licensing remains applicable (AGPL-3.0 or a separately obtained
commercial license). Retain upstream notices and provide the corresponding
source when distributing the modified app under AGPL.
