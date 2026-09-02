import Foundation
import Fluent
import Vapor

enum LegalDocumentType: String, Codable, CaseIterable {
    case regeln
    case ligaordnung
    case bund
    case kontakt
    case impressum
    case privacy

    var usesParagraphNumbers: Bool {
        self == .regeln || self == .ligaordnung
    }

    var isSinglePage: Bool {
        self == .kontakt || self == .impressum || self == .privacy
    }
}

/// Seeds the three existing public information pages as one editable record
/// each. Existing admin content is never overwritten.
struct StaticPageContentSeedMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.eventLoop.makeFutureWithTask {
            let pages: [(LegalDocumentType, String, String)] = [
            (
                .kontakt,
                "Kontakt",
                """
                Bitte mailen Sie uns Ihre Fragen und Anregungen über das untenstehende Formular. Tragen Sie Ihr Anliegen zusammen mit Ihrem Namen, Ihrer E-Mail-Adresse und dem Betreff ein, damit wir Ihnen schnellstmöglich eine Rückmeldung geben können.

                Sie erreichen uns per Post bei:
                1020 Wien, Pazmanitengasse 15/7

                Sie erreichen uns telefonisch (Mo - Fr - 10:00 bis 17:00) unter:
                +43 665 6700 9191

                Oder per Mail unter:
                office@oekfb.eu
                support@oekfb.eu
                strafsenat@oekfb.eu
                """
            ),
            (
                .impressum,
                "Impressum",
                """
                Vereinsname:
                ÖSTERREICHISCHER KLEINFELD FUSSBALL BUND

                Rechtsform:
                Eingetragener Verein

                IBAN:
                AT26 2011 1829 7052 4200

                Sitz:
                1020 Wien, Pazmanitengasse 15/7

                Kontakt:
                Tel: +43 665 6700 9191 (Mo – Fr, 10:00 – 17:00)
                E-Mail: office@oekfb.eu, support@oekfb.eu, strafsenat@oekfb.eu

                ZVR-Nummer:
                046132504

                Vorstand:
                Avi Ben-Or (Obmann)

                Mitgliedschaften:
                Mitglied der WKÖ

                Zuständige Aufsichtsbehörde:
                Landespolizeidirektion Wien, Referat Vereins-, Versammlungs- und Medienrechtsangelegenheiten
                """
            ),
            (
                .privacy,
                "Datenschutzerklärung",
                """
                Der Schutz Ihrer personenbezogenen Daten ist uns ein besonderes Anliegen. Wir verarbeiten Ihre Daten ausschließlich auf Grundlage der gesetzlichen Bestimmungen (DSGVO, DSG, TKG 2003).

                Diese Datenschutzerklärung informiert Sie über Art, Umfang und Zweck der Verarbeitung personenbezogener Daten im Rahmen unserer Website und unserer Tätigkeiten als Fußballverband.

                1. Verantwortlicher
                ÖSTERREICHISCHER KLEINFELD FUSSBALL BUND (Eingetragener Verein)
                ZVR-Nummer: 046132504
                Sitz: 1020 Wien, Pazmanitengasse 15/7
                Kontakt: Tel: +43 665 6700 9191 (Mo – Fr, 10:00 – 17:00)
                E-Mail: office@oekfb.eu, support@oekfb.eu, strafsenat@oekfb.eu
                Vertreten durch: Avi Ben-Or (Obmann)

                2. Verarbeitung personenbezogener Daten
                Wir verarbeiten personenbezogene Daten von Spielern, Trainern, Schiedsrichtern, Vereinsverantwortlichen und Funktionären, soweit dies für die Organisation und Durchführung des Spielbetriebs erforderlich ist.

                Verarbeitete Daten können insbesondere sein:
                • Vor- und Nachname
                • Geburtsdatum / Alter
                • Mannschafts- und Vereinszugehörigkeit
                • Spieler- oder Lizenznummer
                • Position, Einsatzdaten, Statistiken
                • Kontaktdaten (z. B. E-Mail, Telefonnummer – sofern erforderlich)
                • Bilder und Videos (z. B. Spielerfotos, Mannschaftsfotos, Spielaufnahmen)

                3. Zweck der Datenverarbeitung
                Die Verarbeitung erfolgt zu folgenden Zwecken:
                • Organisation, Durchführung und Verwaltung des Ligabetriebs
                • Spielerregistrierung und Spielberechtigung
                • Veröffentlichung von Spieler- und Mannschaftsinformationen
                • Darstellung von Spielergebnissen, Tabellen und Statistiken
                • Öffentlichkeitsarbeit und Berichterstattung über Spiele und Veranstaltungen
                • Einhaltung gesetzlicher und verbandsinterner Verpflichtungen

                4. Verarbeitung von Bildern und Videos
                Im Rahmen von Spielen, Turnieren und Veranstaltungen können Fotos und Videoaufnahmen angefertigt werden, auf denen Spieler und Beteiligte erkennbar sind. Diese Aufnahmen können auf unseren Websites, in sozialen Medien sowie in Spielberichten, Tabellen oder Vereinsdarstellungen veröffentlicht werden.

                Rechtsgrundlage:
                • Art. 6 Abs. 1 lit. b DSGVO (Vertrag / Teilnahme am Spielbetrieb)
                • Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an Öffentlichkeitsarbeit und Dokumentation des Spielbetriebs)
                Sofern gesetzlich erforderlich, erfolgt die Verarbeitung auf Basis einer Einwilligung (Art. 6 Abs. 1 lit. a DSGVO).

                5. Weitergabe von Daten
                Personenbezogene Daten werden nicht verkauft. Eine Weitergabe erfolgt nur, wenn dies erforderlich ist (z. B. an Verbandsorgane, Schiedsrichter oder Ligaverantwortliche, an technische Dienstleister wie Hosting/IT-Systeme oder zur Erfüllung gesetzlicher Verpflichtungen). Auftragsverarbeiter sind gemäß Art. 28 DSGVO vertraglich verpflichtet.

                6. Speicherdauer
                Personenbezogene Daten werden nur so lange gespeichert, wie dies für die jeweiligen Zwecke erforderlich ist oder gesetzliche Aufbewahrungspflichten bestehen. Spiel- und Statistikdaten können aus sporthistorischen Gründen länger gespeichert bleiben.

                7. Cookies und Server-Logs
                Unsere Website kann Cookies verwenden, um grundlegende Funktionen sicherzustellen. Beim Besuch der Website werden automatisch Daten (z. B. IP-Adresse, Browsertyp, Betriebssystem, Datum und Uhrzeit des Zugriffs) erhoben. Diese Daten dienen der technischen Sicherheit und Optimierung der Website.

                8. Ihre Rechte
                Sie haben jederzeit das Recht auf Auskunft, Berichtigung, Löschung (sofern keine gesetzlichen Pflichten entgegenstehen), Einschränkung der Verarbeitung, Datenübertragbarkeit sowie Widerspruch gegen die Verarbeitung.

                Anfragen richten Sie bitte an:
                office@oekfb.eu

                9. Beschwerderecht
                Wenn Sie der Ansicht sind, dass die Verarbeitung Ihrer Daten gegen Datenschutzrecht verstößt, haben Sie das Recht, Beschwerde bei der zuständigen Aufsichtsbehörde einzulegen:

                Österreichische Datenschutzbehörde
                Barichgasse 40–42
                1030 Wien
                www.dsb.gv.at

                10. Änderungen dieser Datenschutzerklärung
                Wir behalten uns vor, diese Datenschutzerklärung bei Bedarf anzupassen, um sie an rechtliche oder technische Änderungen anzupassen. Die jeweils aktuelle Version ist auf unserer Website abrufbar.
                """
            )
            ]

            for (documentType, heading, content) in pages {
                let existing = try await LegalSection.query(on: database)
                    .filter(\.$documentType == documentType)
                    .first()
                guard existing == nil else { continue }

                try await LegalSection(
                    documentType: documentType,
                    heading: heading,
                    content: content,
                    position: 1
                ).create(on: database)
            }
        }
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        // Seeded legal content may have been edited by an administrator and is
        // therefore intentionally retained when reverting the migration.
        database.eventLoop.makeSucceededFuture(())
    }
}

final class LegalSection: Model, Content {
    static let schema = "legal_sections"

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var documentType: FieldKey { "document_type" }
        static var heading: FieldKey { "heading" }
        static var content: FieldKey { "content" }
        static var position: FieldKey { "position" }
        static var createdAt: FieldKey { "created_at" }
        static var updatedAt: FieldKey { "updated_at" }
    }

    @ID(custom: FieldKeys.id)
    var id: UUID?

    @Enum(key: FieldKeys.documentType)
    var documentType: LegalDocumentType

    @Field(key: FieldKeys.heading)
    var heading: String

    @Field(key: FieldKeys.content)
    var content: String

    @Field(key: FieldKeys.position)
    var position: Int

    @Timestamp(key: FieldKeys.createdAt, on: .create)
    var createdAt: Date?

    @Timestamp(key: FieldKeys.updatedAt, on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        documentType: LegalDocumentType,
        heading: String,
        content: String,
        position: Int
    ) {
        self.id = id
        self.documentType = documentType
        self.heading = heading
        self.content = content
        self.position = position
    }
}

struct LegalSectionMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(LegalSection.schema)
            .field(LegalSection.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(LegalSection.FieldKeys.documentType, .string, .required)
            .field(LegalSection.FieldKeys.heading, .string, .required)
            .field(LegalSection.FieldKeys.content, .string, .required)
            .field(LegalSection.FieldKeys.position, .int, .required)
            .field(LegalSection.FieldKeys.createdAt, .datetime)
            .field(LegalSection.FieldKeys.updatedAt, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(LegalSection.schema).delete()
    }
}
