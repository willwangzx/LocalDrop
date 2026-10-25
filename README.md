# LocalDrop

Native iPhone + Windows prototype for direct, bidirectional file transfers on a trusted local network. SwiftUI on iOS 17+; WPF and ASP.NET Core on Windows 10/11. No cloud storage or relay. No third-party runtime libraries.

## Windows

Install the .NET 8 SDK on Windows. In PowerShell from this folder:

```powershell
dotnet run --project windows/LocalDrop/LocalDrop.csproj
```

Allow LocalDrop on **private networks only** in Windows Firewall. The app listens on TCP 45872. If connecting fails, check the firewall, both devices' network, and router client isolation. Guest networks often block device-to-device traffic. Multiple addresses may appear when a VPN or virtual adapter is installed; use your Wi-Fi/Ethernet adapter's private IPv4 address.

Create a self-contained Windows x64 distribution:

```powershell
dotnet publish windows/LocalDrop/LocalDrop.csproj -c Release -r win-x64 --self-contained true -o release/windows
```

Distribute the entire output folder; launch LocalDrop.exe. ARM64 Windows builds can use `win-arm64` instead.

## iPhone

Building and installing the iPhone app requires a Mac with Xcode 15+ and an Apple signing team. On that Mac, install XcodeGen and generate the project:

```sh
brew install xcodegen
cd ios
xcodegen generate
open LocalDrop.xcodeproj
```

Select the LocalDrop target, choose your signing team, change `com.example.LocalDrop` to a unique bundle identifier, select your connected iPhone, and Run. Enable Developer Mode on the phone if Xcode requests it. This source is not a signed IPA or App Store release.

## Transfer

1. Put the iPhone and Windows PC on the same trusted private network. Ethernet for the PC is also fine when the router permits communication with Wi-Fi clients.
2. Open the Windows app. Enter its address and pairing secret in the iPhone app; tap Connect and allow Local Network access.
3. iPhone → Windows: choose photos/videos or files. Completed transfers appear under Documents/LocalDrop/Received on Windows. A unique prefix prevents overwriting existing files.
4. Windows → iPhone: Add files on Windows, refresh on iPhone, and tap a file to download. Received files are available through the share sheet or Files → On My iPhone → LocalDrop. For supported image/video formats, use the share sheet to save to Photos.
5. Keep both apps open and the iPhone app in the foreground until transfers finish. Reconnect using the new secret after restarting Windows LocalDrop.

## Performance and behavior

- Uploads and downloads stream from files to keep memory bounded; Windows uploads use a 1 MiB copy buffer.
- iPhone uploads are queued sequentially. The Windows service accepts up to two concurrent uploads and supports HTTP range downloads (the current iPhone UI does not implement resume).
- Photos/video preparation uses a temporary copy of one item at a time. It needs available iPhone disk space. iCloud-only items must first download through the Photos picker; local files transfer directly.
- The Photos picker requests the current representation to reduce conversion. This is not a complete Photos-library backup: Live Photo pairing, albums, edits, and all metadata are not guaranteed to be preserved.
- Actual speed is unmeasured. Wi-Fi signal, router, device storage, and photo preparation determine throughput. The iPhone displays average completed-upload speed. Use a nearby 5/6 GHz access point and Ethernet on Windows where possible.
- 100 GB server-side per-file limit. No automatic retries, resumable uploads, background transfers, automatic discovery, QR pairing, or installer yet.
- Shared Windows files remain in place and should not be edited during a download. Removing an item stops future downloads; an active download can finish.

## Security boundary

This development prototype uses a random 128-bit pairing secret that changes on each Windows app launch. Every API request requires it. Only explicitly shared Windows paths can be downloaded. Uploads use sanitized names, unique destinations, a free-space check, and partial-file cleanup on handled failures. A process crash can leave hidden `.partial` files in Received; delete these after stopping the app.

**HTTP traffic, including the pairing secret and file contents, is unencrypted.** Use only a trusted private LAN; never forward its port or expose it to the internet. iOS allows HTTP for this prototype, and the pairing UI accepts private/link-local IPv4 addresses only. A paired device can read all shared files and upload files until Windows closes. Treat received files as untrusted.

Before public distribution, add TLS with certificate pinning and authenticated QR pairing, persistent device approval/revocation, transfer cancellation/resume, stronger quota controls, and signed installers. Replace the broad iOS ATS exception with the final transport configuration.

## Verification

The implementation was authored in Linux without .NET, Xcode, or Swift installed; native compilation and device transfers have **not** been verified here. The included GitHub Actions workflow builds both targets and runs the protocol checks when pushed to GitHub. It has not been run in this workspace.

On a machine with .NET 8 installed:

```sh
dotnet run --project tests/ProtocolTests.csproj
```

The tests use an isolated temporary receive directory and cover authentication, listing, byte-for-byte upload/download integrity, download ranges, duplicate filenames, path sanitization, and unsharing. Port 45872 must be free.

Before treating this as a release, build both platforms and complete the device checklist in `docs/device-testing.md`.
