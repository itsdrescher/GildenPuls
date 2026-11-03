# GildenPuls

Live-Ticker für eure WoW-Forever-Gilde – gebaut für den Stream.
Zeigt Pop-ups im Spielbild, wenn jemand aus der Gilde:

- ein **Level** aufsteigt (alle 10 Level als *Meilenstein*, Level 60 als *Max Level*)
- **stirbt** – inkl. Gegner bzw. Ursache (Sturz, Ertrinken …) und Gebiet
- der Gilde **beitritt** oder sie **verlässt**

Alle Events werden gespeichert (`GildenPulsDB`) – Grundlage für die spätere Statistik-Seite.

## So funktioniert's

| Event | Mit Addon beim Spieler | Ohne Addon beim Spieler |
|---|---|---|
| Level-Up | sofort | mit bis zu ~20 s Verzögerung (über die Gildenliste) |
| Tod | sofort, mit Ursache | ❌ nicht erkennbar |
| Beitritt / Austritt | über die Gildenliste | über die Gildenliste |

→ Je mehr Gildenmitglieder das Addon installieren, desto vollständiger der Ticker.

## Befehle

| Befehl | Funktion |
|---|---|
| `/gp test` | alle Beispiel-Pop-ups nacheinander |
| `/gp test tod` | einzelnes Beispiel (`level`, `meilenstein`, `max`, `tod`, `join`, `leave`) |
| `/gp unlock` / `/gp lock` | Position verschieben / speichern |
| `/gp scale 1.2` | Größe |
| `/gp dauer 7` | Anzeigedauer in Sekunden |
| `/gp sound` | Sound an/aus |
| `/gp joinleave` | Beitritte/Austritte an/aus |
| `/gp verlauf 10` | letzte Events im Chat |
| `/gp wer` | wer online das Addon nutzt |
| `/gp reset` | Verlauf löschen |

## Installation von Hand

Ordner `GildenPuls` in den AddOns-Ordner von WoW Forever kopieren, z. B.
`World of Warcraft\_forever_\Interface\AddOns\GildenPuls`
(der genaue Ordnername von Forever steht im WoW-Installationsverzeichnis).

## Installation über WowUp (für die Gilde)

1. Dieses Projekt als **öffentliches GitHub-Repo** hochladen.
2. Release erstellen, indem ein Tag gepusht wird:
   `git tag v1.0.0 && git push origin v1.0.0`
   → GitHub baut automatisch `GildenPuls-v1.0.0.zip` und hängt sie an das Release.
3. Gildenmitglieder in WowUp: **Get Addons → Install from URL** → Repo-Link einfügen.
4. Updates: neuen Tag pushen (`v1.0.1` …) – WowUp zeigt das Update automatisch an.

Später optional zusätzlich auf CurseForge / Wago veröffentlichen (dann ist es in WowUp auch über die Suche findbar).

## Wichtig zum Release von WoW Forever

Die Interface-Nummer in `GildenPuls.toc` ist vorläufig. Am Release-Tag im Spiel eingeben:

```
/dump select(4, GetBuildInfo())
```

Die angezeigte Zahl in `## Interface:` eintragen. Bis dahin hilft im AddOn-Menü der Haken **„Veraltete AddOns laden“**.
