# Releasing a signed, notarized build

Local builds are ad-hoc signed (`make dist`). To publish a build other people can open without a Gatekeeper warning you need an Apple Developer ID certificate and notarization.

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
