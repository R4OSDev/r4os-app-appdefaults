# APPDEF.R4X

`APPDEF.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.8`
- Image target: `/R4OS/SOFTWARE/DESKTOP/APPDEF.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

APPDEF stores application, subsystem, and deliberately removed default
handlers in `ASSOC.R4S`; installed subsystem host metadata remains sourced
only from `MODULES.JSON`. The shipped `.BAS` default stores only
`r4os.basic` and `basic.qbasic-source`; Notepad remains a normal alternative
handler.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


APPDEF: Bestand und Speicherergebnis ab 0.78.63
---------------------------------------------
ASSOC.R4S wird vor dem Einlesen ueber R4STD CONFIG_V1 wiederhergestellt.
Fehlende und leere Dateien aktivieren Defaults; ein Lese-, Groessen-, Format-
oder Wiederherstellungsfehler sperrt Speichern bis zum erfolgreichen neuen
Laden. Die App importiert CONFIG_V1 jetzt ausdruecklich. OK verwendet
saveDocument statt direktem Ueberschreiben und ungeprueftem Rueckbau.
Bei Fehler bleiben Fenster und Aenderungen offen. Eine ausstehende
Wiederherstellung wird als solche angezeigt, nicht als abgeschlossen.

Der bestehende /SELFTEST arbeitet ab 0.78.63 nur mit vorher abwesenden C:\TEMP\APPDEF.R4S/.TMP/.BAK. Vorhandene private Daten bleiben erhalten. Die echte ASSOC.R4S wird weder gelesen noch geaendert; ein Bereinigungsfehler verhindert den OK-Abschluss.
