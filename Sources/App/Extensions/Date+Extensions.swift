import Foundation

extension Date {
    static var viennaNow: Date {
        let now = Date()
        let viennaTimeZone = TimeZone(identifier: "Europe/Vienna")!
        let secondsFromGMT = viennaTimeZone.secondsFromGMT(for: now)
        return Date(timeIntervalSince1970: now.timeIntervalSince1970 + TimeInterval(secondsFromGMT))
    }
}
