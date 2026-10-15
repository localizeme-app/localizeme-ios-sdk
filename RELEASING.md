# Releasing

A release is a git tag. Swift Package Manager reads versions straight from
the tags of this repository; there is nothing to upload.

1. Set `sdkVersion` in `Sources/LocalizeMe/API.swift` to the new version. The
   SDK reports it in every request, so it has to match the tag.
2. Commit, then tag and push: `git tag -a 1.0.1 -m 1.0.1 && git push origin 1.0.1`.
   Tags are plain semantic versions with no `v` prefix, or SPM ignores them.
3. Mark the release on GitHub (`gh release create 1.0.1 --verify-tag`).

Apps follow the default "Up to Next Major Version" rule, so a minor or patch
release reaches them on their next package update and must not break source.
Breaking changes wait for the next major version. A pre-release (`2.0.0-rc.1`)
is only resolved by apps that ask for it with an exact version; mark it with
`--prerelease`.
