# In-app update downloads

Settings checks the official repository's stable release only after a click.
When a verifiable package is available, **Download Update** opens a standard
save panel and transfers it inside Gallery, with progress and cancellation.
Closing Settings leaves an active download running; quitting the app ends it.
After verification, the user can open the package or reveal it in Finder.
Installation still consists of replacing Gallery.app normally; no updater
helper, privileged service, automatic app replacement or new permission is added.

## Package validation and resource use

- Release metadata comes from the permanent repository ID. The archive must be
  the unique uploaded `Gallery-macOS.zip` asset at that release's canonical URL.
- Use GitHub's SHA-256 asset digest, or the official `SHA256SUMS.txt` asset for
  releases without a digest. Require an unambiguous checksum for the archive.
- Stream release metadata with a 2 MiB limit, including responses without a
  Content-Length header; require the final HTTPS API endpoint.
- Follow HTTPS redirects using normal TLS validation, without cookies or stored
  credentials. Allow only github.com and GitHub's release-assets, objects and
  github-releases subdomains of githubusercontent.com, on the standard port.
  Reject unrelated hosts, embedded credentials and excessive redirect chains.
- Bound packages to 128 MiB and checksum manifests to 64 KiB. Stream downloads
  to a temporary file; verify actual length, ZIP header and SHA-256 before saving.
- Hash in the asynchronous download service using 64 KiB reads. Progress reports
  are throttled to roughly ten per second, plus a final transfer update. No idle
  timer, periodic update polling or external updater framework is introduced.
- Copy verified content to an adjacent staging file before atomically publishing
  it to the selected destination. Failed or cancelled transfers preserve an
  existing destination and clean their staging files.

The shared updater survives settings-view dismissal. Request generations reject
late cancellation/progress callbacks, and checks/downloads are single-flight.
Moving or deleting a completed package produces a retry action on the next open.

The transfer uses Apple's [asynchronous URLSession download API](https://developer.apple.com/documentation/foundation/urlsession/download(for:delegate:)).
Asset digest fields follow the [GitHub release-assets API](https://docs.github.com/en/rest/releases/assets).

## Checks

`bash Scripts/update-check.sh` uses local URLProtocol fixtures by default. It
covers manual-only checks, version comparison, single-flight requests, exact
downloaded bytes, checksum fallback, atomic replacement, invalid content/size/
HTTP failures, cancellation, settings dismissal, missing files, bounded progress
and credential-free HTTPS redirects. It compiles a library and a standalone
test executable; it does not create Gallery.app or an installation archive.
The optional `--live` path reads release metadata anonymously; it does not
download or install a real application package.
