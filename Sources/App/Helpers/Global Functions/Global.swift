//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Foundation
import Vapor
import Fluent

func paginate<T: Model>(_ queryBuilder: QueryBuilder<T>, on req: Request, defaultPage: Int = 1, defaultPer: Int = 10) -> QueryBuilder<T> {
    // Extract pagination parameters from query, defaulting to provided defaults
    let page = (try? req.query.get(Int.self, at: "page")) ?? defaultPage
    let per = (try? req.query.get(Int.self, at: "per")) ?? defaultPer
    let start = (page - 1) * per
    let end = start + per
    
    return queryBuilder.range(start..<end)
}
