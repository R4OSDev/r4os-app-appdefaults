APPDEF.R4X
==========

APPDEF.R4X verwaltet Desktop-nahe App-Zuordnungen und Standardprogramme.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\AppDefaults
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\AppDefaults\zig-out\APPDEF.R4X

Contract:
- R4XStart-Entry: `appdef_main`
- App-Klasse: `gui`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\APPDEF.R4X`

