//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Foundation

extension String {
    func toUUID() -> UUID? {
        return UUID(uuidString: self)
    }
}
