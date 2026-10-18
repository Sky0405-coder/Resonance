# Resonance Bücher – KOReader-Plugin

Bücher aus Resonance direkt auf dem E-Reader (Kindle, Kobo, Tolino, Android – überall, wo KOReader läuft):
suchen, anfragen, herunterladen. Fertige Anfragen werden automatisch geladen, sobald das WLAN verbunden ist.

## Installation

1. Den Ordner `resonance.koplugin` nach `koreader/plugins/` auf dem Gerät kopieren
   (Kindle: `/mnt/us/koreader/plugins/`).
2. KOReader neu starten.
3. Dateibrowser → Menü „Suche“ → **Resonance Bücher** → mit dem Resonance-Konto anmelden.

Bücher landen standardmäßig in `<Startordner>/Resonance` (änderbar über das Zahnrad oben links).

## Ohne Plugin

- **OPDS-Katalog:** `https://<server>/opds` – Benutzername + App-Passwort (Einstellungen → OpenSubsonic).
- **Lesefortschritt synchronisieren:** KOReader → Fortschritts-Synchronisation → eigener Server
  `https://<server>/kosync`, Anmeldung mit Benutzername + App-Passwort.
