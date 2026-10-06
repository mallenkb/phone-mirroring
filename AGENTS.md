# Project instructions

## Release trigger

When the user clearly asks to "push a release" or uses an equivalent instruction such as "publish a release," "ship a release," "cut a release," "deploy a release," "release the app," or "push the new version," execute the complete workflow in `RELEASE_WORKFLOW.md` unless the user explicitly excludes a step.

Treat a clear release command as authorization for the normal in-scope release operations described there: versioning, Xcode archive and Direct Distribution export through Computer, replacement of the canonical project `PhoneRelay.app`, packaging, commits, pushes, tagging, GitHub release publication, website updates and deployment, and live verification. Use Xcode-beta when it is installed. If it is unavailable, use the installed Xcode app. Do not ask the user to restate the workflow.

Do not trigger the workflow when the user is only asking a question, requesting an explanation or plan, reviewing release status, or explicitly says not to act yet.

The Xcode version and build number must be changed and visually confirmed in the `PhoneRelayApp` target's `General` > `Identity` section using Computer before archiving. Use Xcode-beta when available, otherwise use the installed Xcode app. After a successful export, always replace `/Users/mallenkb/Documents/Code Projects/phone mirroring/PhoneRelay.app` with the newly exported and verified signed application.

Always update and deploy `/Users/mallenkb/Documents/Code Projects/PhoneRelay for Android Website`, then verify the live version, changelog, download link and artifact, checksum, signature, `release.json`, and `appcast.xml`.
