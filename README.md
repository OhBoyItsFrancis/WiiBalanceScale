# WiiBalanceScale
Use the Wii Balance Board as a pretty accurate weight scale (± 20 gram), and keep a journal of your weight loss journey.

This repository contains a native **macOS app** (in [`macOS/`](macOS)) and the original **Windows app** it was ported from.

## macOS app

### Features
- **Scale**: the live readout of the original app, with the accuracy stars, Zero button and kg / lbs / st:lbs units.
- **Automatic weigh-ins**: step on the board and stand still. Once all five stars are lit, the weight is saved to your journal. You can Undo, add a note, or turn this off and save manually.
- **Progress**: latest weight, smoothed trend, total change, last 7 and 30 days, weekly rate, lowest weight and BMI. The chart shows daily weights with a trend line and your goal (1M / 3M / 6M / 1Y / All).
- **Goal tracking**: how far along you are, how much is left, and a projected date for reaching your goal at your current rate.
- **Milestones**: the date you first got 2.5 kg / 5 lb / ½ st further from your starting weight, then each step after that, and the date you reached your goal.
- **History**: every weigh-in with its change from the previous one. Add past weights by hand, edit, delete, and import or export CSV.

Day-to-day weight swings by a kilogram or more from water and food, so the trend uses an exponentially smoothed average (as in *The Hacker's Diet*). That gives a much more honest picture of gradual progress than any single weigh-in.

### Requirements
- Wii Balance Board
- macOS 13 Ventura or later
- Bluetooth
- Xcode 15 or later (or the Xcode Command Line Tools) to build

### Building
```bash
cd macOS
```
```bash
Scripts/build-app.sh
```
This creates `macOS/build/WiiBalanceScale.app`. Move it to your Applications folder. The app is signed ad hoc, not notarized, so the first time you open it, right-click it and choose **Open**. When asked, allow Bluetooth access.

For development, `swift run` builds and starts the app, `swift test` runs the unit tests, and `open Package.swift` opens the project in Xcode.

The included GitHub Actions workflow (`.github/workflows/macos.yml`) runs the tests and builds the app on every push. The zipped `.app` is attached to each run as an artifact.

### Usage
1. Start the app and press the red **SYNC** button in the battery compartment of the Balance Board. You don't need to pair it in System Settings.
2. Keep the board empty while it zeroes. If someone is standing on it, the app waits until they step off.
3. Step on and stand still. The stars fill up over about five seconds, and your weight is saved to the journal.
4. Look at **Progress** and **History** to follow your journey. Set your goal weight and height (for BMI) with the **Goal…** toolbar button or in Settings (⌘,).

The journal is stored at `~/Library/Application Support/WiiBalanceScale/journal.json`, and the previous version is kept next to it as `journal.backup.json`. CSV exports have the columns `date, weight_kg, weight_lb, note, source`. For imports, the file needs a `date` column (ISO 8601 or `yyyy-MM-dd [HH:mm]`) and a weight column in kg or lb, so data from most other apps and spreadsheets can be brought in.

### Troubleshooting
- **The board is not found**: press SYNC again. The board only stays discoverable for about 20 seconds. Check the batteries too, since weak batteries cause both connection problems and inaccurate readings.
- **The board was paired in System Settings before**: remove it there (Bluetooth › ⓘ › Forget This Device). macOS may otherwise grab the connection.
- **Nothing happens and Bluetooth is on**: check that the app is allowed in System Settings › Privacy & Security › Bluetooth.

## Windows app (original)

### Download
You can find a binary download under the [Releases page](https://github.com/schellingb/WiiBalanceScale/releases/latest).

### Requirements
- Wii Balance Board
- Windows
- Bluetooth (built-in or USB dongle)

### Usage
On startup, the application will try to find a connected Wii Balance Board. If none is connected it will start to scan for new Bluetooth devices. As soon as a Wii Balance Board is found (by pressing the SYNC button on the device) it will establish a connection to it.

The application will then quickly calculate the initial zeroing. At any time you can click the 'Zero' button to do manual zeroing of the scale.

Below the weight you can find a gauge indicating the quality/accuracy of the measurement. It goes from 0 stars (1 kg unit accuracy) to 5 stars (± 20 gram accuracy) after 5 seconds. The Wii Balance Board is not very accurate in an instant measure but it becomes more accurate by accumulating measurement over time.

Use the unit selector to choose between kilograms (kg), pounds (lbs) and stone/pounds (st/lbs).

![Screenshot](README.png)

### Troubleshooting
The automatic connection to the Bluetooth device requires admin rights which the application tries to acquire automatically. If this does not work for you, you can launch the application by right-clicking it and selecting 'Run as administrator' or you can connect to it using the Windows Bluetooth control panel before launching the application.

## License
WiiBalanceScale and the included [WiimoteLib by BrianPeek](https://github.com/BrianPeek/WiimoteLib) are available under the [MIT license](https://choosealicense.com/licenses/mit/).
