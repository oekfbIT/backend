//
//  CustomCORSMiddleware.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 05.10.24.
//

import Foundation
import Vapor

public final class CustomCORSMiddleware: Middleware {
    private let allowedOrigins: [String]
    private let allowedMethods: [HTTPMethod]
    private let allowedHeaders: [String]
    private let allowCredentials: Bool

    public init(
        allowedOrigins: [String],
        allowedMethods: [HTTPMethod] = [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [String] = [
            "Authorization",
            "Content-Type",
            "Accept",
            "Origin",
            "X-Requested-With",
            "User-Agent",
            "sec-ch-ua",
            "sec-ch-ua-mobile",
            "sec-ch-ua-platform"
        ],
        allowCredentials: Bool = true
    ) {
        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.allowCredentials = allowCredentials
    }

    public func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        // Handle preflight OPTIONS requests
        if request.method == .OPTIONS {
            return handlePreflight(request: request)
        } else {
            return next.respond(to: request).map { response in
                self.addCORSHeaders(request: request, response: response)
                return response
            }
        }
    }

    private func handlePreflight(request: Request) -> EventLoopFuture<Response> {
        let response = Response(status: .ok)
        addCORSHeaders(request: request, response: response)
        return request.eventLoop.makeSucceededFuture(response)
    }

    private func addCORSHeaders(request: Request, response: Response) {
        guard let origin = request.headers[.origin].first else {
            return
        }

        if isOriginAllowed(origin) {
            response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)

            if allowCredentials {
                response.headers.replaceOrAdd(name: .accessControlAllowCredentials, value: "true")
            }

            let methods = allowedMethods.map { $0.string }.joined(separator: ", ")
            response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: methods)

            let headers = allowedHeaders.joined(separator: ", ")
            response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: headers)
        }
    }

    private func isOriginAllowed(_ origin: String) -> Bool {
        // Remove trailing slash if present
        let trimmedOrigin = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        return allowedOrigins.contains(trimmedOrigin)
    }
}
