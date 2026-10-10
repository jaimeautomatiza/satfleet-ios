# SatFleet Live for iOS

Native iOS app for [SatFleet Live](https://satfleetlive.com), a real-time satellite, launch, Moon, Mars and deep space tracker.

The app shows the SatFleet Live website inside a native shell and adds iOS features:

- Sign in with Apple and Google (native)
- Premium subscription with Apple in-app purchases (RevenueCat)
- Push notifications for rocket launches and satellite passes (Firebase Cloud Messaging)
- Native GPS for satellite pass predictions and AR Sky View
- ISS widget (Home Screen and Lock Screen), computed on-device
- Live Activity countdown for upcoming launches

## How it is built

There is no Xcode project in this repository. It is generated in the cloud:

1. `project.yml` describes the project (XcodeGen).
2. `.github/workflows/testflight.yml` runs on a GitHub macOS runner: it generates the project, signs the app and uploads it to TestFlight.
3. The workflow is started manually: **Actions > Compilar y enviar a TestFlight > Run workflow**.

## Secrets

This repository contains no secrets. Signing certificates, provisioning profiles and the App Store Connect key are stored in **GitHub Actions secrets**. The Firebase configuration file (`GoogleService-Info.plist`) and the RevenueCat public SDK key are public by design.

## Structure

- `SatFleetLive/`: app code (SwiftUI + WKWebView bridges), assets and Firebase configuration
- `SatFleetLiveWidget/`: ISS widget and Live Activity UI
- `Shared/`: code shared by the app and the widget
- `project.yml`: project definition
- `.github/workflows/testflight.yml`: build and upload recipe

## License

All rights reserved. This code may not be copied or reused without permission.
