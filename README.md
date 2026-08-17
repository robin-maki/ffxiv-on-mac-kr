# FFXIV on Mac KR

Unofficial native macOS launcher for the Korean FINAL FANTASY XIV client.

- Actoz login through the official launcher page
- Official full-file install and ZiPatch updates
- Standalone XIV on Mac runtime; CrossOver is not used

The app is experimental, unsigned, and intended for Apple Silicon Macs.

```sh
swift test --disable-sandbox
scripts/package.sh
```

On first game launch, the app downloads the official XIV on Mac runtime
archive directly from `softwareupdate.xivmac.com` and verifies its pinned
SHA-256 before extracting only Wine and `d3dcompiler_47.dll`.

This project is licensed under GPL-3.0. Third-party components retain their
own licenses. FINAL FANTASY XIV is a trademark of Square Enix. This
project is not affiliated with Square Enix, Actoz Soft, CodeWeavers, or XIV on
Mac.
