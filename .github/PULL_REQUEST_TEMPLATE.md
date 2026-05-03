<!-- Replace this comment with a 1–2 sentence summary of what changed and why. -->

## What

-

## Why

-

## How verified

- [ ] `xcodegen generate && xcodebuild -scheme ThreeMFQuickLook -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` passes
- [ ] `xcodebuild -scheme ThreeMFTests -configuration Debug test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` passes (XCTest + swift-testing suites)
- [ ] `swift build` (SwiftPM) passes with zero source warnings
- [ ] `swiftformat Sources Tests --lint` is clean
- [ ] If user-visible: tested manually in the Quick Look extension / Spotlight / Finder

## Checklist

- [ ] Tests added or updated for new behavior
- [ ] `CHANGELOG.md` `[Unreleased]` updated
- [ ] `MARKETING_VERSION` bumped if shipping a release
- [ ] No new compiler warnings
- [ ] No new SwiftFormat violations
- [ ] No `Co-Authored-By` lines in commits
