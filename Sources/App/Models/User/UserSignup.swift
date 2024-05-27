//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Vapor
import Fluent

struct UserSignup: Content {
    public let id: String
    public let firstName: String
    public let lastName: String
    public let email: String
    public let password: String
    public let type: UserType
    
    init(id: String, firstName: String, lastName: String, email: String, password: String, type: UserType) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.password = password
        self.type = type
    }
}

struct NewSession: Content {
    let token: String
    let user: User.Public
}
