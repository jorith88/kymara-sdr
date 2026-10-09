---
name: release
description: Build Kymara as a .dmg and publish it as a GitHub release. Usage: /release <version>, e.g. /release 1.0.0-beta.2
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
- A release is always made from `main`, freshly pulled. The working tree must be clean (stop if not; never stash
  or discard someone's changes). Switch to `main` if needed (`git switch main`) and run `git pull --ff-only origin
  main`. Stop if the pull fails or if `main` has commits that are not on `origin/main` (`git rev-list
  origin/main..main` is not empty): everything in a release must already be on GitHub's `main`, e.g. merged from
  `develop` via a PR.

## 2. Test

`swift test -c release`. All tests must pass. rtk filters the output, so read the per-suite totals with
`rtk proxy swift test -c release 2>&1 | grep -E "Test Suite '.*' (passed|failed)|Executed"`.

## 3. Set the version in `Resources/Info.plist`

- `CFBundleShortVersionString` = the numeric part only (`1.0.0-beta.2` → `1.0.0`). Apple does not allow suffixes
  there; the pre-release label lives in the tag and file name.
- `CFBundleVersion` = the current value + 1. Every release gets a higher build number.

Read with `plutil -extract CFBundleVersion raw Resources/Info.plist` and write with
`plutil -replace <Key> -string <value> Resources/Info.plist`. plutil rewrites the whole file in its canonical format
(tabs, sorted keys); the file is kept in that format, so `git diff` should only show the changed values. If it shows
more, the file was hand-edited: commit the reformat separately first.

## 4. Build and verify the DMG

`./scripts/make-dmg.sh <version>` → `build/Kymara-<version>.dmg`. Then verify:

- `hdiutil verify` reports a VALID checksum.
- Mount it read-only (`hdiutil attach -nobrowse -readonly`). It must contain `Kymara.app` and an `Applications`
  symlink, `Contents/Frameworks` must contain `librtlsdr.0.dylib`, `libusb-1.0.0.dylib` and `Sparkle.framework`,
  the app's Info.plist must have the new `CFBundleVersion`, and `codesign -v --deep` must pass. Detach it afterwards.

If librtlsdr was not bundled (the build prints a warning), stop: the release would need Homebrew.

Then run `./scripts/check-licenses.sh`. It checks that the bundled-libraries table in `README.md` lists the versions
of librtlsdr, libusb and Sparkle that the app ships (the GPL requires pointing to the exact librtlsdr source). If it
reports a mismatch, replace the rows it names in `README.md` with the rows it prints, run it again until it passes,
and include `README.md` in the release commit (step 7).

## 5. Release notes

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

## 6. Update the appcast

`./scripts/update-appcast.sh <version> <notes>` signs the DMG with the Sparkle EdDSA key in the login keychain and
adds an item to `appcast.xml` (versions with `-` go in the `beta` channel). If it reports a missing signing key, stop:
the key must be restored from its backup (`generate_keys -f <file>`); a new key cannot sign updates that installed
copies accept.

## 7. Commit, tag, push the tag

- Commit `Resources/Info.plist`, `appcast.xml` and, if step 4 updated it, `README.md`: `Release <version>`
  (no Co-Authored-By trailer).
- Create an annotated tag: `git tag -a v<version> -m "Kymara <version>"`.
- `git push origin v<version>`. Push only the tag for now: installed apps read the appcast from `main`, so `main`
  is pushed after the DMG is downloadable (step 9).

GitHub sometimes returns `Internal Server Error` on push even when its status page is green. If so, retry in the
background (every 20 s, a few minutes), then check with `git ls-remote origin`.

## 8. Publish

```bash
gh release create v<version> build/Kymara-<version>.dmg --verify-tag --title "Kymara <version>" \
  --notes-file <notes> [--prerelease]
```

Add `--prerelease` when the version contains `-` (beta, rc, …). Then check
`gh release view v<version> --json url,isPrerelease,assets` and confirm the asset's state is `uploaded`.

## 9. Push main

`git push origin main` (same retry rule as step 7). This publishes the appcast, so installed apps see the update.
Confirm with `curl -sI <enclosure url from appcast.xml>` that the DMG link resolves (HTTP 302 → 200).

## 10. Report

Report the release URL, the DMG size, the test results, the build number and the appcast channel. Also mention any
push retries.
