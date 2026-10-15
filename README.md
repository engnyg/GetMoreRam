# Get More Ram
A simple [StosSign](https://github.com/stossy11/StosSign) wrapper app that allows you to enable "Increased Memory Limit" for your sideloaded apps without using Xcode.

# How to use
1. Sideload this app
2. Go to settings, sign in your account that you used to sign the app you want to enable "Increased Memory Limit"
3. Go to "App IDs" page
4. Tap Refresh
5. Tap the app you want to enable "Increased Memory Limit"
6. Tap "Add Increased Memory Limit"
7. Reinstall the app from SideStore/AltStore
8. Check if you have "Increased Memory Limit"

# Building
Sign in relies on a patch to StosSign (`patches/stossign.patch`: 2FA `hsc 409` handling, anisette resync, and the same anisette headers as iloader/isideload).
The GitHub Actions workflow applies it automatically after resolving the packages. To build locally, resolve the Swift packages first, then run
`patch -p1 -d <path to the StosSign checkout> < patches/stossign.patch` (the checkout is under `SourcePackages/checkouts/StosSign` in the derived data folder).

# Credits
Stossy11 - For StosSign.
SideStore - Anisette Data fetching codes are stolen from SideStore
