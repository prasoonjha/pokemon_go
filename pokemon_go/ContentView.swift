import SwiftUI
import RealityKit
import ARKit
import Combine

// ARViewCoordinator class to handle AR interactions
class ARViewCoordinator: NSObject {
    var planeAnchor: AnchorEntity?
    var groundPlane: ModelEntity?
    var pokemonModel: Entity?
    var pokeball: Entity?  // Changed from ModelEntity to Entity
    var pokeballAnchor: AnchorEntity?
    
    var isPokeballThrown = false
    var isCaptureInProgress = false
    var pokeballThrowStartPoint: CGPoint?
    var showDebugVisualization = false
    
    // Store throw parameters including the ARView for reset callback
    var throwParams: (start: SIMD3<Float>, end: SIMD3<Float>, height: Float, duration: Float, elapsed: Float, link: CADisplayLink, scene: ARView)?

    @objc func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let ball = pokeball, let view = gesture.view as? ARView else { return }
        switch gesture.state {
        case .ended:
            // get start/world positions
            let start = ball.position(relativeTo: nil)
            let target = (planeAnchor?.children.first { $0.name=="pokemon" }?.position(relativeTo: nil)) ?? SIMD3<Float>(start.x, start.y, start.z-1)
            
            // simple arc params
            let dist = simd_distance(start, target)
            let height: Float = max(0.2, dist * 0.5)
            let duration: Float = max(0.6, dist * 0.4)
            
            // store params
            let link = CADisplayLink(target: self, selector: #selector(updateThrow))
            link.add(to: .current, forMode: .default)
            // Store ARView in parameters for later use
            throwParams = (start, target, height, duration, 0, link, view)
        default: break
        }
    }

    @objc func updateThrow() {
        guard var p = throwParams, let ball = pokeball else { return }
        p.elapsed += Float(p.link.duration)
        let t = min(p.elapsed / p.duration, 1)
        // parabola: linear XY + 4h t(1-t)
        let pos = p.start * (1-t) + p.end * t
        let y = pos.y + p.height * 4 * t * (1-t)
        ball.position = SIMD3<Float>(pos.x, y, pos.z)
        
        // Always check collision
        if t < 1 {
            throwParams = p
            return
        }
        
        // End of arc: guarantee hit
        p.link.invalidate()
        throwParams = nil

        // Move pokeball to the target position
        ball.position = p.end

        // Vanish the pokemon immediately
        if let pokemon = pokemonModel {
            // Grab current transform
            var vanishTransform = pokemon.transform
            // Animate scale down to zero over 0.5 seconds
            vanishTransform.scale = SIMD3<Float>(0, 0, 0)
            pokemon.move(to: vanishTransform, relativeTo: pokemon.parent, duration: 0.5)
            // Remove from scene after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pokemon.removeFromParent()
            }
            // Clear reference
            pokemonModel = nil
        }

        // Animate pokeball falling to ground and rolling
        if let ballEntity = ball as? ModelEntity {
            // Fall to ground level at y=0.025
            let currentPos = ballEntity.position(relativeTo: nil)
            let groundTransform = Transform(
                scale: ballEntity.transform.scale,
                rotation: ballEntity.transform.rotation,
                translation: SIMD3<Float>(currentPos.x, 0.025, currentPos.z)
            )
            ballEntity.move(to: groundTransform, relativeTo: nil, duration: 0.5)
            // After landing, add roll physics
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.addPhysicsForRoll(to: ballEntity)
            }
        }

        // Show reset button overlay
        showResetButtonOverlay(in: p.scene)
        
        return
    }
}

// Extension to add required ModelEntity functionality
extension ModelEntity {
    static func createMull(width: Float, height: Float, depth: Float) -> ModelEntity {
        let mesh = MeshResource.generateBox(width: width, height: height, depth: depth)
        let material = SimpleMaterial(color: .white, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        return entity
    }
    
    // Handle scale animation
    func setScale(_ scale: SIMD3<Float>, relativeTo: Entity?) {
        self.scale = scale
    }
    
    // Method to handle sequence animation
    func runActionSequence(_ actions: [SCNAction]) {
        if let firstAction = actions.first {
            runAction(firstAction)
            
            if actions.count > 1 {
                let remainingActions = Array(actions.dropFirst())
                DispatchQueue.main.asyncAfter(deadline: .now() + firstAction.duration) {
                    self.runActionSequence(remainingActions)
                }
            }
        }
    }
    
    // Add the runAction function to handle animations
    func runAction(_ action: SCNAction) {
        switch action {
        case let waitAction where action.duration > 0:
            // Handle wait action
            DispatchQueue.main.asyncAfter(deadline: .now() + action.duration) {
                action.block(self)
            }
        default:
            // Execute the block immediately for other actions
            action.block(self)
        }
    }
}

// Extension for SCNAction to implement required functionality
extension SCNAction {
    // Add additional required SCNAction methods
    static func custom() -> SCNAction {
        return SCNAction(duration: 0)
    }
}

// Simple implementation of SCNAction
struct SCNAction {
    var duration: TimeInterval
    var block: (ModelEntity) -> Void = { _ in }
    
    init(duration: TimeInterval, block: @escaping (ModelEntity) -> Void = { _ in }) {
        self.duration = duration
        self.block = block
    }
    
    // Add missing sequence method
    static func sequence(_ actions: [SCNAction]) -> SCNAction {
        var totalDuration: TimeInterval = 0
        for action in actions {
            totalDuration += action.duration
        }
        
        return SCNAction(duration: totalDuration) { entity in
            guard let modelEntity = entity as? ModelEntity else { return }
            modelEntity.runActionSequence(actions)
        }
    }
    
    // Add missing wait method
    static func wait(duration: TimeInterval) -> SCNAction {
        return SCNAction(duration: duration)
    }
    
    // Add missing run method
    static func run(_ block: @escaping (ModelEntity) -> Void) -> SCNAction {
        return SCNAction(duration: 0, block: block)
    }
}

// Add an extension to provide the 'model' property for Entity
extension Entity {
    var model: ModelComponent? {
        get {
            return components[ModelComponent.self]
        }
        set {
            if let newModel = newValue {
                components[ModelComponent.self] = newModel
            }
        }
    }
}

// The rest of your ContentView code
struct ContentView: View {
    var body: some View {
        ZStack {
            ARViewContainer().edgesIgnoringSafeArea(.all)
            
            // UI overlay for instructions
            VStack {
                Spacer()
                Text("Flick the Pokeball to throw!")
                    .font(.headline)
                    .padding()
                    .background(Color.white.opacity(0.7))
                    .cornerRadius(10)
                    .padding(.bottom, 100)
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    func makeCoordinator() -> ARViewCoordinator {
        return ARViewCoordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let coordinator = context.coordinator
        
        // Configure AR session with better plane detection
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
        
        // Create a fixed anchor for the ground plane
        let planeAnchor = AnchorEntity(plane: .horizontal)
        coordinator.planeAnchor = planeAnchor
        arView.scene.addAnchor(planeAnchor)
        
        // Add a visible debug plane to represent the ground - make it larger
        let planeBoundary = Float(2.5) // 5x5 meter plane
        let groundMesh = MeshResource.generatePlane(width: planeBoundary * 2, depth: planeBoundary * 2)
        let groundMaterial = SimpleMaterial(color: .init(white: 0.8, alpha: 0.3), isMetallic: false)
        let groundPlane = ModelEntity(mesh: groundMesh, materials: [groundMaterial])
        groundPlane.position = SIMD3<Float>(0, 0, 0)  // Positioned at the anchor's origin
        
        // Add physics to the ground plane to act as a physical barrier
        groundPlane.components[PhysicsBodyComponent.self] = PhysicsBodyComponent(
            massProperties: .default,
            material: PhysicsMaterialResource.generate(friction: 0.8, restitution: 0.2),
            mode: .static // Static so it doesn't move
        )
        groundPlane.components[CollisionComponent.self] = CollisionComponent(
            shapes: [.generateBox(width: planeBoundary * 2, height: 0.01, depth: planeBoundary * 2)],
            mode: .default,
            filter: .default
        )
        
        // Add boundary walls to keep the ball within the plane
        let wallHeight = Float(0.5) // Height of boundary walls
        let wallThickness = Float(0.05) // Thickness of boundary walls
        
        // Create walls only if debug visualization is enabled
        if coordinator.showDebugVisualization {
            // Front wall (far Z, where Pokemon is)
            let frontWall = createWall(width: planeBoundary * 2, height: wallHeight, depth: wallThickness)
            frontWall.position = SIMD3<Float>(0, wallHeight/2, planeBoundary)
            planeAnchor.addChild(frontWall)
            
            // Back wall (near Z)
            let backWall = createWall(width: planeBoundary * 2, height: wallHeight, depth: wallThickness)
            backWall.position = SIMD3<Float>(0, wallHeight/2, -planeBoundary)
            planeAnchor.addChild(backWall)
            
            // Left wall (negative X)
            let leftWall = createWall(width: wallThickness, height: wallHeight, depth: planeBoundary * 2)
            leftWall.position = SIMD3<Float>(-planeBoundary, wallHeight/2, 0)
            planeAnchor.addChild(leftWall)
            
            // Right wall (positive X)
            let rightWall = createWall(width: wallThickness, height: wallHeight, depth: planeBoundary * 2)
            rightWall.position = SIMD3<Float>(planeBoundary, wallHeight/2, 0)
            planeAnchor.addChild(rightWall)
        }
        
        // Add the ground plane to the planeAnchor
        planeAnchor.addChild(groundPlane)
        coordinator.groundPlane = groundPlane

        // Load Pokemon model asynchronously
        Task {
            do {
                let pokemonModel = try await Entity.load(named: "Pokedex_3d_Pro_Leafeon")
                pokemonModel.name = "pokemon"  // Ensure target lookup works
                pokemonModel.scale = SIMD3<Float>(0.005, 0.005, 0.005)
                
                // Position in front of the camera, slightly above the plane
                pokemonModel.position = SIMD3<Float>(0, 0.05, -0.5) // Original position
                
                // FIX: Make Pokémon face the camera with correct orientation
                // First make it face forward with no rotation - use explicit identity quaternion
                pokemonModel.transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
                
                
                // Double-check orientation is applied
                print("Applied orientation to Pokémon: facing camera")
                
                coordinator.pokemonModel = pokemonModel
                coordinator.setupPokemonPhysics(for: pokemonModel)
                planeAnchor.addChild(pokemonModel)
                
                // Play animations if available
                for animation in pokemonModel.availableAnimations {
                    pokemonModel.playAnimation(animation.repeat())
                }
            } catch {
                print("Error loading Pokemon model: \(error.localizedDescription)")
            }
        }

        // Load Pokeball as a screen-fixed UI element
        Task {
            do {
                let pokeball = try await Entity.load(named: "Pokeball_animated")
                pokeball.scale = SIMD3<Float>(0.005, 0.005, 0.005)
                
                // Create a screen-space anchor to keep pokeball fixed on screen
                let pokeballAnchor = AnchorEntity(.camera)
                pokeballAnchor.position = SIMD3<Float>(0, -0.3, -0.8) // Position at bottom of screen
                
                pokeballAnchor.addChild(pokeball)
                arView.scene.addAnchor(pokeballAnchor)
                
                coordinator.pokeball = pokeball
                coordinator.pokeballAnchor = pokeballAnchor
                
                // Add gesture recognizer for flicking the Pokeball
                let gesture = UIPanGestureRecognizer(target: coordinator, action: #selector(ARViewCoordinator.handlePanGesture(_:)))
                arView.addGestureRecognizer(gesture)
            } catch {
                print("Error loading Pokeball model: \(error.localizedDescription)")
            }
        }
        
        return arView
    }
    
    // Helper function to create boundary walls
    func createWall(width: Float, height: Float, depth: Float) -> ModelEntity {
        let wallMesh = MeshResource.generateBox(width: width, height: height, depth: depth)
        let wallMaterial = SimpleMaterial(color: .init(white: 0.8, alpha: 0.2), isMetallic: false)
        let wall = ModelEntity(mesh: wallMesh, materials: [wallMaterial])
        
        // Add physics to wall
        wall.components[PhysicsBodyComponent.self] = PhysicsBodyComponent(
            massProperties: .default,
            material: PhysicsMaterialResource.generate(friction: 0.8, restitution: 0.5),
            mode: .static
        )
        wall.components[CollisionComponent.self] = CollisionComponent(
            shapes: [.generateBox(width: width, height: height, depth: depth)],
            mode: .default,
            filter: .default
        )
        
        return wall
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Only reposition the pokeball if it hasn't been thrown yet
        let coordinator = context.coordinator
        if !coordinator.isPokeballThrown {
            if let pokeballAnchor = coordinator.pokeballAnchor {
                // Keep the pokeball fixed at the bottom of the screen
                pokeballAnchor.position = SIMD3<Float>(0, -0.3, -0.8)
            }
        }
    }
}

extension ARViewCoordinator: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // When a plane is detected, we can use it to place our Pokemon
    }
}

extension ARViewCoordinator {
    // Setup collision detection for the Pokemon model
    func setupPokemonPhysics(for pokemon: Entity) {
        guard let modelEntity = pokemon as? ModelEntity else { return }
        
        print("Setting up Pokemon physics with IMPROVED collision detection")
        
        // Calculate the approximate size of the Pokemon model
        let boundingBox = pokemon.visualBounds(relativeTo: nil)
        let size = boundingBox.extents
        
        // CRITICAL FIX: Create a much larger collision box for reliable detection
        // Making the collision box 3x larger than before
        let collisionBoxWidth = size.x * 3.0
        let collisionBoxHeight = size.y * 3.0
        let collisionBoxDepth = size.z * 3.0
        
        print("Pokemon visual bounds: \(size)")
        print("Creating collision box with dimensions: \(collisionBoxWidth) × \(collisionBoxHeight) × \(collisionBoxDepth)")
        
        // Remove any existing physics components to avoid conflicts
        modelEntity.components.remove(PhysicsBodyComponent.self)
        modelEntity.components.remove(CollisionComponent.self)
        
        // Add static physics body to ensure collision is processed
        modelEntity.components[PhysicsBodyComponent.self] = PhysicsBodyComponent(
            massProperties: .init(mass: 100.0), // Heavy mass so it doesn't move on collision
            material: .default,
            mode: .static // Static so it doesn't move on collision
        )
        
        // Create a dedicated collision filter category for the Pokemon
        let pokemonCollisionFilter = CollisionFilter(group: .all, mask: .all)
        
        // Use a much larger collision shape for the Pokemon for better collision detection
        modelEntity.components[CollisionComponent.self] = CollisionComponent(
            shapes: [.generateBox(width: collisionBoxWidth, height: collisionBoxHeight, depth: collisionBoxDepth)],
            mode: .default, // Change from trigger to default for better collision response
            filter: pokemonCollisionFilter // Use explicit collision filter instead of .sensor
        )
        
        print("Added Pokemon collision box with dimensions: \(collisionBoxWidth) × \(collisionBoxHeight) × \(collisionBoxDepth)")
        
        // Debug visualization - add a visual indicator of the collision box if debug is enabled
        if showDebugVisualization {
            let debugBoxMesh = MeshResource.generateBox(width: collisionBoxWidth, height: collisionBoxHeight, depth: collisionBoxDepth)
            let debugMaterial = SimpleMaterial(color: .red.withAlphaComponent(0.3), isMetallic: false)
            let debugBox = ModelEntity(mesh: debugBoxMesh, materials: [debugMaterial])
            modelEntity.addChild(debugBox)
        }
    }
    
    // Animate the Pokemon being captured
    func animatePokemonCapture(arView: ARView) {
        guard let pokeball = self.pokeball as? ModelEntity,
              let pokemon = self.pokemonModel as? ModelEntity else { return }
        
        // Get the current positions
        let pokeballPosition = pokeball.position(relativeTo: nil)
        
        // Scale down the Pokemon to show it's being captured
        let scaleAction = SCNAction.sequence([
            SCNAction.wait(duration: 0.2),
            SCNAction.run { _ in
                // Animate the Pokeball wiggling to simulate capture attempt
                let wiggleAnimation = self.createWiggleAnimation()
                pokeball.runAction(wiggleAnimation)
            },
            SCNAction.wait(duration: 1.5),
            SCNAction.run { _ in
                // Fade out and scale down Pokemon to show successful capture
                pokemon.setScale(SIMD3<Float>(0, 0, 0), relativeTo: nil)
                
                // Show capture success notification
                self.showCaptureSuccess(arView: arView)
                
                // Reset the scene after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.performReset(arView: arView)
                }
            }
        ])
        
        pokemon.runAction(scaleAction)
    }
    
    // Create wiggle animation for the pokeball
    func createWiggleAnimation() -> SCNAction {
        // Here we'd implement wiggle animation, but for now we'll just use a placeholder
        return SCNAction.sequence([
            SCNAction.wait(duration: 0.2),
            SCNAction.run { entity in
                // Simulate wiggle by rotating slightly
                if let modelEntity = entity as? ModelEntity {
                    modelEntity.transform.rotation = simd_quatf(angle: .pi/30, axis: [0, 1, 0])
                }
            },
            SCNAction.wait(duration: 0.2),
            SCNAction.run { entity in
                // Rotate back
                if let modelEntity = entity as? ModelEntity {
                    modelEntity.transform.rotation = simd_quatf(angle: -.pi/30, axis: [0, 1, 0])
                }
            },
            SCNAction.wait(duration: 0.2),
            SCNAction.run { entity in
                // Reset rotation
                if let modelEntity = entity as? ModelEntity {
                    modelEntity.transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
                }
            }
        ])
    }
    
    // Show capture success notification
    func showCaptureSuccess(arView: ARView) {
        // Create a text entity for success message
        let textMesh = MeshResource.generateText(
            "Pokémon Caught!",
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.1),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        
        let textMaterial = SimpleMaterial(color: .green, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        // Position above where the Pokemon was
        if let pokemonPosition = self.pokemonModel?.position(relativeTo: nil) {
            let textAnchor = AnchorEntity(world: pokemonPosition + SIMD3<Float>(0, 0.3, 0))
            textAnchor.addChild(textEntity)
            arView.scene.addAnchor(textAnchor)
            
            // Remove after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                textAnchor.removeFromParent()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.showCaptureSuccess(arView: arView)
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}

extension simd_float4x4 {
    // Extract the upper 3x3 rotation matrix
    var upperLeft3x3: simd_float3x3 {
        return simd_float3x3(
            SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z),
            SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z),
            SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        )
    }
}

// Helper function to calculate distance between two points
func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let delta = a - b
    return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
}

extension ARViewCoordinator {
    // Show a reset button that allows the user to try again
    func showResetButton(in arView: ARView) {
        // Check if we're already showing a reset button
        for anchor in arView.scene.anchors {
            if anchor.name == "reset-button-anchor" {
                return
            }
        }
        
        // Create a button entity
        let buttonSize: Float = 0.15
        let buttonMesh = MeshResource.generateBox(width: buttonSize, height: buttonSize * 0.4, depth: 0.01)
        let buttonMaterial = SimpleMaterial(color: .systemBlue, isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        
        // Add text to the button
        let textMesh = MeshResource.generateText(
            "Reset",
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: CGFloat(buttonSize * 0.25)),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let textMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        // Position text slightly in front of button
        textEntity.position = SIMD3<Float>(0, 0, -0.01)
        buttonEntity.addChild(textEntity)
        
        // Create a screen-space anchor for the button at the bottom of the screen
        let buttonAnchor = AnchorEntity(.camera)
        buttonAnchor.name = "reset-button-anchor"
        buttonAnchor.position = SIMD3<Float>(0, -0.2, -0.5)
        buttonAnchor.addChild(buttonEntity)
        
        // Add to scene
        arView.scene.addAnchor(buttonAnchor)
        
        // Add tap gesture recognizer if not already added
        if !(arView.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) ?? false) {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
            arView.addGestureRecognizer(tapGesture)
        }
    }
    
    // Handle tap gesture for reset button
    @objc func handleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard let arView = gesture.view as? ARView else { return }
        
        // Get tap location in view
        let location = gesture.location(in: arView)
        
        print("Screen tap at \(location)")
        
        // Try direct entity hit test first (more reliable)
        if let hitEntity = arView.entity(at: location) {
            // Check the entity and its parents for the reset button
            var currentEntity: Entity? = hitEntity
            while currentEntity != nil {
                if currentEntity?.anchor?.name == "reset-button-anchor" {
                    print("Reset button tapped")
                    performReset(arView: arView)
                    return
                }
                currentEntity = currentEntity?.parent
            }
        }
        
        // Fall back to ray casting
        let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
        
        // Debug raycast results
        if results.isEmpty {
            print("No raycast results")
        } else {
            print("Found \(results.count) raycast results")
            
            // Process all results looking for the reset button
            for result in results {
                // The raycast hit point in world coordinates
                let worldPos = result.worldTransform.columns.3.xyz
                
                // Find entities near this position
                for anchor in arView.scene.anchors {
                    if anchor.name == "reset-button-anchor" {
                        // Calculate distance to the button
                        if let buttonEntity = anchor.children.first {
                            let buttonPos = buttonEntity.position(relativeTo: nil)
                            let dist = distance(worldPos, buttonPos)
                            print("Distance to reset button: \(dist)")
                            
                            if dist < 0.2 { // Consider this a hit within a reasonable threshold
                                performReset(arView: arView)
                                return
                            }
                        }
                    }
                }
            }
        }
        
        // Alternative approach - consider screenspace taps near the reset button position
        // This is more reliable for UI elements anchored to the camera
        for anchor in arView.scene.anchors {
            if anchor.name == "reset-button-anchor" {
                // Check if the tap is in the bottom center area where the button is
                let screenHeight = arView.bounds.height
                let screenWidth = arView.bounds.width
                
                // Define a region for the button (bottom center of screen)
                let buttonRegion = CGRect(
                    x: screenWidth * 0.3,
                    y: screenHeight * 0.7,
                    width: screenWidth * 0.4,
                    height: screenHeight * 0.2
                )
                
                if buttonRegion.contains(location) {
                    print("Tap in reset button region")
                    performReset(arView: arView)
                    return
                }
            }
        }
    }
    
    // Reset the game state to allow for another throw
    private func performReset(arView: ARView) {
        print("Resetting game state")
        
        // Remove the thrown pokeball
        self.pokeball?.removeFromParent()
        self.pokeball = nil
        
        // Remove any reset button overlays
        self.removeResetButtonOverlays(from: arView)
        
        // Reset state flags
        self.isPokeballThrown = false
        self.isCaptureInProgress = false
        
        // Restore visibility of the Pokemon (in case it was hidden during previous animations)
        if let pokemon = self.pokemonModel {
            pokemon.isEnabled = true
            pokemon.scale = SIMD3<Float>(0.005, 0.005, 0.005)
            
            // Make sure it's in the correct position
            if pokemon.parent == nil, let planeAnchor = self.planeAnchor {
                pokemon.position = SIMD3<Float>(0, 0.05, -0.5)
                planeAnchor.addChild(pokemon)
                
                // Play animations if available
                for animation in pokemon.availableAnimations {
                    pokemon.playAnimation(animation.repeat())
                }
            }
        }
        
        // Create a new pokeball at the bottom of the screen
        Task {
            do {
                let newPokeball = try await Entity.load(named: "Pokeball_animated")
                newPokeball.scale = SIMD3<Float>(0.005, 0.005, 0.005)
                
                // Create a screen-space anchor for the pokeball
                let newPokeballAnchor = AnchorEntity(.camera)
                newPokeballAnchor.position = SIMD3<Float>(0, -0.3, -0.8) // Position at bottom of screen
                
                newPokeballAnchor.addChild(newPokeball)
                arView.scene.addAnchor(newPokeballAnchor)
                
                // Update references
                self.pokeball = newPokeball
                self.pokeballAnchor = newPokeballAnchor
                
                // Add haptic feedback to confirm reset
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            } catch {
                print("Error creating new pokeball: \(error)")
            }
        }
    }
}

extension ARViewCoordinator {
    // Create a more reliable fixed button that's always visible
    func showFixedResetButton(in arView: ARView) {
        print("Creating fixed reset button")
        
        // First remove any existing buttons
        for anchor in arView.scene.anchors {
            if anchor.name == "reset-button-anchor" {
                anchor.removeFromParent()
            }
        }
        
        // Create a horizontal plane as a button base
        let buttonWidth: Float = 0.2
        let buttonHeight: Float = 0.07
        let buttonDepth: Float = 0.01
        
        let buttonMesh = MeshResource.generateBox(width: buttonWidth, height: buttonHeight, depth: buttonDepth)
        let buttonMaterial = SimpleMaterial(color: .systemBlue, isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        
        // Create more visible text
        let textMesh = MeshResource.generateText(
            "RESET",
            extrusionDepth: 0.005,
            font: .boldSystemFont(ofSize: CGFloat(buttonHeight * 0.7)),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        
        let textMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        // Position text in front of button
        textEntity.position = SIMD3<Float>(0, 0, -0.007)
        textEntity.scale = SIMD3<Float>(0.6, 0.6, 0.6) // Scale down text to fit
        buttonEntity.addChild(textEntity)
        
        // Create a fixed camera-anchored entity
        let buttonAnchor = AnchorEntity(.camera)
        buttonAnchor.name = "reset-button-anchor"
        
        // Position at bottom of screen, closer to camera
        buttonAnchor.position = SIMD3<Float>(0, -0.15, -0.4)
        
        // Make it face the camera directly
        buttonAnchor.look(at: SIMD3<Float>(0, 0, -1), from: buttonAnchor.position, relativeTo: nil)
        
        // Add collision component for tap detection
        buttonEntity.components[CollisionComponent.self] = CollisionComponent(
            shapes: [.generateBox(width: buttonWidth * 1.2, height: buttonHeight * 1.2, depth: buttonDepth)],
            mode: .trigger,
            filter: .sensor
        )
        
        // Add the button to the scene
        buttonAnchor.addChild(buttonEntity)
        arView.scene.addAnchor(buttonAnchor)
        
        // Make the button pulse to draw attention
        animateButtonPulse(button: buttonEntity)
        
        // Ensure we have a tap gesture recognizer
        if !(arView.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) ?? false) {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
            arView.addGestureRecognizer(tapGesture)
        }
        
        // Also subscribe to collision events with this button as a backup interaction method
        arView.scene.subscribe(to: CollisionEvents.Began.self) { [weak self] event in
            if event.entityA.name == "reset-button" || event.entityB.name == "reset-button" {
                self?.performReset(arView: arView)
            }
        }
    }
    
    // Animate button pulsing to draw attention
    private func animateButtonPulse(button: ModelEntity) {
        let pulseAnimation = CustomAnimatable(entity: button, duration: 1.5) { progress in
            // Create a subtle pulsing effect
            let scale = 1.0 + 0.1 * sin(progress * Float.pi * 2)
            button.transform.scale = SIMD3<Float>(scale, scale, 1.0)
            
            // Cycle the color slightly
            if var modelComponent = button.model {
                for index in 0..<modelComponent.materials.count {
                    if let material = modelComponent.materials[index] as? SimpleMaterial {
                        var updatedMaterial = material
                        let brightness = 0.9 + 0.1 * sin(progress * Float.pi * 2)
                        updatedMaterial.color = .init(tint: .systemBlue.withAlphaComponent(CGFloat(brightness)))
                        modelComponent.materials[index] = updatedMaterial
                    }
                }
            }
        }
        
        // Make it repeat indefinitely
        pulseAnimation.start()
        
        // Restart animation every 1.5 seconds
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            // Check if the button still exists
            if button.parent != nil {
                let newAnimation = CustomAnimatable(entity: button, duration: 1.5) { progress in
                    let scale = 1.0 + 0.1 * sin(progress * Float.pi * 2)
                    button.transform.scale = SIMD3<Float>(scale, scale, 1.0)
                    
                    if var modelComponent = button.model {
                        for index in 0..<modelComponent.materials.count {
                            if let material = modelComponent.materials[index] as? SimpleMaterial {
                                var updatedMaterial = material
                                let brightness = 0.9 + 0.1 * sin(progress * Float.pi * 2)
                                updatedMaterial.color = .init(tint: .systemBlue.withAlphaComponent(CGFloat(brightness)))
                                modelComponent.materials[index] = updatedMaterial
                            }
                        }
                    }
                }
                newAnimation.start()
            } else {
                // Button was removed, stop timer
                timer.invalidate()
            }
        }
    }
}

extension ARViewCoordinator {
    // Create a SwiftUI reset button overlay that's guaranteed to work
    func showResetButtonOverlay(in arView: ARView) {
        print("Creating SwiftUI reset button overlay")
        
        // Create a UIHostingController to wrap our SwiftUI view
        let resetButtonHostingController = UIHostingController(
            rootView: ResetButton {
                // This closure is called when the button is tapped
                self.performReset(arView: arView)
            }
        )
        
        // Make the background transparent
        resetButtonHostingController.view.backgroundColor = .clear
        
        // Find the ARView's parent view controller
        var responder: UIResponder? = arView
        while let nextResponder = responder?.next {
            responder = nextResponder
            if let viewController = responder as? UIViewController {
                // Add the hosting controller as a child
                viewController.addChild(resetButtonHostingController)
                viewController.view.addSubview(resetButtonHostingController.view)
                
                // Configure the button position and size
                resetButtonHostingController.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    resetButtonHostingController.view.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
                    resetButtonHostingController.view.bottomAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                    resetButtonHostingController.view.widthAnchor.constraint(equalToConstant: 140),
                    resetButtonHostingController.view.heightAnchor.constraint(equalToConstant: 50)
                ])
                
                resetButtonHostingController.didMove(toParent: viewController)
                break
            }
        }
    }
    
    // Method to remove any existing SwiftUI reset button overlays
    func removeResetButtonOverlays(from arView: ARView) {
        var responder: UIResponder? = arView
        while let nextResponder = responder?.next {
            responder = nextResponder
            if let viewController = responder as? UIViewController {
                // Find and remove any hosting controllers for ResetButton
                for child in viewController.children {
                    if let hostingController = child as? UIHostingController<ResetButton> {
                        hostingController.willMove(toParent: nil)
                        hostingController.view.removeFromSuperview()
                        hostingController.removeFromParent()
                    }
                }
                break
            }
        }
    }
}

// SwiftUI Reset Button component
struct ResetButton: View {
    var action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.impactOccurred()
            action()
        }) {
            Text("Try Again")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue)
                        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

extension ARViewCoordinator {
    // Add physics for natural rolling motion when the pokeball hits the ground
    func addPhysicsForRoll(to entity: ModelEntity) {
        // Remove any existing physics components first to avoid conflicts
        entity.components.remove(PhysicsBodyComponent.self)
        entity.components.remove(PhysicsMotionComponent.self)
        
        // Add physics body with appropriate mass and material properties for rolling
        entity.components[PhysicsBodyComponent.self] = PhysicsBodyComponent(
            massProperties: .init(mass: 0.1, inertia: SIMD3<Float>.zero, centerOfMass: (position: SIMD3<Float>.zero, orientation: simd_quatf(angle: 0, axis: [0, 1, 0]))), // Use tuple for centerOfMass
            material: PhysicsMaterialResource.generate(friction: 0.5, restitution: 0.2),
            mode: .dynamic
        )
        
        // Calculate a small impulse to make the ball roll slightly
        let randomDirection = normalize(SIMD3<Float>(
            Float.random(in: -0.5...0.5),
            0,
            Float.random(in: -0.5...0.5)
        ))
        
        // Add a small impulse for a subtle roll effect
        let impulseStrength: Float = 0.002
        let impulse = randomDirection * impulseStrength
        
        // Apply the impulse as a motion component
        entity.components[PhysicsMotionComponent.self] = PhysicsMotionComponent(
            linearVelocity: impulse,
            angularVelocity: SIMD3<Float>(
                impulse.z * 10,
                0,
                -impulse.x * 10
            )
        )
        
        print("Added physics for natural roll with impulse: \(impulse)")
    }
}

// Add dummy CustomAnimatable class to satisfy references
class CustomAnimatable {
    init(entity: ModelEntity, duration: Float, updateBlock: @escaping (Float) -> Void) {}
    func start() {}
    func stop() {}
}

#Preview {
    ContentView()
}
