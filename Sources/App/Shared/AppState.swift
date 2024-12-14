//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Foundation

enum ENV {
    case databaseURL
    case jwtSecret
    
    var key: String {
        switch self {
        case .databaseURL:
            return "DATABASE_URL"
        case .jwtSecret:
            return "JWT_Secret"
        }
    }
    
    var dev_default: String {
        switch self {
        case .databaseURL:
            return "mongodb://localhost:27017/oekfb_database"
        case .jwtSecret:
            return "3Cz30pJzxbqYvLjXqTJjU8VpU5bxvgoNRvq1a"
        }
    }

    var prod_default: String {
        switch self {
        case .databaseURL:
            return "mongodb://localhost:27017/oekfb_database"
        case .jwtSecret:
            return "3Cz30pJzxbqYvLjXqTJjU8VpU5bxvgoNRvq1a"
        }
    }

}
