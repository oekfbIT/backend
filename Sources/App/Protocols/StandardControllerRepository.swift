//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
import Foundation
import Vapor
import Fluent

/// A generic repository for standard CRUD operations on a model conforming to `Model`, `Content`, and `Mergeable`.
class StandardControllerRepository<T: Model & Content & Mergeable>: DBModelControllerRepository where T.IDValue: LosslessStringConvertible {
    
    /// The path to the model, e.g. "localhost:8080/api/users".
    var path: String
    
    init(path: String) {
        self.path = path
    }
    
    /// Creates a new item of type `T`.
    ///
    /// Example: POST "localhost:8080/api/users"
    func create(req: Request) throws -> EventLoopFuture<T> {
        let item = try req.content.decode(T.self)
        return item.create(on: req.db).map { item }
    }
    
    /// Returns paginated items of type `T`.
    ///
    /// Example: GET "localhost:8080/api/users?page=1&perPage=20"
    func index(req: Request) throws -> EventLoopFuture<Page<T>> {
        return T.query(on: req.db).paginate(for: req)
    }

    /// Returns an item of type `T` by its ID.
    ///
    /// Example: GET "localhost:8080/api/users/1"
    func getbyID(req: Request) throws -> EventLoopFuture<T> {
        guard let id = req.parameters.get("id", as: T.IDValue.self) else {
            throw Abort(.badRequest)
        }
        return T.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
    }
    
    /// Returns multiple items of type `T` by their IDs.
    ///
    /// Example: POST "localhost:8080/api/users/batch" with JSON body {"ids": [1, 2, 3]}
    func getbyBatch(req: Request) throws -> EventLoopFuture<[T]> {
        let ids = try req.content.decode([T.IDValue].self)
        return T.query(on: req.db).filter(\._$id ~~ ids).all()
    }
    
    /// Deletes an item of type `T` by its ID.
    ///
    /// Example: DELETE "localhost:8080/api/users/1"
    func deleteID(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let id = req.parameters.get("id", as: T.IDValue.self) else {
            throw Abort(.badRequest)
        }
        return T.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { item in
                item.delete(on: req.db)
                    .transform(to: .noContent)
            }
    }
    
    /// Deletes multiple items of type `T` by their IDs.
    ///
    /// Example: DELETE "localhost:8080/api/users/batch" with JSON body {"ids": [1, 2, 3]}
    func deleteBatch(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        // Decode the array of IDs from the request body.
        let ids = try req.content.decode([T.IDValue].self)
        
        // Create an array of futures that delete each item by its ID.
        let futures = ids.map { id -> EventLoopFuture<Void> in
            // Try to find the item by its ID and delete it if it exists.
            return T.find(id, on: req.db).flatMap { item in
                guard let item = item else {
                    // If the item does not exist, return a successful future.
                    return req.eventLoop.makeSucceededFuture(())
                }
                return item.delete(on: req.db)
            }
        }
        
        // Wait for all futures to complete and return a `204 No Content` status code.
        return EventLoopFuture.whenAllSucceed(futures, on: req.eventLoop).transform(to: .noContent)
    }

    /// Updates an item of type `T` by its ID.
    ///
    /// Example: PATCH "localhost:8080/api/users/1" with JSON body {"name": "John"}
    func updateID(req: Request) throws -> EventLoopFuture<T> {
        
        guard let id = req.parameters.get("id", as: T.IDValue.self) else {
            throw Abort(.badRequest)
        }
        
        let updatedItem = try req.content.decode(T.self)
        
        return T.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { item in
                let mergedItem = item.merge(from: updatedItem)
                return mergedItem.update(on: req.db).map { mergedItem }
            }
    }
    
    /// Updates multiple items of type T.
    ///
    /// Example: PATCH "localhost:8080/api/users/batch" with JSON body [{"id": 1, "name": "John"}, {"id": 2, "name": "Jane"}]
    func updateBatch(req: Request) throws -> EventLoopFuture<[T]> {
        let updatedItems = try req.content.decode([T].self)
        
        let updateFutures = updatedItems.map { updatedItem -> EventLoopFuture<T> in
            guard let id = updatedItem.id else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest))
            }
            
            return T.find(id, on: req.db)
                .unwrap(or: Abort(.notFound))
                .flatMap { item in
                    let mergedItem = item.merge(from: updatedItem)
                    return mergedItem.update(on: req.db).map { mergedItem }
                }
        }
        
        return EventLoopFuture.whenAllSucceed(updateFutures, on: req.eventLoop)
    }
    
    /// Paginates items of type `T`.
    ///
    /// Example: GET "localhost:8080/api/users?page=1&perPage=20&sortField=name&sortDirection=asc"
    func paginate(req: Request) throws -> EventLoopFuture<Page<T>> {
        let pageRequest = try req.query.decode(PageRequest.self)
        return T.query(on: req.db).paginate(for: req)
    }
    
    /// Counts items of type `T`.
    ///
    /// Example: GET "localhost:8080/api/users/count"
    func count(req: Request) throws -> EventLoopFuture<Int> {
        return T.query(on: req.db).count()
    }
    
    /// Filters items of type `T` by a given field and value.
    ///
    /// Example: GET "localhost:8080/api/users/filter?id=1"
    func filter(req: Request, filters: [PartialKeyPath<T>: LosslessStringConvertible]) -> EventLoopFuture<[T]> {
        var queryBuilder = T.query(on: req.db)
        for (field, value) in filters {
            guard let field = field as? KeyPath<T, T.Field<T.IDValue>> else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid filter field"))
            }
            guard let fieldValue = T.IDValue(value.description) else {
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Invalid filter value"))
            }
            queryBuilder = queryBuilder.filter(field == fieldValue)
        }
        return queryBuilder.all()
    }

    /// Gets an item of type `T` by a given field and value.
    ///
    /// Example: GET "localhost:8080/api/users/find?id=1"
    func getByFieldValue(req: Request, field: KeyPath<T, T.Field<T.IDValue>>, value: T.IDValue) -> EventLoopFuture<T> {
        return T.query(on: req.db).filter(field == value).first().unwrap(or: Abort(.notFound))
    }
    
    /// Creates multiple items of type `T`.
    ///
    /// Example: POST "localhost:8080/api/users/bulk" with JSON body [{"name": "John"}, {"name": "Jane"}]
    func createBatch(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        let items = try req.content.decode([T].self)
        //        TO RETURN THE SAVED ITEMS WITH ID
        //        return items.create(on: req.db).map { items }
        return items.create(on: req.db).transform(to: .created)
    }
}

/// A protocol for merging two instances of the same type.
protocol Mergeable {
    func merge(from: Self) -> Self
}
