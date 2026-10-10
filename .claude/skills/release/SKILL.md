---
name: release
description: Merge develop into main, build Kymara as a .dmg and publish it as a GitHub release. Usage: /release <version>, e.g. /release 1.0.0-beta.2
argument-hint: <version>
disable-model-invocation: true
---

Release Kymara version `$ARGUMENTS` as a .dmg on GitHub (repo `jorith88/kymara-sdr`). Follow these steps in order
and stop at the first failure and report it. Do not ask for confirmation between steps: invoking `/release` is the
go-ahead.

## 1. Check inputs and state

- The version must be semver without a leading `v` (`1.2.3` or `1.2.3-beta.1`). If `$ARGUMENTS` is empty or invalid,
  ask for the version and stop.
- The tag is `v<version>`. Stop if it already exists locally (`git tag -l`) or on GitHub (`gh release view`).
- The working tree must be clean (stop if not; never stash or discard someone's changes).
- `git fetch origin`. Local `develop` and `main` must not have commits that are not on GitHub (`git rev-list
  origin/develop..develop` and `git rev-list origin/main..main` are both empty); stop if they do: a release only
  contains what is already pushed.

## 2. Merge develop into main

A release is made from `main` with everything on `develop` merged in.

- `git switch main` and `git pull --ff-only origin main`. Stop if the pull fails.
- If `origin/develop` has commits that are not on `main` (`git rev-list main..origin/develop` is not empty), merge it
  with a merge commit: `git merge --no-ff origin/develop -m "Merge branch 'develop'"`. On a conflict, run
  `git merge --abort` and stop: conflicts are resolved on `develop`, not during a release. If there is nothing to
  merge, say so and go on.
- Do not push yet: `main` (with the merge) is pushed in step 10, after the DMG is downloadable.
- If a later step fails before step 10, the merge (and any release commit) exists only on the local `main`, and the
  next `/release` would stop at step 1. Say so in the failure report, and that `git switch main && git reset --hard
  origin/main` undoes it; don't run that yourself.

## 3. Test

`swift test -c release`. All tests must pass. rtk filters the output, so read the per-suite totals with
`rtk proxy swift test -c release 2>&1 | grep -E "Test Suite '.*' (passed|failed)|Executed"`.

## 4. Set the version in `Resources/Info.plist`

- `CFBundleShortVersionString` = the numeric part only (`1.0.0-beta.2` → `1.0.0`). Apple does not allow suffixes
  there; the pre-release label lives in the tag and file name.
- `CFBundleVersion` = the current value + 1. Every release gets a higher build number.

Read with `plutil -extract CFBundleVersion raw Resources/Info.plist` and write with
`plutil -replace <Key> -string <value> Resources/Info.plist`. plutil rewrites the whole file in its canonical format
(tabs, sorted keys); the file is kept in that format, so `git diff` should only show the changed values. If it shows
more, the file was hand-edited: commit the reformat separately first.

## 5. Build and verify the DMG

`./scripts/make-dmg.sh <version>` → `build/Kymara-<version>.dmg`. Then verify:

- `hdiutil verify` reports a VALID checksum.
- Mount it read-only (`hdiutil attach -nobrowse -readonly`). It must contain `Kymara.app` and an `Applications`
  symlink, `Contents/Frameworks` must contain `librtlsdr.0.dylib`, `libusb-1.0.0.dylib` and `Sparkle.framework`,
  the app's Info.plist must have the new `CFBundleVersion`, and `codesign -v --deep` must pass. Detach it afterwards.

If librtlsdr was not bundled (the build prints a warning), stop: the release would need Homebrew.

Then run `./scripts/check-licenses.sh`. It checks that the bundled-libraries table in `README.md` lists the versions
of librtlsdr, libusb and Sparkle that the app ships (the GPL requires pointing to the exact librtlsdr source). If it
reports a mismatch, replace the rows it names in `README.md` with the rows it prints, run it again until it passes,
and include `README.md` in the release commit (step 8).

## 6. Release notes

Write them in English to a file in the scratchpad. Base them on `git log <previous tag>..HEAD --format=%s`
(or the whole history for the first release), grouped into user-facing changes. Leave out internal commits (tests,
CLAUDE.md, scripts). Always end with this install section (the update dialog in the app shows the notes without it):

```markdown
## Install

1. Download `Kymara-<version>.dmg`, open it and drag **Kymara** to **Applications**.
2. The app is ad-hoc signed, not notarized. On first launch macOS will block it: right-click Kymara → **Open**, or
   allow it under System Settings → Privacy & Security → **Open Anyway**.

Already installed? Use **Kymara → Check for Updates…**; updates installed from within the app need no approval.
librtlsdr and libusb are bundled, so Homebrew is not required. Requires Apple silicon and macOS 14 or later.
```

## 7. Update the appcast

`./scripts/update-appcast.sh <version> <notes>` signs the DMG with the Sparkle EdDSA key in the login keychain and
adds an item to `appcast.xml` (versions with `-` go in the `beta` channel). If it reports a missing signing key, stop:
the key must be restored from its backup (`generate_keys -f <file>`); a new key cannot sign updates that installed
copies accept.

## 8. Commit, tag, push the tag

- Commit `Resources/Info.plist`, `appcast.xml` and, if step 5 updated it, `README.md`: `Release <version>`
  (no Co-Authored-By trailer).
- Create an annotated tag: `git tag -a v<version> -m "Kymara <version>"`.
- `git push origin v<version>`. Push only the tag for now: installed apps read the appcast from `main`, so `main`
  is pushed after the DMG is downloadable (step 10).

GitHub sometimes returns `Internal Server Error` on push even when its status page is green. If so, retry in the
background (every 20 s, a few minutes), then check with `git ls-remote origin`.

## 9. Publish

```bash
gh release create v<version> build/Kymara-<version>.dmg --verify-tag --title "Kymara <version>" \
  --notes-file <notes> [--prerelease]
```

Add `--prerelease` when the version contains `-` (beta, rc, …). Then check
`gh release view v<version> --json url,isPrerelease,assets` and confirm the asset's state is `uploaded`.

## 10. Push main

`git push origin main` (same retry rule as step 8). This publishes the merge from step 2 and the appcast, so installed
apps see the update. Confirm with `curl -sI <enclosure url from appcast.xml>` that the DMG link resolves
(HTTP 302 → 200).

## 11. Bring develop up to date

So the next release merges cleanly and `develop` carries the new version and appcast: `git switch develop`,
`git merge --ff-only main` (it is a fast-forward, since `main` now contains all of `develop`) and `git push origin
develop` (same retry rule). If the fast-forward fails, someone pushed to `develop` during the release: stop and report
it instead of merging. Leave the working tree on `develop`.

## 12. Report

Report the release URL, the DMG size, the test results, the build number, the appcast channel and what step 2
merged (the number of commits, or nothing). Also mention any push retries.
