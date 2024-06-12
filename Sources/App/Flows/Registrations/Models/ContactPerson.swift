//
//  File.swift
//  
//
//  Created by Alon Yakoby on 19.05.24.
//

import Foundation

struct ContactPerson: Codable, LosslessStringConvertible {
    let first, last, phone, email: String
    
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
