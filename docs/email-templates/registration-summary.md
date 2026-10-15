# Teamregistrierung: Ablauf, E-Mails und Speicherung

Stand: 15.10.2026. Dieser Ablauf ersetzt die frühere Grafik mit einer separaten Admin-Einladung.

## Verbindlicher Ablauf

1. Homepage: Teamantrag mit zwei Kontakten absenden. App: zuerst Konto anlegen und E-Mail bestätigen (24 Stunden gültig, erneuter Versand nach 60 Sekunden), dann Teamantrag absenden.
2. Anfrage wird als eigener Registrierungsdatensatz gespeichert. Es entsteht noch kein Team. Die Willkommensmail enthält sofort Vertragsdownload und geschützten Upload-Link (30 Tage). Das Büro erhält eine Informationsmail; es muss keinen Link freischalten.
3. Nutzer lädt unterschriebenen Vertrag und beide Ausweise hoch und ergänzt die vollständigen Kontakte, über die Homepage oder App. Teilspeichern und Ersetzen sind bei offenen Anträgen möglich. Logo optional. Trikotfotos können per E-Mail gesendet werden; dafür gibt es kein eigenes Uploadfeld. Per E-Mail eingegangene Pflichtunterlagen muss der Admin im Antrag hinterlegen.
4. Vollständige Unterlagen lösen Bestätigungen an Hauptkontakt und Büro aus. Erst jetzt beginnt die fachliche Prüfung. Vollständige Unterlagen bedeuten noch keine Annahme.
5. Admin lehnt ab (Ablehnungsmail) oder nimmt durch Ligazuweisung an. Ligazuweisung erfordert serverseitig beide Ausweise, Vertrag und gültige Kontakte. Betrag einschließlich Kaution wird einmal berechnet; die Zahlungsanforderung enthält Bankverbindung und Teamname als Referenz.
6. Admin verbucht Zahlung. Teilzahlungen lassen einen offenen Saldo bestehen; erneutes Absenden derselben Zahlungs-ID bucht nicht doppelt. Eine Zahlungsbestätigung wird gesendet.
7. Nach vollständiger Zahlung bestätigt der Admin die Team-Erstellung ausdrücklich. Neue Konten bekommen E-Mail und generiertes Passwort; vorhandene Konten behalten ihr Passwort und erhalten eine Freigabemail. Zahlung allein erstellt kein Team.
8. Ein fehlgeschlagener Mailversand ist im Admin sichtbar und kann erneut ausgelöst werden. Ein fehlgeschlagener Login-Mailversand erstellt beim Wiederholen kein zweites Team. SMTP-Erfolg bedeutet Versandannahme, keine garantierte Zustellung im Posteingang.

## Komponenten und Berechtigungen

- Homepage: Registrierungsformular, geschützte Uploadseite und Verifizierungsseite.
- Livescore: Konto-Verifizierung, Antrag, Unterlagen-Nachreichung und Weiterführung passender Website-Anträge nach Verifizierung derselben E-Mail.
- API: öffentliche Erstanfrage/Verifizierung; Upload-Link mit X-Email-Action-Token; App-Lesen/Uploads mit Bearer-Token und Eigentümerprüfung; Admin-Aktionen geschützt.
- ÖKFB Client: Registrierungsliste und Detailaktionen; E-Mail Notifier unter `/admin/email-templates` mit HTML-/visuellem Editor, Signatur, Logo und Vorschau. Zugriff erfordert Admin und `communications.manage`.
- Pflichtvariablen für Upload-/Verifizierungslinks, Zahlungsdaten und Login-Daten dürfen im Editor nicht entfernt werden. Veraltete ungültige Overrides der drei Hauptmails verwenden den aktuellen Standard; die Editorliste zeigt denselben effektiven Inhalt wie der Versand.

## Speicherung und Produktion

MongoDB-Datenbank lokal: `oekfb_database`, Port 27018. Collection: `email_templates` (kein SQL-Table). Dokumentfelder: `_id` = Template-Schlüssel, `subject`, `html`. Variablenlisten liegen im Codekatalog; Werte werden erst beim Versand eingesetzt.

Vor der Änderung war die lokale Collection leer. Jetzt sind 26 Vorlagen gespeichert. `local-before-update.json` dokumentiert den vorherigen leeren Zustand. `local-export.json` ist der Export der tatsächlich gespeicherten lokalen Daten. `defaults.json` enthält die Code-Standards. `registration-production.json` enthält nur die 11 für diesen Ablauf relevanten Vorlagen, damit andere Produktionsvorlagen nicht überschrieben werden müssen.

Eine lokale Datenbankänderung wird durch Git-Push nicht nach Produktion übertragen. API und Frontends deployen, danach die gewählte JSON-Datei ausdrücklich in die Produktions-Collection importieren. Der Import ersetzt die gleichnamigen Vorlagen und ergänzt fehlende; andere Schlüssel bleiben bestehen. Das Importscript erstellt vorher ein Backup.

Beispiel vom Repository-Root mit `mongosh` und bereits sicher gesetztem `MONGODB_URI` (inklusive Zieldatenbank):

```sh
export EXPECTED_DATABASE=oekfb_database
export TEMPLATE_FILE="$PWD/docs/email-templates/registration-production.json"
mongosh "$MONGODB_URI" --quiet --file scripts/import-email-templates.js
```

Für alle 26 lokalen Vorlagen stattdessen `local-export.json` wählen. `MONGODB_URI` nicht im Repository speichern. `EXPECTED_DATABASE` bei abweichendem Produktionsnamen anpassen. Keine Produktionsdaten wurden in dieser Aufgabe verändert.

Konfiguration vor dem Onlinebetrieb:

- Backend `REGISTRATION_WEB_BASE_URL`: tatsächliche öffentliche Homepage; nicht localhost. Der bisherige Standard ist `https://www.oekfb.eu`.
- Homepage `API_BASE_URL`: `https://api.oekfb.eu`, falls dies die Produktions-API ist. Livescore nutzt diesen Host bereits.
- Backend `REGISTRATION_CONTRACT_URL`: öffentlich abrufbarer aktueller Vertrag; `EMAIL_ACTION_SECRET`: bestehendes stabiles Secret mit mindestens 32 Zeichen.
- SMTP, Firebase und `REGISTRATION_ADMIN_EMAIL` korrekt in Produktion setzen.
- Falls die Homepage tatsächlich `archivepay.eu` ist: deren genaue HTTPS-Origin muss zusätzlich in der API-CORS-Liste stehen. ÖKFB-Domains sind bereits erlaubt. Lokale Funktion allein bestätigt keine Produktionskonfiguration.

Keine Tests, Builds oder echten E-Mails ausgeführt. Prüfung erfolgte anhand des Codes; lokale Speicherung und Export wurden durchgeführt. Die Bankdaten unten sind aus der bestehenden Vorlage übernommen, nicht extern verifiziert.

## Gespeicherte E-Mail-Inhalte

Die folgenden Texte stammen aus dem lokalen Datenbankexport. HTML-Formatierung ist vereinfacht; Linkziele und {{Variablen}} bleiben sichtbar. Vollständiges HTML steht in den JSON-Dateien.

### sendEmailVerificationLink

**Betreff:** OEKFB E-Mail bestätigen

Österreichischer Kleinfeld Fußball Bund

Sehr geehrte Damen und Herren,

bitte bestätigen Sie Ihre E-Mail-Adresse, indem Sie auf folgenden Button klicken:

            E-Mail bestätigen ({{verificationUrl}})

            Falls der Button nicht funktioniert, öffnen Sie bitte diesen Link in Ihrem Browser:

            {{verificationUrl}}

Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, kontaktieren Sie uns bitte unter support@oekfb.eu (mailto:support@oekfb.eu).

### sendWelcomeMail

**Betreff:** ÖKFB Anmeldung – Willkommen und Unterlagen

Sehr geehrter Mannschaftsleiter,

herzlich willkommen beim Österreichischen Kleinfeld Fußball Bund. Ihre Mannschaftsanmeldung ist eingegangen.

Bitte laden Sie den Vertrag herunter und reichen Sie die folgenden Unterlagen über Ihre persönliche Uploadseite oder die App ein:

• Ausgefüllter und unterschriebener Vertrag

• Ausweiskopien beider Personen am Vertrag

• Vollständige Namen und Kontaktdaten beider Vertragspartner

Vertrag herunterladen ({{contractUrl}})

Unterlagen sicher hochladen ({{uploadUrl}})

Ihr persönlicher Upload-Link ist 30 Tage gültig. Sie können Unterlagen ergänzen oder ersetzen, solange Ihre Anmeldung noch offen ist. Bitte geben Sie den Link nicht weiter.

Ihr Teamlogo können Sie optional auf der Uploadseite ergänzen. Bilder der Heim- und Auswärtstrikots inklusive Stutzen senden Sie bitte an office@oekfb.eu. Falls Sie noch Trikots benötigen: Angebote für ÖKFB-Mannschaften (https://erima.shop/oekfb).

Alternativ können Sie Unterlagen an office@oekfb.eu senden. Diese müssen anschließend durch die Administration Ihrer Anmeldung zugeordnet werden.

Nach vollständigem Eingang prüft die Administration Ihren Antrag. Bei Annahme und Ligazuweisung erhalten Sie den zu zahlenden Betrag und die Bankverbindung per E-Mail. Nach Zahlung und abschließender Freigabe wird Ihre Mannschaft angelegt.

Sportliche Grüße
Ihr ÖKFB Team

Dies ist eine automatisch generierte E-Mail. Bei Fragen: office@oekfb.eu.

### registration.adminRequestReceived

**Betreff:** ÖKFB – Neue Mannschaftsanmeldung

Eine neue Mannschaftsanmeldung liegt vor: {{registrationId}}. Die Unterlagen werden automatisch angefordert. Bitte erst nach vollständigem Eingang prüfen.

### registration.documentsReceived

**Betreff:** ÖKFB – Unterlagen eingegangen

Ihre Unterlagen wurden gespeichert und werden von der Administration geprüft. Eine Mannschaft wird erst nach Freigabe angelegt.

### registration.adminDocumentsReceived

**Betreff:** ÖKFB – Anmeldung zur Prüfung

Die erforderlichen Unterlagen zur Anmeldung {{registrationId}} sind vollständig eingegangen. Bitte prüfen Sie die Anmeldung und entscheiden Sie über Annahme und Ligazuweisung oder Ablehnung.

### sendPaymentMail

**Betreff:** OEKFB Anmeldung - Zahlungsanforderung

Sehr geehrter Mannschaftsleiter,

Ihre Unterlagen wurden geprüft und Ihre Anmeldung wurde angenommen. Ihrer Mannschaft wurde eine Liga zugewiesen. Hier finden Sie den aktuellen Zahlungsstand:

• Offener Gesamtbetrag inklusive Kaution: € {{amount}}

• Kaution: € {{deposit}} (im Gesamtbetrag enthalten)

Bitte überweisen Sie die Summe von € {{amount}} und verwenden Sie als Zahlungsreferenz bitte {{teamName}}.

Kontodaten:

Österreichischer Kleinfeld Fußball Bund

    AT26 2011 1829 7052 4200

    GIBAATWWXXX

Mit freundlichen Grüßen,

    Österreichischer Kleinfeld Fußball Bund

Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.

### registration.paymentReceived

**Betreff:** ÖKFB – Zahlung verbucht

Ihre Zahlung wurde verbucht. Aktueller Saldo: {{balance}} EUR. Die Administration prüft die Freigabe Ihrer Mannschaft.

### sendTeamLogin

**Betreff:** OEKFB Anmeldung - Mannschaft Login Daten

Sehr geehrter Mannschaftsleiter,

Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund.

Anbei sind ihre Login Daten:

Email: {{email}}
Passwort: {{password}}

Ihre Mannschaft wurde freigegeben. Sie können sich in der ÖKFB App oder unter https://team.oekfb.eu anmelden.

Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.

### registration.approved

**Betreff:** ÖKFB – Mannschaft freigegeben

Ihre Mannschaft wurde freigegeben. Melden Sie sich mit Ihren bestehenden Zugangsdaten in der ÖKFB App an.

### registration.rejected

**Betreff:** ÖKFB – Entscheidung zu Ihrer Anmeldung

Ihre Mannschaftsanmeldung wurde abgelehnt. Bei Fragen wenden Sie sich bitte an office@oekfb.eu.

### registration.documentsRequested

**Betreff:** ÖKFB – Bitte Anmeldeunterlagen hochladen

Bitte laden Sie den unterschriebenen Vertrag und die Ausweise beider Kontaktpersonen hoch und prüfen Sie deren Namen und Kontaktdaten.

Vertrag herunterladen ({{contractUrl}})

Unterlagen sicher hochladen ({{uploadUrl}}) (30 Tage gültig)

Dieser persönliche Link darf nicht weitergegeben werden. Die Mannschaft wird erst nach Prüfung und Freigabe durch die Administration angelegt.
