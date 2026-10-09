# Releasing Dual Recorder

Releases are DMG installers that are signed with your Developer ID and notarized by Apple. Anyone can download one, open it, drag the app into Applications and run it without Gatekeeper warnings. GitHub Actions builds and publishes them when you push a version tag.

## One-time setup

Everything secret goes into **GitHub › capceri/ftp-plus-oauth › Settings › Secrets and variables › Actions › New repository secret**. Never commit these values or paste them into chats or issues.

### 1. Developer ID certificate

1. In Xcode: **Settings › Accounts**, select your team, **Manage Certificates…**, click **+** and choose **Developer ID Application**. Only the account holder can create one.
2. Open **Keychain Access** and go to the *login* keychain › **My Certificates**. Find **Developer ID Application: Your Name (TEAMID)** and check it has a private key (expand it).
3. Right-click it, choose **Export…**, and save it as `DeveloperID.p12` with a strong password.
4. In Terminal, copy it as text: `base64 -i DeveloperID.p12 | pbcopy`
5. Add two secrets:
   - `MACOS_CERTIFICATE_P12`: paste the copied text
   - `MACOS_CERTIFICATE_PASSWORD`: the export password
6. Delete `DeveloperID.p12`.

### 2. Notarization login (pick one)

**A. Apple ID with an app-specific password (simplest)**

1. At [account.apple.com](https://account.apple.com), go to **Sign-In and Security › App-Specific Passwords** and create one called "Dual Recorder notarization".
2. Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) › Membership details.
3. Add three secrets:
   - `APPLE_ID`: your Apple ID email
   - `APPLE_APP_PASSWORD`: the app-specific password
   - `APPLE_TEAM_ID`: e.g. `AB12CD34EF`

**B. App Store Connect API key**

1. In App Store Connect, go to **Users and Access › Integrations › App Store Connect API** and create a team key (*Developer* access is enough). Download the `.p8` file; you can only download it once.
2. Add three secrets:
   - `NOTARY_API_KEY`: the whole contents of the `.p8` file, including the BEGIN/END lines
   - `NOTARY_API_KEY_ID`
   - `NOTARY_API_ISSUER_ID`

### 3. Test it

With the workflow on the default branch (merge the pull request first), go to **Actions › Dual Recorder release › Run workflow**. This builds a signed, notarized DMG and attaches it to the run, without publishing anything. It takes about 10 minutes, mostly waiting for Apple.

## Publishing a release

```bash
git tag dual-recorder-v1.0.0
git push origin dual-recorder-v1.0.0
```

The version (`1.0.0`) is taken from the tag and must go up each release. About 10 minutes later the release appears at
**https://github.com/capceri/ftp-plus-oauth/releases/latest** with `Dual-Recorder-1.0.0.dmg` attached. Share that link.

You can also create the release on GitHub (**Releases › Draft a new release**, new tag `dual-recorder-v1.0.0`, **Publish**). The workflow then attaches the DMG to it.

## Building a release on your Mac instead

Needs full Xcode and the Developer ID certificate in your keychain.

```bash
xcrun notarytool store-credentials dual-recorder   # once: asks for Apple ID, team ID and app-specific password
NOTARY_PROFILE=dual-recorder scripts/release.sh 1.0.0
```

The signed, notarized DMG ends up in `build/Dual-Recorder-1.0.0.dmg`.

## Troubleshooting

- **"No Developer ID Application identity"**: the exported certificate is a different type (e.g. *Apple Development*), or it was exported without its private key.
- **Notarization status "Invalid"**: Apple's log is printed in the job output and says which file failed and why.
- **"No notarization credentials"**: none of the secret sets in step 2 is complete.
