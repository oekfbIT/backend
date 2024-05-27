//
//  File.swift
//  
//
//  Created by Alon Yakoby on 19.05.24.
//

import Foundation
import Fluent
import Vapor

protocol RegistrationProtocol {
    func publicSignUp(req: Request) throws -> EventLoopFuture<Player>
}
