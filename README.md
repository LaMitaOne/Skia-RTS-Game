# Skia-RTS-Game
A 2.5D Real-Time Strategy prototype built entirely with Skia4Delphi. A Command &amp; Conquer style experience, featuring A* pathfinding, isometric rendering, AI skirmish combat, destructible environments, and thread-safe particle physics. 

RADStudio FMX / Skia4Delphi RTS Prototype "Skia RTS Game" v0.1 alpha  
   
<img width="1920" height="1080" alt="Unbenannt" src="https://github.com/user-attachments/assets/9ce2dd7b-74e4-4440-8dd7-fc33fd4f6043" />

This is an alpha build. It's not perfect—god knows there might still be hidden bugs or visual quirks—but it is a fully working, highly feature-rich C&C clone that goes way beyond basic movement and shooting. Enjoy! :D

🎮 Gameplay Features

     Isometric 2.5D Rendering: Custom IsoTransform functions project 3D coordinates (X, Y, Z) onto a 2D canvas. Includes dynamic depth sorting (Painter's Algorithm) for large buildings and units.
     A* Pathfinding: Units intelligently navigate around obstacles, water, and each other using a tile-based A* algorithm. If a direct path is blocked during combat, units will dynamically recalculate a path to flank the enemy.
     Collision Avoidance: Units reserve their current and next tiles, preventing them from overlapping or driving through each other.
     RTS Controls: Left-click drag to select units, right-click to move or attack. Middle-click drag to pan the camera.
     C&C Style Unit Spawning: UI buttons below the minimap allow you to dynamically spawn new Tanks and Soldiers at your base during gameplay.
     Dynamic Zoom: Mouse wheel zooms the camera in and out seamlessly. Minimap, selection boxes, and movement coordinates mathematically adapt to the current zoom level.
     Combat System: Units automatically acquire targets within range, rotate their turrets, and fire homing projectiles. Soldiers maintain distance to tanks to shoot from cover.
     Destructible Environments & Base Defenses: Trees and houses have health and can be destroyed. The enemy base is protected by solid walls that must be breached or destroyed.
     Distinct Particle Effects: Thread-safe particle system spawns specific visual effects based on the destruction type:
         Tanks: Massive orange/yellow explosions with semi-transparent smoke.
         Trees: Burst into green leaves and brown wood chips.
         Houses: Break apart into gray concrete blocks and red roof shingles.
         Soldiers: Crushed by tanks, leaving red blood splatters.
     Dynamic Visuals: Tanks and houses show structural cracks when heavily damaged, and tanks emit faint, transparent engine smoke when their health is critical.
     Crush Mechanic: Tanks can run over and instantly kill enemy infantry, leaving a distinct blood splatter.
     Win/Lose State: Game detects when all units of a faction are destroyed, displays a message, and automatically resets the map.
     Large Dynamic Map: 48x48 tile map featuring rivers, two tactical bridges, random lakes, and procedural scenery placement with safe-spacing algorithms.
     Minimap: Transparent, click-to-pan minimap showing the map layout, units, and an exact isometric polygon representing the current camera viewport.
     Tank Tracks: Tanks leave physical tread marks on the ground that align perfectly with their driving direction and slowly fade over time.
     Post-Processing: Press 'F' to cycle between None, Paper, and Cuphead (Film Grain + Vignette) visual filters.

🕹️ Controls

     Move Camera: WASD, Edge Scrolling, or Middle-Click Drag
     Zoom In/Out: Mouse Wheel
     Select Units: Left-Click Drag
     Move/Attack: Right-Click
     Spawn Units: Click 'T' (Tank) or 'S' (Soldier) buttons below the Minimap
     Minimap Navigation: Left-Click on Minimap
     Toggle Filters: 'F'

🛠️ Technical Details

     Renderer: Pure Skia Canvas (No Game Engine, no FMX shapes). Everything is drawn using paths, masks, and procedural shaders.
     Thread-Safe Particle Queue: Physics and AI run on a background thread. To prevent race conditions when modifying the particle list, the physics thread queues explosion requests (position + type) using a TCriticalSection, which the UI thread safely processes during the render loop.
     Single-File Architecture: The complete game engine, including rendering, logic, and procedural texture generation, is contained in one highly commented file.


📦 What's Inside

     SkiaRTSProto.pas: The complete C&C style RTS engine in a single file.
     Sample project and executable(zipped) included.

🚀 Getting Started

    Open the project in RAD Studio (Delphi).
    Ensure you have the Skia4Delphi library installed.
    Run and play!

License

MIT License - Do whatever you want with it. Credits appreciated but not required.

Happy conquering! 🚀👾

More game prototypes:

https://github.com/LaMitaOne/Skia_PlatformerGame   
https://github.com/LaMitaOne/SkiaStarPatrols    
https://github.com/LaMitaOne/Skiatris   
https://github.com/LaMitaOne/Skia-A-Cats-Life   
https://github.com/LaMitaOne/SkiaLemmings   
