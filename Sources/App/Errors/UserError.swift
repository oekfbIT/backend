//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Foundation
import Vapor

enum UserError: AbortError {
    case emailTaken
        
    var description: String {
        reason
    }
    
    var status: HTTPResponseStatus {
        switch self {
            case .emailTaken: return .conflict
        }
    }
    
    var reason: String {
        switch self {
            case .emailTaken: return "User with this email already exists."
        }
    }
}
