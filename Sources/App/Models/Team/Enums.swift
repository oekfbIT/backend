//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Vapor
import Fluent
// Enums
enum MatchEventType: String, Codable {
    case goal
    case redCard
    case yellowCard
    case freeKick
    case penalty
}


enum Bundesland: String, Codable, LosslessStringConvertible {
    case wien
    case niederoesterreich
    case oberoesterreich
    case steiermark
    case kaernten
    case salzburg
    case tirol
    case vorarlberg
    case burgenland
    case ausgetreten
    case auszuwerten
    
    var name: String {
        switch self {
        case .wien: return "Wien"
        case .niederoesterreich: return "Niederösterreich"
        case .oberoesterreich: return "Oberösterreich"
        case .steiermark: return "Steiermark"
        case .kaernten: return "Kärnten"
        case .salzburg: return "Salzburg"
        case .tirol: return "Tirol"
        case .vorarlberg: return "Vorarlberg"
        case .burgenland: return "Burgenland"
        case .ausgetreten: return "Ausgetreten"
        case .auszuwerten: return "Auszuwerten"
        }
    }
    
    init?(_ description: String) {
        self.init(rawValue: description)
    }
    
    var description: String {
        return self.rawValue
    }
}

enum TrikotColor: String, Codable {
    case light, dark, red, green, blue, pink, yellow, white, black 
}
