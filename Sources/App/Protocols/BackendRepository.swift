//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Foundation
import Vapor
import Fluent

protocol DBModelControllerRepository {
    associatedtype T: Model, Content where T.IDValue: LosslessStringConvertible

    var path: String { get }
    // MARK: CRUD - C
    func create(req: Request) throws -> EventLoopFuture<T>
    func createBatch(req: Request) throws -> EventLoopFuture<HTTPStatus>
    
    // MARK: CRUD - R
    func index(req: Request) throws -> EventLoopFuture<Page<T>>
    func getbyID(req: Request) throws  -> EventLoopFuture<T>
    func filter(req: Request, filters: [PartialKeyPath<T>: LosslessStringConvertible]) -> EventLoopFuture<[T]>
    func getbyBatch(req: Request) throws -> EventLoopFuture<[T]>
    func getByFieldValue(req: Request, field: KeyPath<T, T.Field<T.IDValue>>, value: T.IDValue) -> EventLoopFuture<T>
    func paginate(req: Request) throws -> EventLoopFuture<Page<T>>
    func count(req: Request) throws -> EventLoopFuture<Int>

    // MARK: CRUD - U
    func updateID(req: Request) throws  -> EventLoopFuture<T>
    func updateBatch(req: Request) throws -> EventLoopFuture<[T]>
    
    // MARK: CRUD - D
    func deleteID(req: Request) throws -> EventLoopFuture<HTTPStatus>
    func deleteBatch(req: Request) throws -> EventLoopFuture<HTTPStatus>
}
