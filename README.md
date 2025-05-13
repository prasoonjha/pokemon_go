# Pokémon go AR 

A simple AR application built with RealityKit and SwiftUI that lets you flick a Pokéball at a 3D Pokémon model. The ball follows a parabolic trajectory, lands on a detected horizontal plane, and the Pokémon vanishes upon capture.

## Tools & Frameworks
- Xcode 14+ (macOS)
- Swift 5.7+
- ARKit & RealityKit
- SwiftUI for UI overlay

## Installation & Run
1. Clone this repository to your Mac:
   ```bash
   git clone <repository-url>
   cd pokemon_go
   ```
2. Open the project in Xcode:
   ```bash
   open pokemon_go.xcodeproj
   ```
3. Connect your iOS device (iOS 15+ recommended).
4. In Xcode, select your device as the run destination.
5. Build and Run (⌘R).

**Note:** Ensure camera permissions are granted when prompted. Aim your device at a flat surface to initialize the AR plane before throwing the Pokéball.
