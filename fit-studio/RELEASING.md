# Releasing FIT Studio

FIT Studio is released exactly like Dual Recorder, and uses the **same repository secrets**: the Developer ID certificate and the notarization login. If Dual Recorder releases already work, there's nothing to set up. Otherwise follow the one-time setup in [Dual Recorder's RELEASING.md](../dual-recorder/RELEASING.md#one-time-setup) first.

## Test the signing (optional)

With the workflow on the default branch (merge the pull request first), go to **Actions › FIT Studio release › Run workflow**. This builds a signed, notarized DMG and attaches it to the run without publishing anything. It takes about 10 minutes, mostly waiting for Apple.

## Publishing a release

```bash
git tag fit-studio-v1.0.0
git push origin fit-studio-v1.0.0
```

The version (`1.0.0`) comes from the tag and must go up with each release. About 10 minutes later the release appears with `FIT-Studio-1.0.0.dmg` attached. You can also create the release on GitHub (**Releases › Draft a new release**, new tag `fit-studio-v1.0.0`, **Publish**) and leave the description empty; the workflow attaches the DMG and fills in install instructions.

Both apps publish releases in this repository, so `releases/latest` points to whichever app was released last. To share FIT Studio, link to its releases instead:
**https://github.com/capceri/ftp-plus-oauth/releases?q=fit-studio&expanded=true**

## Building a release on your Mac instead

Needs full Xcode and the Developer ID certificate in your keychain.

```bash
xcrun notarytool store-credentials fit-studio   # once: asks for Apple ID, team ID and app-specific password
NOTARY_PROFILE=fit-studio scripts/release.sh 1.0.0
```

The signed, notarized DMG ends up in `build/FIT-Studio-1.0.0.dmg`. See the troubleshooting section of [Dual Recorder's RELEASING.md](../dual-recorder/RELEASING.md#troubleshooting) if signing or notarization fails.
