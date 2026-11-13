# App icon

The project-owned icon is provided under GPL-3.0-or-later together with the app.
`Resources/AppIcon.png` is the source raster; `Resources/AppIcon.icns` contains
the native macOS sizes. Regenerate sizes using `./script/build_icon.sh`.
The same icon is used in the R3DsToolBox catalogue.

Created using the built-in image generation tool, then refined using that tool.
Native `sips`/`iconutil` only resize and package the selected raster.

## Generation prompt

> Use case: logo-brand. Asset type: final macOS application icon for R3Ds CanonScan, a local document scanning app. Create one polished square 1024px app icon: a compact charcoal portable sheet-fed document scanner in a simple three-quarter view, with one crisp white sheet feeding through and a few subtle dark text lines. Reduced native Apple macOS visual style, beautifully restrained sculpted shapes, soft dimensional lighting, quiet blue accent that suggests a scanning beam. Place the object on a blue rounded-square macOS-style tile with generous safe margins. Strong recognizable silhouette at 32px. Transparent outside the rounded-square tile, true alpha. No letters, no wordmark, no Canon logo, no watermarks, no extra objects, no border frame around the image.

## Refinement prompt

> Refine this exact macOS scanner app icon. Keep the scanner, paper, blue rounded-square tile and composition exactly as they are. Clean up only the outside perimeter: remove ALL scattered blue/cyan specks, fuzzy halos and fringe pixels outside the rounded-square tile. Give the tile a smooth precise rounded-square silhouette with clean antialiased edge and fully transparent surroundings. Square 1024 by 1024 canvas, equal transparent safe margins on all four sides. No text. Preserve the visual design.
