

import Vapor
import Fluent
import SwiftSoup

var public_leagueID: UUID?

final class ScraperDetailController: RouteCollection {
    let baseUrl = "https://oekfb.com/"
    
    func boot(routes: RoutesBuilder) throws {
        let scraperRoutes = routes.grouped("scrape")
        scraperRoutes.get("player", ":id", use: scrapePlayer)
        scraperRoutes.get("league", ":id", use: scrapeLeagueDetails)
        scraperRoutes.get("team", ":id", "league", ":leagueID", use: scrapeTeam)
    }
    
    /*  func scrapeLeagueDetails(req: Request) throws -> EventLoopFuture<League> {
        guard let id = req.parameters.get("id", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }
        
        let url = "https://oekfb.com/?action=mannschaften&liga=\(id)"
        return req.client.get(URI(string: url)).flatMapThrowing { response in
            guard let body = response.body else { throw Abort(.badRequest, reason: "No response body") }
            let html = String(buffer: body)
            
            let doc: Document = try SwiftSoup.parse(html)
            
            // Extract the league name
            let leagueNameElement: Element = try doc.select("div.MainFrameTopic").first()!
            let leagueName = try leagueNameElement.text()
            
            // Extract team links
            let teamElements: Elements = try doc.select("div.stat_name a[href^=\"?action=showTeam&data=\"]")
            
            var teamLinks: [String] = []
            for team in teamElements {
                let link = try team.attr("href")
                teamLinks.append("https://oekfb.com/\(link)")
            }
            
            // Construct the League object
            let league = League(
                state: .auszuwerten,
                code: String(id),
                name: leagueName
            )
            
            // Print each team link on a new line
            print("Extracted team links:")
            for link in teamLinks {
                print(link)
            }
            
            return league
            
            // TODO: Save the league, pass the teams to team scraper,
        }
    } */
    
    func scrapeLeagueDetails(req: Request) throws -> EventLoopFuture<League> {
        guard let id = req.parameters.get("id", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }
        
        let url = "https://oekfb.com/?action=mannschaften&liga=\(id)"
        return req.client.get(URI(string: url)).flatMapThrowing { response -> (League, [String]) in
            guard let body = response.body else { throw Abort(.badRequest, reason: "No response body") }
            let html = String(buffer: body)
            
            let doc: Document = try SwiftSoup.parse(html)
            
            // Extract the league name
            let leagueNameElement: Element = try doc.select("div.MainFrameTopic").first()!
            let leagueName = try leagueNameElement.text()
            
            // Extract team links
            let teamElements: Elements = try doc.select("div.stat_name a[href^=\"?action=showTeam&data=\"]")
            
            var teamLinks: [String] = []
            for team in teamElements {
                let link = try team.attr("href")
                teamLinks.append("https://oekfb.com/\(link)")
            }
            
            // Construct the League object
            let league = League(
                state: .auszuwerten,
                teamcount: 14,
                code: String(id),
                name: leagueName
            )
            
            print("Extracted team links:")
            for link in teamLinks {
                print(link)
            }
            
            return (league, teamLinks)
        }.flatMap { (league, teamLinks) in
            // Save the league to the database
            return league.save(on: req.db).map { (league, teamLinks) }
        }.flatMap { (league, teamLinks) in
            // Run team scraping tasks in the background
            if let leagueID = league.id {
                public_leagueID = leagueID
                req.eventLoop.execute {
                    teamLinks.forEach { link in
                        let text = link.replacingOccurrences(of: "?action=showTeam&data=", with: "")
                        print(text)
                        do {
                            try self.scrapeTeam(req: req).whenComplete { result in
                                switch result {
                                case .success:
                                    print("Team \(text) saved successfully")
                                case .failure(let error):
                                    print("Error saving team \(text): \(error)")
                                }
                            }
                        } catch {
                            print("Error initiating team scrape for \(text): \(error)")
                        }
                    }
                }
            }
            return req.eventLoop.makeSucceededFuture(league)
        }
    }

    func scrapePlayer(req: Request) throws -> EventLoopFuture<Player> {
        guard let id = req.parameters.get("id", as: Int.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player ID")
        }
        
        let url = "https://oekfb.com/index.php?action=showPlayer&id=\(id)"
        return req.client.get(URI(string: url)).flatMapThrowing { response in
            guard let body = response.body else {
                throw Abort(.badRequest, reason: "No response body")
            }
            
            let html = String(buffer: body)
            let doc = try SwiftSoup.parse(html)
            
            let sid = String(id)
            let name = try doc.select("font.megaLargeWhite").first()?.text()
            let number = try doc.select("font:contains(Rückennummer:)").first()?.nextElementSibling()?.text()
            let birthday = try doc.select("font:contains(Jahrgang:)").first()?.nextElementSibling()?.text()
            let nationality = try doc.select("font:contains(Nationalität:)").first()?.nextElementSibling()?.text()
            let eligibilityText = try doc.select("td font.megaLargeGreen:contains(Spielberechtigt)").first()?.text()
            let registerDate = try doc.select("font:contains(Angemeldet seit:)").first()?.nextElementSibling()?.text()
            let teamOeidHref = try doc.select("font:contains(Mannschaft:)").first()?.nextElementSibling()?.select("a").attr("href")
            let teamOeid = teamOeidHref?.split(separator: "=").last.map(String.init)
            let imageUrl = try doc.select("img[src*=images/player]").first()?.attr("src")

            // Print statements for debugging
            print("SID: \(String(describing: sid))")
            print("Name: \(String(describing: name))")
            print("Number: \(String(describing: number))")
            print("Birthday: \(String(describing: birthday))")
            print("Nationality: \(String(describing: nationality))")
            print("Eligibility: \(String(describing: eligibilityText))")
            print("Register Date: \(String(describing: registerDate))")
            print("Team OEID: \(String(describing: teamOeid))")
            print("Image URL: \(String(describing: imageUrl))")
            
            guard
                let name = name,
                let number = number,
                let birthday = birthday,
                let nationality = nationality,
                let eligibilityText = eligibilityText,
                let registerDate = registerDate,
                let teamOeid = teamOeid
            else {
                throw Abort(.badRequest, reason: "Failed to parse player data")
            }
            
            let eligibility = PlayerEligibility(rawValue: eligibilityText) ?? .Gesperrt
            
            return Player(
                sid: sid,
                image: self.baseUrl + (imageUrl ?? ""),
                team_oeid: teamOeid,
                name: name,
                number: number,
                birthday: birthday,
                teamID: UUID(), // Placeholder for the team ID, you'll need to fetch or determine this based on your data
                nationality: nationality,
                position: "field", // Assuming 'field' as the default position, adjust as necessary
                eligibility: eligibility,
                registerDate: registerDate, identification: nil, status: true
            )
        }
    }
    
    func scrapePlayer(req: Request, id: Int, teamId: UUID) throws -> EventLoopFuture<Player> {
//        guard let id = req.parameters.get("id", as: Int.self) else {
//            throw Abort(.badRequest, reason: "Missing or invalid player ID")
//        }
        print("Fetching:  \(id)")
        let url = "https://oekfb.com/index.php?action=showPlayer&id=\(id)"
        print("starting \(url)")
        return req.client.get(URI(string: url)).flatMapThrowing { response in
            guard let body = response.body else {
                throw Abort(.badRequest, reason: "No response body")
            }
            
            let html = String(buffer: body)
            let doc = try SwiftSoup.parse(html)
            
            let sid = String(id)
            let name = try doc.select("font.megaLargeWhite").first()?.text()
            let number = try doc.select("font:contains(Rückennummer:)").first()?.nextElementSibling()?.text()
            let birthday = try doc.select("font:contains(Jahrgang:)").first()?.nextElementSibling()?.text()
            let nationality = try doc.select("font:contains(Nationalität:)").first()?.nextElementSibling()?.text()
            let eligibilityText = try doc.select("td font.megaLargeGreen:contains(Spielberechtigt)").first()?.text()
            let registerDate = try doc.select("font:contains(Angemeldet seit:)").first()?.nextElementSibling()?.text()
            let teamOeidHref = try doc.select("font:contains(Mannschaft:)").first()?.nextElementSibling()?.select("a").attr("href")
            let teamOeid = teamOeidHref?.split(separator: "=").last.map(String.init)
            let imageUrl = try doc.select("img[src*=images/player]").first()?.attr("src")
            // https://www.oekfb.com/images/player-png/14191.png
            // https://www.oekfb.com/images/player/14201.jpg

            // Print statements for debugging
            print("SID: \(String(describing: sid))")
            print("Name: \(String(describing: name))")
            print("Number: \(String(describing: number))")
            print("Birthday: \(String(describing: birthday))")
            print("Nationality: \(String(describing: nationality))")
            print("Eligibility: \(String(describing: eligibilityText))")
            print("Register Date: \(String(describing: registerDate))")
            print("Team OEID: \(String(describing: teamOeid))")
            print("Image URL: \(String(describing: imageUrl))")
            
//            guard
//                let name = name,
//                let number = number,
//                let birthday = birthday,
//                let nationality = nationality,
//                let eligibilityText = eligibilityText,
//                let registerDate = registerDate,
//                let teamOeid = teamOeid
//            else {
//                throw Abort(.badRequest, reason: "Failed to parse player data")
//            }
            
            let eligibility = PlayerEligibility(rawValue: eligibilityText ?? "Gesperrt") ?? .Gesperrt
            
            
            let player = Player(
                sid: sid,
                image: self.baseUrl + (imageUrl ?? ""),
                team_oeid: teamOeid ?? "N/A",
                name: name ?? "N/A",
                number: number  ?? "N/A",
                birthday: birthday  ?? "N/A",
                teamID: teamId, // Placeholder for the team ID, you'll need to fetch or determine this based on your data
                nationality: nationality  ?? "N/A",
                position: "field", // Assuming 'field' as the default position, adjust as necessary
                eligibility: eligibility,
                registerDate: registerDate  ?? "N/A",
                identification: nil,
                status: true
            )
            
            player.save(on: req.db).flatMapThrowing {
                player
                print("Saved:", player)
            }
            return player
        }
    }
    
    func scrapeTeam(req: Request) throws -> EventLoopFuture<Team> {
        guard let id = req.parameters.get("id", as: Int.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID")
        }

        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }

        let url = "https://oekfb.com/?action=showTeam&data=\(id)"
        return req.client.get(URI(string: url)).flatMapThrowing { response -> (Team, [String], String, String) in
            guard let body = response.body else { throw Abort(.badRequest, reason: "No response body") }
            let html = String(buffer: body)

            let doc: Document = try SwiftSoup.parse(html)

            // Extract team details
            let teamName = try doc.select("div.MainFrameTopic").first()?.text() ?? "Unknown Team"
            let captainImageURL = try doc.select("table:contains(Kapitän) img").first()?.attr("src") ?? "Unknown Captain"
            let coachImageURL = try doc.select("table:contains(Trainer) img").first()?.attr("src") ?? "Unknown Coach"
            let coachName = try doc.select("table:contains(Trainer) div font.largeWhite").first()?.text() ?? "Unknown Coach"
            let coach = Trainer(name: coachName, imageURL: self.baseUrl + coachImageURL)
            let leagueName = try doc.select("div.MainFrameTopicDown").first()?.text() ?? "Unknown League"
            let coverImg = try doc.select("div.cutedImage img").first()?.attr("src") ?? "https://oekfb.com/images/mannschaften/0.jpg"
            let logo = try doc.select("table[width='594'] img").first()?.attr("src") ?? "Nothing found"
            let foundationYear = (try doc.select("font:contains(Gründungsjahr:)").first()?.text() ?? "Unknown").replacingOccurrences(of: "Gründungsjahr: ", with: "")
            let membershipSince = (try doc.select("font:contains(Im Verband seit:)").first()?.text() ?? "Unknown").replacingOccurrences(of: "Im Verband seit: ", with: "")
            let averageAge = (try doc.select("font:contains(Altersdurchschn.:)").first()?.text() ?? "Unknown").replacingOccurrences(of: "Altersdurchschn.: ", with: "")
            let playerLinks: [String] = try doc.select("a[href^='?action=showPlayer']").map { try $0.attr("href") }.unique()
            let jerseyImages = try doc.select("img[src^='images/png/TR/']").map { try $0.attr("src") }
            let trikotHome = jerseyImages.first ?? "Unknown Home Jersey"
            let trikotAway = jerseyImages.last ?? "Unknown Away Jersey"
            let trikot = Trikot(home: self.baseUrl + trikotHome, away: self.baseUrl + trikotAway)

            let randomemail =  String.randomString(length: 6) + "@oekfb.eu"
            let randompass =  String.randomString(length: 8)

            let team = Team(sid: String(id),
                            userId: nil, // This will be set after user creation
                            leagueId: leagueID,
                            leagueCode: leagueName,
                            points: 0,
                            coverimg: self.baseUrl + coverImg,
                            logo: logo,
                            teamName: teamName,
                            foundationYear: foundationYear,
                            membershipSince: membershipSince,
                            averageAge: averageAge,
                            coach: coach,
                            captain: self.baseUrl + captainImageURL,
                            trikot: trikot,
                            balance: 0.0,
                            referCode: String.randomString(length: 6),
                            usremail: randomemail,
                            usrpass: randompass, usrtel: ""
            )
            
            return (team, playerLinks, randomemail, randompass)
        }.flatMap { (team, playerLinks, email, password) in
            // Create user for the team
            return self.createUser(req: req, email: email, password: password).map { user in
                team.$user.id = user.id
                team.usrpass = password
                
                return (team, playerLinks)
            }
        }.flatMap { (team, playerLinks) in
            // Save the team to the database
            return team.save(on: req.db).map { (team, playerLinks) }
        }.flatMap { (team, playerLinks) in
            // Run player scraping tasks in the background
            if let teamID = team.id {
                req.eventLoop.execute {
                    playerLinks.forEach { link in
                        let text = link.replacingOccurrences(of: "?action=showPlayer&id=", with: "")
                        do {
                            try self.scrapePlayer(req: req, id: Int(text) ?? 0, teamId: teamID).whenComplete { result in
                                switch result {
                                case .success:
                                    print("Player \(text) saved successfully")
                                case .failure(let error):
                                    print("Error saving player \(text): \(error)")
                                }
                            }
                        } catch {
                            print("Error initiating player scrape for \(text): \(error)")
                        }
                    }
                }
            }
            return req.eventLoop.makeSucceededFuture(team)
        }
    }

    private func createUser(req: Request, email: String, password: String) -> EventLoopFuture<User> {
        let userSignup = UserSignup(id: UUID().uuidString,
                                    firstName: "Team",
                                    lastName: "User",
                                    email: email,
                                    password: password,
                                    type: .team)
        let user: User
        do {
            user = try User.create(from: userSignup)
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
        
        return user.save(on: req.db).map { user }
    }
}

extension Array where Element == String {
    /// Returns an array with unique strings by preserving the order of the first occurrence.
    func unique() -> [String] {
        var seen: Set<String> = []
        return self.filter { element in
            guard !seen.contains(element) else {
                return false
            }
            seen.insert(element)
            return true
        }
    }
}
