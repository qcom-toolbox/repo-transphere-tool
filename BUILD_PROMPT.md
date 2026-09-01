Build a Theos app for an iOS 15 rootless jailbreak (Dopamine/palera1n-style, `/var/jb` prefix).

**What it is:** an app called **Repo Transphere Tool**, package/bundle identifier `com.qcom-toolbox.repo-transphere-tool`. Its icon source image is `ICON.png` (already in this project folder, 180x180).

**What it does:** Sileo (the package manager on jailbroken iPhones) keeps a list of "repos" — URLs of package sources. This app lets you move that list from one iPhone to another:

- **Export**: reads every repo currently configured in Sileo, writes them out to a file.
- **Transfer**: get that file onto the other iPhone by any means (AirDrop, cable, whatever).
- **Import**: reads that file on the new phone and adds any repos it doesn't already have. It must never delete or duplicate existing repos — only add what's missing.

Theos is installed at `~/theos`. Build for rootless (`THEOS_PACKAGE_SCHEME = rootless`) and as a release build (`FINALPACKAGE = 1`), not debug.
