# Privacy Policy for QuickProtect

_Last updated: August 13, 2026_

QuickProtect ("the app") is a menu-bar (macOS) and system-tray (Windows, Linux)
application for viewing live camera feeds from your own UniFi Protect
controller. Your privacy matters, and this policy explains exactly what the app
does and does not do with your data.

## Summary

**QuickProtect does not collect, store, transmit, or share any personal data.**
There are no analytics, no tracking, no advertising, no user accounts, and no
servers operated by the developer. The app talks only to the UniFi Protect
controller you configure, on your own network.

## Information stored on your device

The app stores the following locally on your device, solely so it can function.
None of it is ever sent to the developer or any third party:

- **Controller connection details** — the IP address and API key for your UniFi
  Protect controller, and (optionally) a local admin username and password used
  for PTZ camera control. These credentials are stored securely on your
  device — in the **macOS Keychain** on Mac, **encrypted with your Windows
  account (DPAPI)** on Windows, or in your **desktop's secret service** (GNOME
  Keyring or KWallet) on Linux, falling back to a file readable only by your
  user account — and are used only to connect to your controller.
- **App preferences** — settings such as themes, camera order, layouts, and
  your keyboard shortcut, stored in standard macOS preferences or in a local
  settings file on Windows and Linux.

## Network connections

QuickProtect connects **only to the UniFi Protect controller you specify**, over
HTTPS and RTSP/RTSPS, to list cameras and stream video. This connection is made
on your local network (or through a VPN you set up yourself). The app does not
connect to any developer-operated servers and does not transmit your data
anywhere else.

One exception: the free builds downloaded from GitHub check **GitHub
(api.github.com)** once a day for a newer release, so they can show a notice in
Settings. This request contains no personal data or identifiers, and nothing is
downloaded or installed automatically. Builds from the App Store or Microsoft
Store are updated by the store itself and never perform this check.

## Data collection

None. QuickProtect does not collect or process any personal data, usage data,
diagnostics, or identifiers.

## Third parties

QuickProtect contains no third-party analytics, advertising, or tracking SDKs,
and does not share any data with third parties.

## Children's privacy

The app is not directed at children and collects no data from anyone.

## Changes to this policy

Any updates to this policy will be posted at this URL.

## Contact

If you have questions about this privacy policy, contact:
**hello@quickprotect.app**
