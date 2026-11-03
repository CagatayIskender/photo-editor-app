# AURUM

A luxury photo and video editor for iOS. *AURUM* is a working title: every brand string, colour, font and product ID lives in `Brand/brand.json` and `Packages/AurumDesign/Sources/AurumDesign/Brand.swift`, so the app can be renamed in one change.

Product spec, design system and architecture live in the project docs:

- Product spec: https://claude.ai/artifact/6Ros1AyhQYVtGEJGT5mKPZ
- Design system and screens: https://claude.ai/artifact/YB2s7psmxopG3Lob3KKs8n
- Technical architecture: https://claude.ai/artifact/L8wsg7QsdXEAS4n8ECiD7g

## Layout

```
App/                      SwiftUI app target (shell, navigation, environment)
Brand/brand.json          Single source of brand tokens and copy
Looks/catalog.json        The look catalogue (generated, see tools/)
Packages/
  AurumCore/              Pure Swift: edit graph, history, looks, export gate, presets. Builds on Linux.
  AurumDesign/            Tokens, fonts, icons and components
  AurumRender/            Core Image + Metal render pipeline
  AurumServices/          Photos, drafts, purchases, analytics, remote config
  AurumFeatures/          Onboarding, Salon, Vault, Picker, Studio, Export, Paywall
tools/generate_catalog.py Builds Looks/catalog.json from parametric families
project.yml               XcodeGen project spec
```

Dependencies only point down: App → Features → Design / Render / Services → Core.

## Building

Requirements: Xcode 16 or newer, iOS 16+ device or simulator, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Aurum.xcodeproj
```

Core logic tests run anywhere Swift runs:

```sh
cd Packages/AurumCore && swift test
```

Fonts: download Playfair Display and Inter (both SIL Open Font License) from Google Fonts and place the `.ttf` files in `App/Resources/Fonts/`. The app falls back to system serif and SF Pro if they are missing.

## Conventions

- Tools never touch pixels. They change the `EditDocument`; `AurumRender` turns it into an image.
- Every service is a protocol with a live and a preview/test implementation, injected through `AppEnvironment`.
- All look, collection and sticker names are original. `LookCatalogTests` rejects names on the deny-list.
- The Auto Studio (enhance, portrait blur, background, relight, retouch, object remove, portrait looks, 3D motion) runs entirely on the device with Apple's Vision detection and classic Core Image processing. There is no generative model, AI provider, image server or credit system; photos never leave the device. Members' tools and looks preview freely and ask for membership only when the result is kept, like every other export.
