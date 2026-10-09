# Task: set up signed releases for Dual Recorder and publish version 1.0.0

You're helping the owner of this Mac publish **Dual Recorder**, a macOS app they built, as a download their friends can install with a double-click. All the code and automation already exist. What's missing is the owner's Apple signing credentials stored as GitHub secrets, plus merging, testing and publishing.

Work through the steps in order. After each step, check the **Verify** line before moving on.

## Background

- Repository: https://github.com/capceri/ftp-plus-oauth (public). The app lives in the `dual-recorder/` folder.
- Open pull request with the app and the release automation: https://github.com/capceri/ftp-plus-oauth/pull/1
- Release workflow: `.github/workflows/dual-recorder-release.yml`. When a release with a tag like `dual-recorder-v1.0.0` is published, GitHub Actions does the following:
  1. Builds the app for Apple Silicon and Intel Macs.
  2. Signs it with the owner's **Developer ID Application** certificate.
  3. Has Apple notarize it.
  4. Packs it into a drag-to-Applications DMG.
  5. Attaches the DMG to the release.
- The owner has a paid **Apple Developer Program** membership.
- The workflow reads these GitHub Actions secrets, which this task creates:

  | Secret | What it is |
  |---|---|
  | `MACOS_CERTIFICATE_P12` | The Developer ID Application certificate and private key, exported as .p12 and then base64-encoded |
  | `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the .p12 |
  | `APPLE_ID` | The Apple ID email of the developer account |
  | `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID, used for notarization |

  An optional `APPLE_TEAM_ID` secret isn't needed: the workflow reads the team ID from the certificate.

## Ground rules

1. **Secret values are entered by the person, never by you.** These are the .p12 contents, the .p12 password, the app-specific password and the Mac login password. You open the right page and fill in the secret's *name*. Then ask the person to paste or type the *value* and click the button. Never type, read out, copy, store or summarize a secret value.
2. **Don't look while a secret is on screen.** When Apple shows the app-specific password, ask the person to copy it and close the dialog before your next screenshot.
3. **Never write secrets** into files, notes, chat messages, GitHub issues, pull request comments or commit messages.
4. **Stay in scope.** Don't change code, settings or anything else not listed here. If something unexpected comes up, stop and ask.
5. **Terminal:** you can't type in Terminal. When a command is needed, copy it to the clipboard and ask the person to paste it into Terminal (⌘V) and press Return.
6. **Use the browser tools for websites** (github.com, developer.apple.com, account.apple.com). Use computer use for Xcode, Keychain Access, Finder and Terminal.
7. **Ask before irreversible clicks:** merging the pull request, publishing the release and deleting files.

## Step 0: pre-flight

- Ask the person:
  - the Apple ID email of their developer account;
  - whether they're the **Account Holder** of that membership (only the Account Holder can create Developer ID certificates).
- Check whether Xcode is installed (`/Applications/Xcode.app`). This decides between the two routes in Step 1.
- Open https://github.com/capceri/ftp-plus-oauth/pull/1. The latest checks should be green and there should be no merge conflicts.

**Verify:** you know the Apple ID email, the person is the Account Holder, and the pull request is green. If the person isn't the Account Holder, stop: they need the Account Holder to create the certificate.

## Step 1: create the Developer ID Application certificate

First check whether one already exists. In Keychain Access, choose the **login** keychain › **My Certificates** and look for **Developer ID Application: <Name> (<TEAMID>)**. If it's there with a private key under it, skip to Step 2.

**Route A (Xcode installed)**
1. Open Xcode, then **Settings… › Accounts**.
2. If the Apple ID isn't listed, click **+ › Apple ID** and let the person sign in, including two-factor authentication.
3. Select the team, click **Manage Certificates…**, click **+** at the bottom left and choose **Developer ID Application**. Click **Done**.

**Route B (no Xcode)**
1. In Keychain Access, choose **Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority…**.
2. Fill in the email and name, choose **Saved to disk**, and save the request to the Desktop.
3. In the browser, open https://developer.apple.com/account/resources/certificates/add and choose **Developer ID Application**. Pick the **G2 Sub-CA** profile if asked, upload the request file and click **Download**.
4. Double-click the downloaded `.cer` file to add it to the login keychain.

**Verify:** under **login › My Certificates**, **Developer ID Application: <Name> (<TEAMID>)** is listed, and expanding it shows a private key. Note the 10-character TEAMID; it isn't a secret.

## Step 2: export the certificate as a .p12

1. In Keychain Access, under **login › My Certificates**, right-click the **Developer ID Application** certificate. Pick the certificate row, not the key under it.
2. Choose **Export "Developer ID Application: …"**.
3. Set File Format to **Personal Information Exchange (.p12)**, name it `DeveloperID`, save it to the **Desktop** and click **Save**.
4. The person types a new export password twice. Tell them to remember it for Step 3b.
5. If macOS asks for the Mac login password to allow the export, the person types it and clicks **Allow**.

**Verify:** `~/Desktop/DeveloperID.p12` exists.

## Step 3: add the GitHub secrets

Open https://github.com/capceri/ftp-plus-oauth/settings/secrets/actions/new once for each secret. You type the **Name**. The person fills the **Secret** box and clicks **Add secret**.

**3a. `MACOS_CERTIFICATE_P12`**
1. Copy this command to the clipboard: `base64 -i ~/Desktop/DeveloperID.p12 | pbcopy`
2. Ask the person to open Terminal, paste it, and press Return. It prints nothing; the encoded certificate is now on the clipboard.
3. On the new-secret page, type the name `MACOS_CERTIFICATE_P12`.
4. Ask the person to click the Secret box, press ⌘V, and click **Add secret**.

**3b. `MACOS_CERTIFICATE_PASSWORD`**
- You type the name. The person types the export password from Step 2 and clicks **Add secret**.

**3c. `APPLE_ID`**
- You type the name. The person types (or you may type) the Apple ID email and clicks **Add secret**.

**3d. `APPLE_APP_PASSWORD`**
1. In a new tab, open https://account.apple.com and go to **Sign-In and Security › App-Specific Passwords**. Click **+** and name it `Dual Recorder notarization`. The person may need to sign in or approve two-factor authentication.
2. When the password appears, ask the person to copy it and close the dialog. Don't take a screenshot while it's shown.
3. Back on the new-secret page, type the name `APPLE_APP_PASSWORD`.
4. The person pastes the password and clicks **Add secret**.

**Verify:** https://github.com/capceri/ftp-plus-oauth/settings/secrets/actions lists `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID` and `APPLE_APP_PASSWORD`. Values are hidden; that's normal.

**Clean up:**
- With the person's OK, move `~/Desktop/DeveloperID.p12` to the Bin, plus the certificate request file if Route B created one.
- Ask the person to copy any harmless text so the encoded certificate is no longer on the clipboard.

## Step 4: merge the pull request

1. Open https://github.com/capceri/ftp-plus-oauth/pull/1.
2. If it's a draft, click **Ready for review**.
3. Confirm with the person, then click **Merge pull request** and **Confirm merge**.

**Verify:** the pull request shows **Merged**, and https://github.com/capceri/ftp-plus-oauth/actions lists a workflow called **Dual Recorder release**.

## Step 5: test signing and notarization (publishes nothing)

1. Open https://github.com/capceri/ftp-plus-oauth/actions/workflows/dual-recorder-release.yml.
2. Click **Run workflow**, keep branch **main**, set version `0.0.1`, and click **Run workflow**.
3. Wait. It usually takes 10–20 minutes, mostly waiting for Apple. Refresh every few minutes.
4. **If it's green:** open the run, check that the last lines of the **Build, sign, notarize and package** step say `is signed, notarized and ready to share`, and that the run has an artifact called **Dual-Recorder-0.0.1**.
5. **If it's red:** open the failed step, read the last 40 or so lines, and use the troubleshooting table below. After fixing a secret, run the workflow again. If the error isn't in the table, stop and show the person the error text. Error logs don't contain secret values.

**Verify:** a green run with the Dual-Recorder-0.0.1 artifact.

## Step 6: publish version 1.0.0

1. Open https://github.com/capceri/ftp-plus-oauth/releases/new.
2. Under **Choose a tag**, type `dual-recorder-v1.0.0` and pick **Create new tag: dual-recorder-v1.0.0 on publish**. Set the target to **main**.
3. Set the title to `Dual Recorder 1.0.0`. Leave the description empty; the workflow fills in install instructions.
4. Keep **Set as the latest release** ticked.
5. Confirm with the person, then click **Publish release**.
6. Wait 10–20 minutes, then refresh the release page.
   - If two **Dual Recorder release** runs appear for this tag, that's expected: the second one notices the DMG is already attached and finishes quickly.
7. Once **Dual-Recorder-1.0.0.dmg** is under **Assets**, download it and open it from Downloads. A window should show the Dual Recorder icon, an arrow and the Applications folder.
8. Drag the app to Applications, replacing the existing copy is fine because settings are kept, then open it.
   - A standard prompt like *"Dual Recorder is an app downloaded from the Internet. Are you sure you want to open it?"* is normal and fine.
   - Any message like "Apple could not verify…" or "unidentified developer" means signing didn't work. Report it.

**Verify:** the release page has the DMG and install notes, and the downloaded app opens without an "unidentified developer" warning.

## Step 7: report back

Tell the person:
- the link to share: **https://github.com/capceri/ftp-plus-oauth/releases/latest**
- which steps were completed, and anything that didn't go to plan.

For future versions, they publish a new release in the same way with a higher number, e.g. `dual-recorder-v1.0.1`.

## Troubleshooting

| Error in the workflow log | Cause and fix |
|---|---|
| `The MACOS_CERTIFICATE_P12 secret isn't set` | Secret missing or misnamed. Redo Step 3a. |
| `MAC verification failed during PKCS12 import (wrong password?)` | `MACOS_CERTIFICATE_PASSWORD` doesn't match the export password. Update that secret, or redo Steps 2 and 3a–3b with a new password. |
| `No "Developer ID Application" identity in the certificate` | The wrong certificate was exported (e.g. *Apple Development* or *Developer ID Installer*), or it had no private key. Redo Step 2 with the right certificate, then Step 3a. |
| `No notarization credentials` | `APPLE_ID` or `APPLE_APP_PASSWORD` is missing. Redo Step 3c or 3d. |
| `HTTP status code: 401` or `Invalid credentials` | The Apple ID or app-specific password is wrong. Create a new app-specific password and update `APPLE_APP_PASSWORD`. |
| `A required agreement is missing or has expired` (HTTP 403) | The person must accept the latest agreements at https://developer.apple.com/account, then re-run. |
| `Set APPLE_TEAM_ID` | Add an `APPLE_TEAM_ID` secret containing the 10-character team ID from the certificate name. |
| `Notarization failed (status: Invalid)` followed by a log | Apple rejected the app. Don't change any code: show the person the `issues` section of the log. |
| No **Run workflow** button, or the workflow isn't listed | The pull request isn't merged yet. Do Step 4. |
