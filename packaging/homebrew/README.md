# Homebrew cask

`keyloom.rb` is the template; `.github/workflows/release.yml` fills `@VERSION@`/`@SHA256@` and pushes it to
`tankibaj/homebrew-tap` (`Casks/keyloom.rb`) using the `TAP_GITHUB_TOKEN` secret.

Install: `brew install --cask tankibaj/tap/keyloom`

The repo is private, so release assets need auth to download. Options:

1. Make `tankibaj/keyloom` public (simplest; the cask works as is).
2. Keep it private: export `HOMEBREW_GITHUB_API_TOKEN` (read access to the repo) and add a custom
   download strategy to the cask (`url ..., using: GitHubPrivateRepositoryReleaseDownloadStrategy`).
   Not implemented here.

The build is ad-hoc signed, not notarized; the cask's `postflight` strips the quarantine attribute.
