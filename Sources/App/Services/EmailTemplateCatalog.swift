import Vapor

struct MailTemplateDefinition: Content {
    let key: String
    let subject: String
    let html: String
    let variables: [String]
}

enum EmailTemplateCatalog {
    static let all: [MailTemplateDefinition] = [
        .init(key: "approve", subject: "OEKFB Spielverlegung Anfrage - Zusagt", html: #"""
        <html>
        <body>
            <p>Die gegnerische Mannschaft: <strong>{{teamName}}</strong> hat Ihrer Anfrage zur Spielverlegung vom <strong>{{gameday}}. Spieltag, am {{matchDate}}</strong> <strong>zugestimmt</strong>.</p>
            <p>Sie müssen zu diesem Spieltermin nicht erscheinen.</p>
        </body>
        </html>
        """#, variables: ["gameday", "matchDate", "teamName"]),
        .init(key: "deny", subject: "OEKFB Spielverlegung Anfrage - Abgelehnt", html: #"""
        <html>
        <body>
            <p>Die gegnerische Mannschaft: <strong>{{teamName}}</strong> hat der Spielverlegung vom <strong>{{gameday}}. Spieltag, am {{matchDate}}</strong> <strong>nicht zugestimmt</strong>.</p>
            <p>Das Spiel findet wie geplant statt.</p>
        </body>
        </html>
        """#, variables: ["gameday", "matchDate", "teamName"]),
        .init(key: "informRefereeCancellation", subject: "OEKFB Spielabsage - {{matchDate}}", html: #"""
        <html>
        <body>
            <p>Das Spiel: <strong>{{homeTeam}} vs {{awayTeam}}</strong> am <strong>{{gameday}}. Spieltag, {{matchDate}}</strong> wurde <strong>abgesagt</strong>.</p>
            <p>Bitte prüfen Sie den Spielplan.</p>
        </body>
        </html>
        """#, variables: ["awayTeam", "gameday", "homeTeam", "matchDate"]),
        .init(key: "registration.adminDocumentsReceived", subject: "ÖKFB – Anmeldung zur Prüfung", html: #"""
        <p>Die erforderlichen Unterlagen zur Anmeldung {{registrationId}} sind vollständig eingegangen. Bitte prüfen Sie die Anmeldung und entscheiden Sie über Annahme und Ligazuweisung oder Ablehnung.</p>
        """#, variables: ["registrationId"]),
        .init(key: "registration.adminRequestReceived", subject: "ÖKFB – Neue Mannschaftsanmeldung", html: #"""
        <p>Eine neue Mannschaftsanmeldung liegt vor: {{registrationId}}. Die Unterlagen werden automatisch angefordert. Bitte erst nach vollständigem Eingang prüfen.</p>
        """#, variables: ["registrationId"]),
        .init(key: "registration.approved", subject: "ÖKFB – Mannschaft freigegeben", html: #"""
        <p>Ihre Mannschaft wurde freigegeben. Melden Sie sich mit Ihren bestehenden Zugangsdaten in der ÖKFB App an.</p>
        """#, variables: []),
        .init(key: "registration.documentsReceived", subject: "ÖKFB – Unterlagen eingegangen", html: #"""
        <p>Ihre Unterlagen wurden gespeichert und werden von der Administration geprüft. Eine Mannschaft wird erst nach Freigabe angelegt.</p>
        """#, variables: []),
        .init(key: "registration.documentsRequested", subject: "ÖKFB – Bitte Anmeldeunterlagen hochladen", html: #"""
        <p>Bitte laden Sie den unterschriebenen Vertrag und die Ausweise beider Kontaktpersonen hoch und prüfen Sie deren Namen und Kontaktdaten.</p><p><a href="{{contractUrl}}">Vertrag herunterladen</a></p><p><a href="{{uploadUrl}}">Unterlagen sicher hochladen</a> (30 Tage gültig)</p><p>Dieser persönliche Link darf nicht weitergegeben werden. Die Mannschaft wird erst nach Prüfung und Freigabe durch die Administration angelegt.</p>
        """#, variables: ["contractUrl", "uploadUrl"]),
        .init(key: "registration.paymentReceived", subject: "ÖKFB – Zahlung verbucht", html: #"""
        <p>Ihre Zahlung wurde verbucht. Aktueller Saldo: {{balance}} EUR. Die Administration prüft die Freigabe Ihrer Mannschaft.</p>
        """#, variables: ["balance"]),
        .init(key: "registration.rejected", subject: "ÖKFB – Entscheidung zu Ihrer Anmeldung", html: #"""
        <p>Ihre Mannschaftsanmeldung wurde abgelehnt. Bei Fragen wenden Sie sich bitte an office@oekfb.eu.</p>
        """#, variables: []),
        .init(key: "sendCancellationNotification", subject: "OEKFB Absage - Absagen Benachrichtigung", html: #"""
        <html>
        <head>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
            <p>Die gegnerische Mannschaft hat das Spiel vom <strong>{{gameday}}. Spieltag, am {{matchDate}}</strong> offiziell abgesagt.</p>
            <p>Sie müssen zu diesem Spieltermin nicht erscheinen. Ihrer Mannschaft wurden automatisch <strong>3 Punkte</strong> gutgeschrieben und mit 6 Toren gewonnen.</p>
            <p>Sportliche Grüße,<br>Ihr ÖKFB Team</p>
        </body>
        </html>
        """#, variables: ["gameday", "matchDate"]),
        .init(key: "sendEmailVerificationLink", subject: "OEKFB E-Mail bestätigen", html: #"""
        <!DOCTYPE html>
        <html lang="de">
        <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>OEKFB E-Mail bestätigen</title>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
                .container { max-width: 560px; margin: 0 auto; background: #fff; border-radius: 10px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
                h2 { margin: 0 0 10px 0; font-size: 18px; }
                p { margin: 0 0 12px 0; }
                .btn {
                    display: inline-block;
                    padding: 12px 18px;
                    border-radius: 8px;
                    background: #007bff;
                    color: #fff !important;
                    text-decoration: none;
                    font-weight: bold;
                }
                .hint { font-size: 12px; color: #6b7280; margin-top: 12px; }
                .footer { margin-top: 18px; font-size: 12px; color: #6b7280; }
                a { color: #007bff; text-decoration: none; }
                a:hover { text-decoration: underline; }
                .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; word-break: break-all; }
            </style>
        </head>
        <body>
            <div class="container">
                <h2>Österreichischer Kleinfeld Fußball Bund</h2>
        
                <p>Sehr geehrte Damen und Herren,</p>
                <p>bitte bestätigen Sie Ihre E-Mail-Adresse, indem Sie auf folgenden Button klicken:</p>
        
                <p>
                    <a class="btn" href="{{verificationUrl}}">E-Mail bestätigen</a>
                </p>
        
                <p class="hint">
                    Falls der Button nicht funktioniert, öffnen Sie bitte diesen Link in Ihrem Browser:<br/>
                    <span class="mono">{{verificationUrl}}</span>
                </p>
        
                <div class="footer">
                    <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, kontaktieren Sie uns bitte unter <a href="mailto:support@oekfb.eu">support@oekfb.eu</a>.</p>
                </div>
            </div>
        </body>
        </html>
        """#, variables: ["verificationUrl"]),
        .init(key: "sendEmailWithData", subject: "Registration Details", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">Thank you for your registration.
        
        Login: {{email}}
        Password: {{password}}</div>
        """#, variables: ["email", "password"]),
        .init(key: "sendPaymentInstruction", subject: "OEKFB Anmeldung - Willkommen", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">Sehr geehrter Mannschaftsleiter,
        
        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund. Bitte senden Sie uns den Vertrag im Anhang ausgefüllt zurück.
        Wir benötigen noch folgende Unterlagen:
        
        · Ausweiskopie beider Personen am Vertrag
        · Logo des Teams
        · Bilder der Trikots (Heim und Auswärts komplett inklusive Stutzen)
        
        Falls Sie Trikots benötigen und noch keine haben, können Sie sich über die Angebote für ÖKFB Mannschaften hier erkundigen: https://erima.shop/oekfb
        
        Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</div>
        """#, variables: []),
        .init(key: "sendPaymentMail", subject: "OEKFB Anmeldung - Zahlungsanforderung", html: #"""
        <html>
        <head>
            <style>
                body { font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; }
                p { margin-bottom: 10px; }
                ul { padding-left: 20px; }
                li { margin-bottom: 8px; }
                a { font-size: 16px; color: #007bff; text-decoration: none; }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
        
            <p>Ihre Unterlagen wurden geprüft und Ihre Anmeldung wurde angenommen. Ihrer Mannschaft wurde eine Liga zugewiesen. Hier finden Sie den aktuellen Zahlungsstand:</p>
        
            <ul>
                <li>Offener Gesamtbetrag inklusive Kaution: € {{amount}}</li>
                <li>Kaution: € {{deposit}} (im Gesamtbetrag enthalten)</li>
            </ul>
        
            <p>Bitte überweisen Sie die Summe von <strong>€ {{amount}}</strong> und verwenden Sie als Zahlungsreferenz bitte <strong>{{teamName}}</strong>.</p>
        
            <p>Kontodaten:</p>
            <p>Österreichischer Kleinfeld Fußball Bund<br>
            AT26 2011 1829 7052 4200<br>
            GIBAATWWXXX</p>
        
            <p>Mit freundlichen Grüßen,<br>
            Österreichischer Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        </body>
        </html>
        """#, variables: ["amount", "deposit", "teamName"]),
        .init(key: "playerApproved", subject: "OEKFB Spieleranmeldung genehmigt", html: #"""
        <html>
        <body style="font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; color: #333;">
            <p>Guten Tag,</p>
            <p>die Anmeldung von <strong>{{playerName}}</strong> (SID: <strong>{{playerSid}}</strong>) wurde geprüft.</p>
            <p>Ihr Antrag wurde genehmigt. Der Spieler ist ab sofort spielberechtigt.</p>
            <p>Dies ist eine automatisch generierte E-Mail.</p>
            <p>Sportliche Grüße,<br>Ihr ÖKFB Team</p>
        </body>
        </html>
        """#, variables: ["playerName", "playerSid"]),
        .init(key: "playerRejected", subject: "OEKFB Spieleranmeldung abgelehnt", html: #"""
        <html>
        <body style="font-family: Arial, sans-serif; font-size: 14px; line-height: 1.6; color: #333;">
            <p>Guten Tag,</p>
            <p>die Anmeldung von <strong>{{playerName}}</strong> (SID: <strong>{{playerSid}}</strong>) wurde geprüft.</p>
            <p>Ihr Antrag wurde abgelehnt. Grund: {{rejectionReason}}</p>
            <p>Dies ist eine automatisch generierte E-Mail.</p>
            <p>Sportliche Grüße,<br>Ihr ÖKFB Team</p>
        </body>
        </html>
        """#, variables: ["playerName", "playerSid", "rejectionReason"]),
        .init(key: "sendPostPone", subject: "OEKFB Spielverlegung Anfrage", html: #"""
        <html>
          <body style="font-family: Arial, sans-serif; line-height: 1.6;">
            <p>
              Die gegnerische Mannschaft <strong>{{teamName}}</strong> bittet darum, 
              das Spiel vom <strong>{{gameday}}. Spieltag, am {{matchDate}}</strong> 
              offiziell zu verschieben.
            </p>
            <p>
              Bitte bestätigen oder lehnen Sie die Anfrage ab, indem Sie den folgenden Link aufrufen:
            </p>
            <p>
              <a href="{{actionUrl}}">
                Spielverschiebung ansehen
              </a>
            </p>
          </body>
        </html>
        """#, variables: ["gameday", "matchDate", "teamName", "actionUrl"]),
        .init(key: "sendRefLogin", subject: "OEKFB Anmeldung - Willkommen", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">Sehr geehrter Schiedsrichter,
        
        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund.
        
        Anbei sind ihre Login Daten:
        
        Email: {{email}}
        Passwort: {{password}}
        
        Sie können sich einlogen unter https://ref.oekfb.eu.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</div>
        """#, variables: ["email", "password"]),
        .init(key: "sendTeamAccountPassword", subject: "ÖKFB – Passwort zurückgesetzt", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">Ihr ÖKFB-Passwort wurde von der Administration zurückgesetzt.
        
        Login: {{email}}
        Neues Passwort: {{password}}
        
        Bitte ändern Sie das Passwort nach der Anmeldung. Es gilt für alle Mannschaften dieses Benutzerkontos.</div>
        """#, variables: ["email", "password"]),
        .init(key: "sendTeamLogin", subject: "OEKFB Anmeldung - Mannschaft Login Daten", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">Sehr geehrter Mannschaftsleiter,
        
        Herzlich Willkommen bei der Österreichischen Kleinfeld Fußball Bund.
        
        Anbei sind ihre Login Daten:
        
        Email: {{email}}
        Passwort: {{password}}
        
        Ihre Mannschaft wurde freigegeben. Sie können sich in der ÖKFB App oder unter https://team.oekfb.eu anmelden.
        
        Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</div>
        """#, variables: ["email", "password"]),
        .init(key: "sendTestEmail", subject: "Test Email", html: #"""
        <div style="font-family:Arial,sans-serif;line-height:1.6;white-space:pre-wrap">This is a test email sent from Vapor application.</div>
        """#, variables: []),
        .init(key: "sendTransferRequest", subject: "OEKFB Anmeldung - Transfer Anfrage", html: #"""
        <html>
        <body style="font-family: Arial, sans-serif; font-size: 14px; color: #333;">
            <p>Hallo {{playerName}},</p>
        
            <p>Die Mannschaft <strong>{{teamName}}</strong> hat dir eine Anfrage geschickt, ihrer Mannschaft beizutreten und deine derzeitige zu verlassen. Willst du diese Anfrage annehmen?</p>
        
            <p>Um diese Anfrage anzunehmen oder abzulehnen, klicken Sie bitte auf den folgenden Button:</p>
        
            <a href="{{actionUrl}}" style="display: inline-block; padding: 10px 20px; font-size: 16px; color: white; background-color: #007bff; text-align: center; text-decoration: none; border-radius: 5px;">Transfer Anfrage beantworten</a>
        
            <p>Wir freuen uns über Ihre baldige Rückmeldung und verbleiben.</p>
        
            <p>Mit freundlichen Grüßen,<br>Österreichische Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        
        </body>
        </html>
        """#, variables: ["playerName", "teamName", "actionUrl"]),
        .init(key: "sendUpdatePlayerData", subject: "OEKFB Spieleranmeldung: {{playerSid}}", html: #"""
        <!DOCTYPE html>
        <html lang="de">
        <head>
            <meta charset="UTF-8">
            <title>Spielerdaten Update</title>
            <style>
                body {
                    font-family: Arial, sans-serif;
                    line-height: 1.6;
                    color: #333;
                    margin: 0;
                    padding: 20px;
                    background-color: #f8f9fa;
                }
                p {
                    margin: 0 0 15px 0;
                }
                ul {
                    margin: 0 0 15px 20px;
                    padding: 0;
                    list-style-type: disc;
                }
                li {
                    margin-bottom: 10px;
                }
                a {
                    color: #007bff;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                .signature {
                    margin-top: 30px;
                }
            </style>
        </head>
        <body>
            <p>Sehr geehrter Mannschaftsleiter,</p>
        
            <p>bitte überprüfen Sie erneut die hochgeladenen Daten Ihres Spielers <strong>{{playerName}}</strong> mit der SID Nummer <strong>{{playerSid}}</strong>. Anscheinend fehlen bei der Anmeldung:</p>
        
            <ul>
                <li>Das Profilbild des Spielers</li>
                <li>Die E-Mail-Adresse des Spielers</li>
                <li>Die Lesbarkeit des Ausweises des Spielers</li>
            </ul>
        
            <p>Bitte beachten Sie, dass sowohl das Profilbild als auch eine lesbare Kopie des Ausweises des Spielers erneut hochgeladen werden müssen. Alle Dokumente müssen gemäß der Ligaordnung hochgeladen und überprüft werden, bevor der Spieler zugelassen werden kann. Bis zur Überprüfung bleibt der Status des Spielers auf „WARTEN“ und es wird kein Bild angezeigt.</p>
        
            <p>Sie können sich auf <a href="https://team.oekfb.eu">team.oekfb.eu</a> einloggen, auf "Spieler bearbeiten" klicken und dort die fehlenden Dokumente hochladen. Diese Änderung ist mit keinen weiteren Kosten verbunden.</p>
        
            <p class="signature">Mit freundlichen Grüßen,<br>
            Der Österreichischer Kleinfeld Fußball Bund</p>
            <p>Dies ist eine automatisch generierte E-Mail. Sollten Sie Fragen haben oder Unterstützung benötigen, zögern Sie bitte nicht, uns unter support@oekfb.eu zu kontaktieren. Wir stehen Ihnen gerne zur Verfügung.</p>
        </body>
        </html>
        """#, variables: ["playerName", "playerSid"]),
        .init(key: "sendWelcomeMail", subject: "ÖKFB Anmeldung – Willkommen und Unterlagen", html: #"""
        <html lang="de"><body style="font-family:Arial,sans-serif;color:#172b4d;line-height:1.6">
        <p>Sehr geehrter Mannschaftsleiter,</p>
        <p>herzlich willkommen beim Österreichischen Kleinfeld Fußball Bund. Ihre Mannschaftsanmeldung ist eingegangen.</p>
        <p>Bitte laden Sie den Vertrag herunter und reichen Sie die folgenden Unterlagen über Ihre persönliche Uploadseite oder die App ein:</p>
        <ul><li>Ausgefüllter und unterschriebener Vertrag</li><li>Ausweiskopien beider Personen am Vertrag</li><li>Vollständige Namen und Kontaktdaten beider Vertragspartner</li></ul>
        <p><a href="{{contractUrl}}">Vertrag herunterladen</a></p>
        <p><a href="{{uploadUrl}}" style="display:inline-block;padding:12px 18px;background:#087f5b;color:#fff;text-decoration:none;border-radius:6px">Unterlagen sicher hochladen</a></p>
        <p>Ihr persönlicher Upload-Link ist 30 Tage gültig. Sie können Unterlagen ergänzen oder ersetzen, solange Ihre Anmeldung noch offen ist. Bitte geben Sie den Link nicht weiter.</p>
        <p>Ihr Teamlogo können Sie optional auf der Uploadseite ergänzen. Bilder der Heim- und Auswärtstrikots inklusive Stutzen senden Sie bitte an office@oekfb.eu. Falls Sie noch Trikots benötigen: <a href="https://erima.shop/oekfb">Angebote für ÖKFB-Mannschaften</a>.</p>
        <p>Alternativ können Sie Unterlagen an office@oekfb.eu senden. Diese müssen anschließend durch die Administration Ihrer Anmeldung zugeordnet werden.</p>
        <p>Nach vollständigem Eingang prüft die Administration Ihren Antrag. Bei Annahme und Ligazuweisung erhalten Sie den zu zahlenden Betrag und die Bankverbindung per E-Mail. Nach Zahlung und abschließender Freigabe wird Ihre Mannschaft angelegt.</p>
        <p>Sportliche Grüße<br>Ihr ÖKFB Team</p><p>Dies ist eine automatisch generierte E-Mail. Bei Fragen: office@oekfb.eu.</p>
        </body></html>
        """#, variables: ["contractUrl", "uploadUrl"]),
        .init(key: "teamTopUp", subject: "ÖKFB – Guthaben Einzahlung {{invoiceNumber}}", html: #"""
        <p>Guten Tag,</p><p>Die Einzahlung für {{teamName}} wurde Ihrem Mannschaftskonto gutgeschrieben.</p><p>Eingezahlt: {{amount}}<br>Stripe-Gebühren: {{fee}}<br>Gutgeschrieben: {{credit}}<br>Bezahlt am: {{paidAt}}<br>Belegnummer: {{invoiceNumber}}<br>Transaktions-ID: {{transaction}}<br>Guthaben vorher: {{balanceBefore}}<br>Guthaben nachher: {{balanceAfter}}</p><p>Den bezahlten Einzahlungsbeleg finden Sie in Ihrer Finanzhistorie.</p><p>{{sandbox}}</p><p>Sportliche Grüße<br>Ihr ÖKFB Team</p>
        """#, variables: ["invoiceNumber", "teamName", "amount", "fee", "credit", "paidAt", "transaction", "balanceBefore", "balanceAfter", "sandbox"]),
    ]
    static func definition(_ key: String) throws -> MailTemplateDefinition {
        guard let value = all.first(where: { $0.key == key }) else { throw Abort(.notFound, reason: "Unbekannte E-Mail-Vorlage.") }
        return value
    }
}
