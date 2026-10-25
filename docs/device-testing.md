# Real-device acceptance checklist

Record Windows/iPhone versions, router band, connection type, source size, elapsed time, and observed MB/s. No throughput target is claimed until these measurements exist.

- Build both native applications; run the protocol tests with port 45872 free.
- Pair on the same network; verify incorrect secrets fail and a restart invalidates the previous secret.
- Transfer a JPEG, HEIC, MOV, PDF, empty file, Unicode filename, and a file larger than 4 GB each way. Compare SHA-256 hashes on both ends after exporting iPhone downloads to a verification machine.
- Select multiple photos and files; verify all successes and any reported failures. Test iCloud-only items separately from local items.
- Download a Windows photo, then save to Photos through Share. Verify unsupported formats remain available in Files.
- Disconnect Wi-Fi during upload; verify Windows removes the incomplete file after the connection terminates and a fresh retry succeeds.
- Lock/background the phone during a transfer and document actual suspension behavior. Foreground completion is the supported mode.
- Try duplicate filenames, little free disk space, inaccessible shared files, and removing a share. Confirm existing files are not overwritten.
- Test private-network firewall prompts and router client isolation; verify actionable connection errors.
- Measure transfers over 2.4 GHz, 5/6 GHz, and Windows Ethernet. Compare with a wired baseline; monitor memory during a large transfer.
- Confirm received files and pairing secrets are not emitted to telemetry or logs.
