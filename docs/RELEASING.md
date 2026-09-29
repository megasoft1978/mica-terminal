# Releasing a signed, notarized build

Local builds are ad-hoc signed (`make dmg`). To publish a build other people can open without a Gatekeeper warning you need an Apple Developer ID certificate and notarization.

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

This signs the helper, icon tool and app with the hardened runtime, Apple's secure timestamp (required for notarization) and the microphone entitlement, zips the app, submits it with `notarytool --wait`, staples the ticket, re-zips and runs `spctl --assess`. Attach `build/Mica.zip` to a GitHub release.

`make notarize` has not been run end to end yet because no Developer ID certificate is installed on the development machine.

## Cutting a release

1. Bump `MICA_VERSION`/`MICA_REVISION` in `include/mica.h` and `CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist` (keep them equal).
2. `make validate && make dmg` (or `make notarize SIGN_ID="Developer ID Application: … (TEAMID)"` once the certificate and notary profile exist).
3. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`. The `Release` workflow checks the tag against `Info.plist`, runs the tests, builds `Mica.dmg`, `Mica.zip` and `SHA256SUMS.txt`, and publishes them. It signs and notarizes when the repository secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_APP_PASSWORD` are set; otherwise the build is ad-hoc.
4. The README and site link to `releases/latest/download/Mica.dmg`, so they follow each new release without edits.
