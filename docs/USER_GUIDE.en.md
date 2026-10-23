# PhoneBridge User Guide

PhoneBridge lets you browse and move files on an Android phone or tablet connected to your Mac over USB. It runs on Apple Silicon Macs (M1 or later) with macOS 15 or later; the Finder sidebar needs macOS 26 or later. See `INSTALL.md` for installing and removing, and `PRIVACY.md` for privacy.

## 1. Connect
1. Connect the device with a USB cable that carries data.
2. Unlock the device.
3. In the device's notification, set "Use USB for" to **File transfer**. Tap **Allow** if it asks to allow access to phone data.
4. The device appears under **Connected Devices** and its internal storage opens.

| Message | Meaning | What to do |
|---|---|---|
| Select File Transfer Mode | Charging-only mode | Pick "File transfer" in the device's notification |
| Connected in Photo Transfer (PTP) Mode | Photo transfer mode | Switch to "File transfer" |
| Unlock Your Device | Locked, or data access not allowed | Unlock and tap Allow |
| Another program is using the device | Image Capture, Android File Transfer, Smart Switch etc. hold the device | Quit that app and click **Retry** |
| Waiting to reconnect | Cable unplugged or mode changing | Reconnect within 8 seconds to continue |
| Safely Disconnected | You can unplug now | Unplug, or click **Reconnect** |

If the device does not show up, open **Help › Connection Troubleshooting**.

## 2. Browse
- Double-click a folder to open it. Back ⌘[, Forward ⌘], Enclosing Folder ⌘↑, Refresh ⌘R.
- View as List ⌘1 or Icons ⌘2. Click a column header to sort by name, date modified, size or kind.
- Search by name ⌘F, in the current folder or all subfolders (up to 2,000 results).
- Inspector (⌥⌘I): size, dates, location and a thumbnail for photos and videos.
- Quick Look ⌘Y or Space: photos, videos, PDFs and documents up to 1 GB (downloaded to the Mac the first time).

## 3. Move files
| Task | How |
|---|---|
| Copy to the Mac | Select, then **Download** (⇧⌘D, to Downloads) or **Download To…** (⌥⇧⌘D) |
| Drag straight to Finder | Drag from the Android list to a Finder window or the Desktop; the file appears once it has been downloaded |
| Copy to the device | **Upload from Mac…** (⌘U), or drag from Finder into the Android list |
| Side by side with the Mac | **Show Mac Pane** (⌥⌘2): Android left, Mac right; drag between them |
| Move within the device | Drag onto a folder, or Cut ⌘X then Paste ⌘V |
| New folder, rename, delete | ⇧⌘N, Rename…, ⌘⌫ (asks first; the device has no Trash, so deletion is permanent) |

- When a name already exists you choose **Replace / Keep Both / Skip**.
- Korean file names are sent in precomposed form so the phone does not show separated jamo.
- Several items dragged to Finder at once appear as one row in the transfer list.
- Progress shows in the **File Transfers** bar at the bottom; ⌥⌘T opens the list. Failed transfers show the cause and what to do, and can be retried.
- If the cable comes out during a transfer, the job fails and no partial file is left on the device or the Mac. Reconnect and retry.
- Temporary files left by a crash are cleaned at the next launch or connection.

## 4. Safely disconnect
Choose **Device › Safely Disconnect** (⌘E) or right-click the device in the sidebar. PhoneBridge asks first if transfers are running, unmounts its Finder volumes, then says you can unplug. If a file from the device is open in Finder, close it and try again.

## 5. Finder (optional)
Turn on **Enable Finder integration** in Settings › Finder and enable the "PhoneBridge Finder" extension in System Settings (`INSTALL.md`). The device's storage then appears under Locations in the Finder sidebar.
- It is **read-only** by default: open, Quick Look and copy to the Mac.
- **Allow writing from Finder (experimental)** writes to the virtual device; turn on **Also allow writing to real Android devices** below it to write to phones too (asks once more). Files deleted on the phone cannot be recovered, and only one model has been verified so far, so back up important files first.
- While a large copy runs through the Finder volume, other folders may take a moment to list (MTP handles one request at a time).

## 6. Settings
- **General › Language**: 한국어 / English. The app's windows switch immediately; a few texts drawn by macOS (Services and Quit in the app menu, file panel buttons) follow after a relaunch.
- Show virtual device: a demo Android device for trying PhoneBridge without hardware. It is marked as virtual; its files reset when the app quits.

## 7. When something goes wrong
1. Go through **Help › Connection Troubleshooting** (cable, port, unlock, other apps).
2. If that does not help, use **Help › Export Diagnostics…** and attach the text file to your support request. It contains no file or folder names, and you can read it before sending.

## 8. Good to know
- MTP handles one request at a time. Large files move in pieces so you can keep browsing; on devices that do not support this, opening folders waits until the transfer ends.
- SD cards formatted FAT32 cannot hold files over 4 GB (device limit).
- Some devices hide their storage while locked; unlocking continues automatically.
- So far, the Samsung Galaxy S25 Edge (SM-S937N) has been verified on real hardware. Other Android devices using standard MTP will likely work but have not been verified.
