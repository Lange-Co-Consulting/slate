# Slate · Compliance & Richtlinien

Praktische Übersicht der rechtlichen Pflichten für **Website + App + zukünftigen Verkauf**.
Anbieter/Verantwortlicher: **Lange und Co. Consulting GmbH**, Gertrud-Luckner-Straße 5,
48282 Emsdetten · Geschäftsführer Lucas Lange · Amtsgericht Steinfurt HRB 15830 ·
USt-IdNr. DE460959877 · info@lange-co-consulting.de.

> ⚠️ **Kein Rechtsrat.** Diese Datei ist eine interne Arbeitshilfe. Vor dem öffentlichen
> Launch (insbesondere vor dem ersten Verkauf) sollte ein:e Fachanwält:in für IT-/
> Datenschutzrecht die Texte und den Checkout-Prozess prüfen.

## Status-Legende
✅ umgesetzt · 🟡 offen vor Launch · ⬜ erst beim bezahlten Verkauf relevant

---

## 1. Impressumspflicht · ✅
- § 5 DDG (ehem. § 5 TMG) und § 18 MStV: vollständige Anbieterkennzeichnung.
- Umgesetzt in `landing/imprint.html` mit echten Registerdaten. Im Footer jeder Seite verlinkt.
- Pflicht: leicht erkennbar, unmittelbar erreichbar, ständig verfügbar. ✅ (Footer-Link „Impressum").

## 2. Datenschutz (DSGVO) · ✅ Texte / 🟡 Organisatorisches
- Art. 13 Informationspflichten: `landing/privacy.html` (Website Teil A + App Teil B). ✅
- Zuständige Aufsichtsbehörde: **LDI NRW**, Düsseldorf (NRW). ✅ genannt.
- 🟡 **Auftragsverarbeitung (Art. 28):** AV-Vertrag mit dem Hosting-Anbieter abschließen.
  Die DS-Erklärung nennt **Cloudflare Pages** (wie die Hauptseite). Wenn Slate woanders
  gehostet wird → Abschnitt A.2 anpassen und passenden AV-Vertrag/SCC sicherstellen.
- 🟡 **Verzeichnis von Verarbeitungstätigkeiten (Art. 30):** intern führen (Website-Logs,
  Kontaktanfragen). Für ein kleines Unternehmen kurz, aber vorhanden.
- ✅ Kein Datenschutzbeauftragter nötig (Art. 37, keine Pflicht).
- ✅ Betroffenenrechte (Art. 15–21) beschrieben; Anlaufstelle info@…

## 3. Cookies / Tracking (TDDDG § 25) · ✅
- Website nutzt **keine** Cookies, kein Analytics, keine Third-Party-Fonts, keine Pixel →
  **kein Consent-Banner erforderlich.** (Belegt im Code: keine Netzwerkaufrufe, System-Fonts.)
- 🟡 Falls später Analytics/Marketing-Tools ergänzt werden: TDDDG-Einwilligung (Consent-Banner)
  + Anpassung der DS-Erklärung nötig.

## 4. Barrierefreiheit (BFSG, ab 28.06.2025) · ✅ Website / ⬜ Checkout
- Das Barrierefreiheitsstärkungsgesetz erfasst u. a. B2C-Dienstleistungen im E-Commerce.
- Website: auf WCAG 2.1 AA getunt (Kontraste, ARIA, Tastaturbedienung, reduced-motion). ✅
- ⬜ Sobald ein **Kauf-/Checkout-Flow** existiert, muss auch dieser barrierefrei sein
  (EN 301 549 / WCAG). App-UI ebenfalls möglichst zugänglich halten.

## 5. Verbraucherverkauf (erst bei Bezahl-Launch) · ⬜
- **Widerrufsrecht** (§§ 355 ff. BGB): 14 Tage bei digitalen Inhalten; erlischt nur bei
  ausdrücklicher Zustimmung zum sofortigen Beginn **und** Kenntnisnahme des Erlöschens.
  → Widerrufsbelehrung + Muster-Widerrufsformular bereitstellen.
- **Button-Lösung** (§ 312j BGB): Bestellbutton mit „zahlungspflichtig bestellen".
- **Vorvertragliche Pflichtinfos**: Preis inkl. USt, Gesamtpreis, wesentliche Eigenschaften,
  Vertragslaufzeit, Zahlungs-/Lieferbedingungen.
- **AGB / EULA**: Lizenzbedingungen der App (Nutzungsrecht, Haftung, Gewährleistung).
- **USt / Umsatzsteuer**: bei EU-B2C digitalen Produkten Leistungsort = Wohnsitz des Kunden;
  ggf. **OSS-Verfahren** (One-Stop-Shop) nutzen. Bei Verkauf über App Store/Paddle o. Ä. tritt
  der Anbieter ggf. als „Merchant of Record" auf → USt-Handling ändert sich.
- **Preisangabenverordnung**: Endpreise inkl. USt ausweisen.

## 6. Urheber- & Lizenzrecht · ✅ / 🟡
- ✅ Die tatsächlich ausgelieferten Code-/Binary-Lizenzen sind in
  `THIRD_PARTY_NOTICES.md` inventarisiert; vollständige Texte werden ins App-Bundle kopiert.
- ✅ Slate liefert **keine Modellgewichte** mit. Das gilt auch für Parakeet, Supertonic und
  Silero: Flow importiert sie lokal oder lädt sie erst nach einer ausdrücklichen User-Aktion.
- ✅ Bei kuratierten Downloads zeigt Slate Modellkarte, Lizenzname und Lizenzlink vor dem
  Start; auch dynamische Hub-/URL-Downloads verlangen eine bewusste Bestätigung. Parakeet
  (CC-BY-4.0), Supertonic (OpenRAIL-M) und Silero (MIT) bleiben als transparente Quellen-
  und Lizenzangaben in App, Hilfe und Notices sichtbar.
- ✅ FLUX.2 klein wurde wegen der offiziellen nicht-kommerziellen Modellbedingungen aus
  dem kommerziellen Downloadkatalog entfernt. Der lokale Import kompatibler eigener Dateien
  bleibt möglich und ändert deren Anbieterbedingungen nicht.
- 🟡 Die technische Lizenzinventur ersetzt keine anwaltliche Prüfung der Modell- und
  Produktbedingungen vor dem öffentlichen Bezahl-Launch.
- 🟡 **Namensrecht „Slate":** vor Launch eine Marken-/Namensrecherche (DPMA/EUIPO) durchführen.
  „Slate" ist ein häufiger Produktname.

## 7. Distribution der App · 🟡
- Direktvertrieb: **Developer ID signiert + notarisiert + gestapelt** (bereits als Pflicht im
  `security.html`/Prozess vermerkt). Kein unsignierter Download.
- Alternativ Mac App Store: dann App-Review-Guidelines + **App-Privacy-Labels** (Datennutzung
  deklarieren, bei Slate weitgehend „No Data Collected").

## 8. KI-Transparenz (EU AI Act) · ⬜ beobachten
- Slate ist ein lokales BYO-Modell-Werkzeug ohne eigene Hochrisiko-Funktion. Transparenz-
  pflichten sind gering, aber die Entwicklung des AI Act beobachten (v. a. bei generierten
  Bildern/Sprache, ggf. Kennzeichnungshinweise).

---

### Vor dem öffentlichen Launch (Kurz-Checkliste)
1. 🟡 Hosting bestätigen → DS-Erklärung Abschnitt A.2 + AV-Vertrag angleichen.
2. 🟡 Marken-/Namensrecherche „Slate".
3. 🟡 Signierter, notarisierter Download + echte Download-URL (`site-config.publicDownloadUrl`).
4. ⬜ Bei Bezahl-Launch: EULA/AGB, Widerrufsbelehrung, Button-Lösung, USt/OSS, Preisangaben.
5. 🟡 Fachanwaltliche Endprüfung von Impressum, Datenschutz und Checkout.
