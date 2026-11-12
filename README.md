# CHIICH iOS

Open source for CHIICH iOS **1.0.0, build 10**, based on Element X iOS.

## Source

- `app/`: complete prepared application source, CHIICH changes, native extensions, resources, notices and pinned package lockfiles.
- `src/element-x-ios/`: original CHIICH patches, integrity manifest, preparation/signing-support scripts and tests.
- `source-dependencies/`: pinned source archives, checksums and dependency inventory. Its manifest identifies components provided by exact upstream links, registry dependencies and the auxiliary development-tool license exception.
- `SOURCE-PROVENANCE.json` and `SHA256SUMS`: revision, build configuration and application file hashes.
- `build-reference/`: inactive text copies of build 10 workflows, containing secret variable names but no credentials.

Original native revision: `3dc8d5676d43c68664aa0d0ed0410e9cdd0547ab`. Element X: `27cdd980dcce083b939935521fdcc9a754e18244` (`release/26.10.8`). Source publication does not change the installed application.

## Build

Use macOS and Xcode **27.0 (27A266a)**. Build 10 used XcodeGen **2.46.0**, SwiftGen **6.6.3**, and Sourcery **2.4.1**. Install these tools and Git LFS, then:

```sh
git clone https://github.com/CC-P2/chiich-ios.git
cd chiich-ios
python3 scripts/check_source.py
shasum -a 256 -c SHA256SUMS
cd app
xcodegen
xcodebuild archive -project ElementX.xcodeproj -scheme ElementX \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath ../CHIICH-unsigned.xcarchive -derivedDataPath ../DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
```

Swift Package Manager obtains exact versions from the lockfiles. Building native dependencies from source uses their included upstream scripts/toolchains. Private Apple credentials are not needed to inspect source or compile unsigned code. Signing/distribution require your own Apple configuration and, where necessary, distinct bundle identifiers.

Run `python3 scripts/materialize_source.py` to reproduce source from original patches and pinned archives. This verifies checksums, recreates `app/` and downloads dependency sources. It does not build, sign or upload an app. Local edits in generated `app/` are replaced.

Configuration is `links-only`: Universal Links are configured; production push is not enabled. Test screenshot baselines remain upstream Git LFS pointers; build-required development media is included as verified actual bytes. The proprietary Enterprise submodule is not used or included. This publication does not claim a new Xcode compilation.

## License

The CHIICH modifications and combined application are published under **GNU AGPL version 3 or later**. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Original notices remain in `app/` and dependency archives. Third-party packages retain their own licenses. Branding does not grant an endorsement or trademark license for another app.

Source publication does not establish Apple approval or an Element commercial license/App Store exception. No such agreement is included.

Support: [support@chiich.one](mailto:support@chiich.one). [Privacy](https://chiich.one/help/privacy.html).
