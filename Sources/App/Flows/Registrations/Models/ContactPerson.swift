// ContactPerson.swift

import Foundation

struct ContactPerson: Codable, LosslessStringConvertible {
    var first, last, phone, email: String
    var identification: String?

    // ✅ Add this initializer
    init(first: String, last: String, phone: String, email: String, identification: String?) {
        self.first = first
        self.last = last
        self.phone = phone
        self.email = email
        self.identification = identification
    }

    init?(_ description: String) {
        guard let data = description.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ContactPerson.self, from: data) else {
            return nil
        }
        self = decoded
    }

    var description: String {
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}

// ✅ convenience helper
extension ContactPerson {
    func withIdentification(_ url: String) -> ContactPerson {
        ContactPerson(
            first: first,
            last: last,
            phone: phone,
            email: email,
            identification: url
        )
    }
}
