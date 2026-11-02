# Fonts

All fonts are under the SIL Open Font License 1.1 (see `licenses/`). The files
are the unmodified static instances served by Google Fonts, so their names
(including the reserved names "Playfair Display" and "Italiana") are used as the
licence allows.

| File | Used for |
|---|---|
| PlayfairDisplay-Medium.ttf, PlayfairDisplay-Italic.ttf | Display and editorial headings, text overlays |
| Inter-Regular/Medium/SemiBold.ttf | UI text |
| CormorantGaramond-MediumItalic.ttf | Text overlays |
| Italiana-Regular.ttf | Text overlays |
| BodoniModa-Medium.ttf | Text overlays |

To add a font: drop the .ttf here, add it to `UIAppFonts` in `project.yml`, and
add an `OverlayFont` entry in `AurumCore/OverlayAssets.swift` using its PostScript name.
