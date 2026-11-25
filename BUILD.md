# Pin

Pin reads saved photos and connects an answer to the photos that support it. This preview includes a SwiftUI itinerary journey and the Pin wordmark. A saved change notice and a photographed station board can disagree. Each has its own button, date or time, and source photo.

## Run the Nativ demo

Use an Apple Silicon Mac, Xcode with an iOS Simulator, Python 3 and a separately installed Nativ app. The verified setup used Nativ 0.4.3, Xcode 26.6 and iOS 26.5. Clone the Pin and iBrain repositories and unpack the model release in the same parent directory so that `Pin`, `iBrain` and `Pin-Qwen-6bit` are siblings.

1. From the Pin directory run `python3 Tools/start-nativ.py /Applications/Nativ.app ../Pin-Qwen-6bit`. Leave that terminal running.
2. Open `PinSavedPlaces.xcodeproj`, choose the PinSavedPlaces scheme and run it on an iPhone Simulator. Import the PNGs from `Verification/Photos` into that simulator's Photos library. Grant Pin access and wait for the photos to be read.
3. Ask “Compare the change notice and the departure board for train R581.” Tap **Change notice** and **Departure board** in turn. **Done** takes you back to the answer.
4. Ask “For BA629 to R581, reconstruct my itinerary with all saved changes. Give departure, gap after landing, destination hotel and platform.” Look for 00:12, 84 minutes, Fern Court and platform 3.

## How the answer works

Apple Vision reads text locally. For itinerary questions that need interpretation, Pin sends the question and fixed examples to the post-trained Qwen checkpoint running in Nativ on the Mac. The model selects a source policy. Swift uses the saved records to resolve the booking, calculate time differences, and bind each answer row to a photo. Explicit requests can resolve entirely in Swift. The model endpoint is loopback-only and uses no account or API key. On a physical phone, loopback points to that phone. This preview does not bundle a phone inference runtime.

The itinerary reader currently recognizes labelled English travel records and explicit train references in the supported format. Its benchmark covers fictional itineraries, ambiguous or missing records, and questions about live conditions. Real documents can have different layouts and language.

## Verification

Run `swift test` for the 133 portable Pin core tests. Run `bash Verification/replay.sh BOOTED_SIMULATOR_UDID` with Nativ running. It builds the package, executes the shipping itinerary code in the simulator, and compares returned facts and source IDs with the answer key. The retained comparator and results are in `Verification`. The 74 cases include the original 15, the expanded checks, and two release regressions covering saved changes and a platform printed on the original ticket. The separate UI test exercises PhotoKit, rendering and navigation. To reproduce it, use a disposable simulator with just the eight supplied photos plus any stock simulator photos. Install Pin, start Nativ, then run the PinHeadlessUI scheme in `Verification/UI/PinHeadlessUI.xcodeproj` against the same simulator. This test grants access to the simulator's fictional library. It checks both source buttons, the return path and the connection interval after a saved change.

Pin is distributed under the MIT license. See LICENSE.
