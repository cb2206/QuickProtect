fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac auth_check

```sh
[bundle exec] fastlane mac auth_check
```

Read-only: verify API auth and print current App Store version states

### mac status

```sh
[bundle exec] fastlane mac status
```

Read-only: show version states + recent build processing status

### mac review_subs

```sh
[bundle exec] fastlane mac review_subs
```

Read-only: list review submissions (state + platform + items)

### mac review_detail

```sh
[bundle exec] fastlane mac review_detail
```

Read-only: dump the App Review contact + notes for every version

### mac cancel_review

```sh
[bundle exec] fastlane mac cancel_review
```

Remove the current version from App Store review (frees the slot to ship a new version)

### mac submit_v11

```sh
[bundle exec] fastlane mac submit_v11
```

Ship 1.1: set version to 1.1, push all localized metadata, attach build 2, and submit for review

### mac submit_v12

```sh
[bundle exec] fastlane mac submit_v12
```

Ship 1.2: set version to 1.2, push metadata, attach build 3, set review notes, submit

### mac delete_stray_ios

```sh
[bundle exec] fastlane mac delete_stray_ios
```

Cleanup: delete stray non-macOS version drafts (only deletes editable PREPARE_FOR_SUBMISSION)

### mac ci_disable

```sh
[bundle exec] fastlane mac ci_disable
```

Disable all enabled Xcode Cloud workflows (stops failing CI builds + emails; reversible)

### mac ci_status

```sh
[bundle exec] fastlane mac ci_status
```

Read-only: list Xcode Cloud products and workflows

### mac gen

```sh
[bundle exec] fastlane mac gen
```

Regenerate the Xcode project from project.yml (it is gitignored)

### mac metadata

```sh
[bundle exec] fastlane mac metadata
```

Regenerate localized metadata from APP_STORE_LISTINGS.md and push it (no binary). Safe anytime.

### mac build

```sh
[bundle exec] fastlane mac build
```

Archive a Release build and export an App Store .pkg into build/fastlane/

### mac upload_build

```sh
[bundle exec] fastlane mac upload_build
```

Upload an already-exported .pkg to App Store Connect (no submit, no metadata)

### mac release

```sh
[bundle exec] fastlane mac release
```

Build, upload the binary + metadata, and submit the current version for review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
