# Releasing a signed, notarized build

For an ad-hoc local build, use `make dmg SIGN_ID=-`. By default, Make uses an installed Developer ID identity when one is available. To publish a build other people can open without a Gatekeeper warning you need an Apple Developer ID certificate and notarization.

## One-time setup

1. In Xcode, open **Settings → Accounts**, select your team, choose **Manage Certificates…**, click **+** and add **Developer ID Application**. (Apple Development certificates cannot be used for distribution.)
2. Confirm the identity exists: `security find-identity -v -p codesigning` should list `Developer ID Application: … (TEAMID)`.
3. Create an app-specific password at appleid.apple.com, then store notarization credentials once:

   ```sh
   xcrun notarytool store-credentials mica-notary --apple-id YOU@example.com --team-id TEAMID
   ```

## Each release

```sh
make notarize SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

This signs the helper, icon tool and app, notarizes and staples the app, packages it, then notarizes and staples the DMG. It regenerates `SHA256SUMS.txt` after the final stapling operation and runs `spctl --assess`. Verify with `cd build && shasum -a 256 -c SHA256SUMS.txt` before attaching the DMG, ZIP and checksum manifest to a release. [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) describes attaching the ticket to the distribution artifact.

The published [alpha 8 release](https://github.com/megasoft1978/mica-terminal/releases/tag/v0.1.0-alpha.8) is Developer ID signed. On 2026-09-30, downloaded app signature verification and app/DMG stapled-ticket validation passed. This audit did not submit a new build for notarization.

The alpha 8 ZIP matches its published checksum, but the DMG does not: published `dfd4207684c67f53ebc8ccdb214c73fd1a3222af6821ecc2d8e5af42d460e036`, downloaded `952c2ff4a2c5213215e8fe6ee0ad4fdb186dc7112dba8addce8ef1536e00adaf`. The old recipe generated the manifest before stapling the DMG, which can explain the mismatch. The local recipe now hashes after stapling, and CI verifies the manifest before publishing. The existing release manifest still requires correction; it was not changed by this audit.

## Cutting a release

1. Bump `MICA_VERSION`/`MICA_REVISION` in `include/mica.h` and `CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist` (keep them equal).
2. `make validate && make dmg` (or `make notarize SIGN_ID="Developer ID Application: … (TEAMID)"` once the certificate and notary profile exist).
3. Publish the verified local artifacts and push the tag:

   ```sh
   TAG=v0.1.0
   gh release create "$TAG" build/Mica.dmg build/Mica.zip build/SHA256SUMS.txt \
     --title "Mica ${TAG#v}" --generate-notes
   git tag "$TAG"
   git push origin "$TAG"
   ```

   The `Release` workflow checks the tag against `Info.plist`, then builds and publishes when repository secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_APP_PASSWORD` are configured. If a release already exists for the pushed tag, it skips the CI build; this supports publishing the locally signed and notarized artifacts above without duplicating them. The workflow never publishes an ad-hoc fallback. Local ad-hoc packaging remains available with `make dmg SIGN_ID=-`.
4. After verifying the uploaded assets, update README/site download links and release notes to the new tag. Update the site’s visible version, ZIP size and JSON-LD `softwareVersion`, `fileSize` and `downloadUrl`; regenerate the inline-script CSP hash after changing JSON-LD. The current links pin the verified alpha 8 ZIP while its alternative DMG manifest awaits correction. [GitHub’s release-link documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) describes moving latest-release links; pinned asset URLs keep the download consistent with the displayed version and audit.
