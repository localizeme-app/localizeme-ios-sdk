# Releasing

A release is a git tag. Swift Package Manager reads versions straight from
the tags of this repository; there is nothing to upload.

1. Set `sdkVersion` in `Sources/LocalizeMe/API.swift` to the new version. The
   SDK reports it in every request, so it has to match the tag.
2. Commit, then tag and push: `git tag -a 0.1.0 -m 0.1.0 && git push origin 0.1.0`.
   Tags are plain semantic versions with no `v` prefix, or SPM ignores them.
3. Mark the release on GitHub (`gh release create 0.1.0 --verify-tag`), with
   `--prerelease` for a beta.

Apps only resolve a pre-release such as `0.1.0-beta.1` when they ask for it
with an exact version. The first release without a suffix lets them use the
default "Up to Next Major Version" rule.
