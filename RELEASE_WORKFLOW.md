# Phone Relay Release Workflow

This is the canonical release plan for Phone Relay. Run the complete workflow when the user clearly asks to push, publish, ship, cut, deploy, or otherwise create a release, unless the user explicitly excludes a step.

Questions, explanations, planning requests, and release-status checks do not start the workflow.

## 1. Establish the release

1. Inspect the app and website repositories, current branches, worktree changes, latest GitHub release, tags, and published website version.
2. Preserve unrelated user changes. Do not overwrite or include them without clear release scope.
3. Determine the next marketing version and build number from the highest canonical released values. Use the requested release type when one is supplied. If the version sources conflict materially, stop and ask.
4. Prepare concise release notes covering the changes since the previous release.
5. Update the app repository changelog or canonical GitHub-facing release notes.

Do not run the unit-test suite unless the user explicitly requests tests. Static validation, archive validation, signing checks, and live release verification remain required.

## 2. Set the version in Xcode with Computer

Use Computer to operate Xcode-beta when it is installed. If Xcode-beta is unavailable, use the installed Xcode app. Confirm the version and build in the Xcode interface rather than relying only on terminal edits.

1. Open `App/PhoneRelay.xcodeproj` in the available Xcode app.
2. Select the `PhoneRelayApp` target.
3. Open `General` and locate the `Identity` section.
4. Set `Version` to the new marketing version.
5. Set `Build` to the new build number.
6. Confirm both fields display the intended values and Xcode saved the project.
7. Verify the saved project values statically before archiving.

## 3. Archive and export with Xcode

Use Computer for the complete Xcode UI workflow, using the same Xcode app selected in step 2.

1. Select the production Phone Relay scheme and the correct Mac destination.
2. Choose `Product` > `Archive`.
3. Wait for a successful archive and open it in Organizer.
4. Choose `Distribute App`.
5. Choose `Direct Distribution`.
6. Complete signing, validation, and export.
7. Verify the exported app's bundle identifier, marketing version, build number, signing identity, designated requirement, and entitlements.

Do not replace the existing project app if archive, distribution, export, or validation fails.

## 4. Replace the canonical app bundle

After the export is verified, replace:

`/Users/mallenkb/Documents/Code Projects/phone mirroring/PhoneRelay.app`

with the newly exported signed app. The old bundle must not remain at that canonical path after a successful release export.

Re-read the installed bundle metadata and signature after replacement.

## 5. Build the public release artifacts

1. Use the repository's existing release and packaging scripts where applicable.
2. Produce the signed public download artifact, including the DMG and any Sparkle files required by the existing release system.
3. Update `docs/release.json` and `docs/appcast.xml` with the new version, artifact URL, signature, length, and publication metadata.
4. Verify artifact filenames, checksums, signatures, and embedded app version.

## 6. Publish the GitHub release

1. Review the release diff and keep unrelated user work out of the release commit.
2. Commit the app release changes.
3. Push the intended release branch or `main`, according to the repository's current release convention.
4. Create and push the version tag.
5. Create the GitHub release with the changelog/release notes.
6. Upload all required signed artifacts.
7. Confirm the GitHub release, tag, notes, and downloads are publicly accessible and internally consistent.

## 7. Update and publish the website

Website project:

`/Users/mallenkb/Documents/Code Projects/PhoneRelay for Android Website`

1. Update the site's displayed current version and changelog.
2. Copy the new release artifact into the site's established `public/downloads` structure.
3. Update `public/downloads/release.json` and `public/downloads/appcast.xml`.
4. Update every current download link to the new artifact.
5. Commit and push the website changes.
6. Run or trigger the website's established deployment workflow.

## 8. Verify the live website and release

After deployment, verify the live site rather than assuming the push succeeded.

1. Confirm the live site displays the new version and changelog.
2. Confirm its primary download button resolves to the new artifact.
3. Confirm the previous release is not presented as current.
4. Inspect or download the live artifact and verify its filename, checksum, signature, marketing version, and build number.
5. Confirm the live `release.json` and `appcast.xml` reference the same release and artifact.
6. Confirm the GitHub release and website agree on version, notes, and downloads.

## 9. Handoff

Report:

- marketing version and build number;
- archive and export result;
- canonical `PhoneRelay.app` replacement result;
- commit and tag;
- GitHub release URL and published artifacts;
- website commit/deployment result and live URL;
- live download, signature, checksum, `release.json`, and `appcast.xml` verification;
- anything explicitly skipped or blocked.
