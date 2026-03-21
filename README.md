# hi, this is freewrite

a simple, open-source mac app to freewrite.

download latest version [here](https://www.freewrite.io/)

![img](https://i.imgur.com/2ucbtff.gif)

if you wanna make an addition + pr,
or just wanna remix the app for yourself go for it.

## build from source

1. clone the repo: `git clone https://github.com/your-username/freewrite-app.git`
2. open `freewrite.xcodeproj` in xcode.
3. select the `freewrite` scheme and hit **Cmd+B** to build (or **Cmd+R** to build & run).
4. done -- you're up and running.

### move to applications

after building, the app lives deep in xcode's DerivedData folder. to grab it:

**option a -- from xcode (easiest)**
- in xcode, go to **Product → Show Build Folder in Finder**.
- open the `Debug` (or `Release`) folder.
- drag `freewrite.app` into `/Applications`.

**option b -- from terminal**
```sh
cp -R ~/Library/Developer/Xcode/DerivedData/freewrite-*/Build/Products/Debug/freewrite.app /Applications/
```

**option c -- release build (recommended for daily use)**

a release build is optimized and doesn't include debug overhead:

```sh
xcodebuild -scheme freewrite -configuration Release -derivedDataPath build
cp -R build/Build/Products/Release/freewrite.app /Applications/
```

> **note:** if macOS blocks the app on first launch ("unidentified developer"), right-click the app → Open → Open.

---

make changes on a pr and i'll run on my end and then build a new version :).
