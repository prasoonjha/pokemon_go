import SwiftUI
import RealityKit

struct ContentView : View {
    var body: some View {
        ARViewContainer().edgesIgnoringSafeArea(.all)
    }
}

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Create anchor for the Pokemon model
        let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))

        // Load Pokemon model asynchronously
        Task {
            do {
                // Replace "Pokedex_3d_Pro_Eevee" with your actual USDZ file name (without extension)
                let pokemonModel = try await Entity.load(named: "Pokedex_3d_Pro_Eevee")

                // Scale the model appropriately
                pokemonModel.scale = SIMD3<Float>(0.1, 0.1, 0.1)

                // Position the model slightly above the anchor point
                pokemonModel.position = SIMD3<Float>(0, 0.05, 0)

                // Play all animations in the model if they exist
                for animation in pokemonModel.availableAnimations {
                    pokemonModel.playAnimation(animation.repeat())
                }

                // Add the model to the anchor
                anchor.addChild(pokemonModel)

                // Add the anchor to the scene
                arView.scene.addAnchor(anchor)
            } catch {
                print("Error loading Pokemon model: \(error.localizedDescription)")
            }
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

#Preview {
    ContentView()
}