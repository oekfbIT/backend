
import Foundation
import Combine
import SwiftSoup

class APIClient {
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    func getHTMLDocument(from url: URL) -> AnyPublisher<Document, Error> {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://www.google.com", forHTTPHeaderField: "Referer")
        
        return session.dataTaskPublisher(for: request)
            .map { $0.data }
            .tryMap { data in
                guard let htmlString = String(data: data, encoding: .utf8) else {
                    throw URLError(.badServerResponse)
                }
                return try SwiftSoup.parse(htmlString)
            }
            .eraseToAnyPublisher()
    }
}
