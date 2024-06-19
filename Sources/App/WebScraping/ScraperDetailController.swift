

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
            let imageUrl = try doc.select("img[src*=images/player/]").first()?.attr("src")

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
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }

        guard let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }

        let url = "https://oekfb.com/?action=showTeam&data=\(id)"
        return req.client.get(URI(string: url)).flatMapThrowing { response -> (Team, [String]) in
            guard let body = response.body else { throw Abort(.badRequest, reason: "No response body") }
            let html = String(buffer: body)

            let doc: Document = try SwiftSoup.parse(html)

            // Extract team name
            let teamName = try doc.select("div.MainFrameTopic").first()?.text() ?? "Unknown Team"
            print("Extracted team name: \(teamName)")

            // Extract captain image URL
            let captainImageURL = try doc.select("table:contains(Kapitän) img").first()?.attr("src") ?? "Unknown Captain"
            print("Extracted Captain image URL: \(captainImageURL)")

            // Extract coach name and image URL
            let coachImageURL = try doc.select("table:contains(Trainer) img").first()?.attr("src") ?? "Unknown Coach"
            let coachName = try doc.select("table:contains(Trainer) div font.largeWhite").first()?.text() ?? "Unknown Coach"
            let coach = Trainer(name: coachName, imageURL: self.baseUrl + coachImageURL)
            print("Extracted Coach name: \(coachName), image URL: \(coachImageURL)")

            // Extract league name
            let leagueName = try doc.select("div.MainFrameTopicDown").first()?.text() ?? "Unknown League"
            print("Extracted league name: \(leagueName)")

            // Extract cover image
            let coverImg = try doc.select("div.cutedImage img").first()?.attr("src") ?? "https://oekfb.com/images/mannschaften/0.jpg"
            print("Extracted cover image: \(coverImg)")

            // Extract logo
            let logo = try doc.select("table[width='594'] img").first()?.attr("src") ?? "Nothing found"
            print("Extracted logo: \(logo)")

            // Extract foundation year and membership since
            let foundationYearText = try doc.select("font:contains(Gründungsjahr:)").first()?.text() ?? "Unknown"
            let foundationYear = foundationYearText.replacingOccurrences(of: "Gründungsjahr: ", with: "")
            print("Extracted foundation year: \(foundationYear)")

            let membershipSinceText = try doc.select("font:contains(Im Verband seit:)").first()?.text() ?? "Unknown"
            let membershipSince = membershipSinceText.replacingOccurrences(of: "Im Verband seit: ", with: "")
            print("Extracted membership since: \(membershipSince)")

            // Extract average age
            let averageAgeText = try doc.select("font:contains(Altersdurchschn.:)").first()?.text() ?? "Unknown"
            let averageAge = averageAgeText.replacingOccurrences(of: "Altersdurchschn.: ", with: "")
            print("Extracted average age: \(averageAge)")

            // Extract player links
            let playerLinks: [String] = try doc.select("a[href^='?action=showPlayer']").map { try $0.attr("href") }
            print("Extracted player links:")

            // Construct the Trikot object
            let trikot = Trikot(home: Dress(image: "none", color: .light), away: Dress(image: "none", color: .dark)) // Use this hardcoded value
            print("Constructed trikot: \(trikot)")

            // Create and return the Team object
            let team = Team(sid: String(id),
                            userId: nil,
                            leagueId: leagueID, // I want to use it here
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
                            balance: 0.0)
            
            return (team, playerLinks)
        }.flatMap { (team, playerLinks) in
            // Save the team to the database
            return team.save(on: req.db).map { (team, playerLinks) }
        }.flatMap { (team, playerLinks) in
            // Run player scraping tasks in the background
            if let teamID = team.id {
                req.eventLoop.execute {
                    playerLinks.forEach { link in
                        let text = link.replacingOccurrences(of: "?action=showPlayer&id=", with: "")
                        print(text)
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
}

/* import Vapor
//import Fluent
//import SwiftSoup
//
//final class ScraperDetailController: RouteCollection {
//    let baseUrl = "https://oekfb.com/"
//    
//    func boot(routes: RoutesBuilder) throws {
//        let scraperRoutes = routes.grouped("scrape")
//        scraperRoutes.get("player", ":id", use: scrapePlayer)
//        scraperRoutes.get("league", ":id", use: scrapeLeagueDetails)
//        scraperRoutes.get("team", ":id", use: scrapeTeam)
//    }
//    
//    // MARK: Scrape Player Function
//    func scrapePlayer(req: Request) throws -> EventLoopFuture<Player> {
//        guard let id = req.parameters.get("id", as: Int.self) else {
//            throw Abort(.badRequest, reason: "Missing or invalid player ID")
//        }
//        return fetchPlayerHTML(req: req, playerId: id).flatMapThrowing { html in
//            try self.parsePlayerHTML(html: html, playerId: id)
//        }.flatMap { player in
//            player.save(on: req.db).map { player }
//        }
//    }
//    
//    // Helper function to fetch player HTML
//    private func fetchPlayerHTML(req: Request, playerId: Int) -> EventLoopFuture<String> {
//        let url = "https://oekfb.com/index.php?action=showPlayer&id=\(playerId)"
//        return req.client.get(URI(string: url)).flatMapThrowing { response in
//            guard let body = response.body else {
//                throw Abort(.badRequest, reason: "No response body")
//            }
//            return String(buffer: body)
//        }
//    }
//    
//    // Helper function to parse player HTML
//    private func parsePlayerHTML(html: String, playerId: Int) throws -> Player {
//        let doc = try SwiftSoup.parse(html)
//        
//        let sid = String(playerId)
//        let name = try doc.select("div[style*='position:absolute; margin-top:-150px;'] font.megaLargeWhite").first()?.text()
//        let number = try doc.select("font:contains(Rückennummer:)").first()?.nextElementSibling()?.text()
//        let birthday = try doc.select("font:contains(Jahrgang:)").first()?.nextElementSibling()?.text()
//        let nationality = try doc.select("font:contains(Nationalität:)").first()?.nextElementSibling()?.text()
//        let eligibilityText = try doc.select("font:contains(Status:)").first()?.nextElementSibling()?.text()
//        let registerDate = try doc.select("font:contains(Angemeldet seit:)").first()?.nextElementSibling()?.text()
//        let teamOeidHref = try doc.select("font:contains(Mannschaft:)").first()?.nextElementSibling()?.select("a").attr("href")
//        let teamOeid = teamOeidHref?.split(separator: "=").last.map(String.init)
//        let imageUrl = try doc.select("td[style*=background-image:url('images/bg/player_bg.png')] img").first()?.attr("src")
//        
//        guard
//            let name = name,
//            let number = number,
//            let birthday = birthday,
//            let nationality = nationality,
//            let eligibilityText = eligibilityText,
//            let registerDate = registerDate,
//            let teamOeid = teamOeid
//        else {
//            throw Abort(.badRequest, reason: "Failed to parse player data")
//        }
//        
//        let eligibility = PlayerEligibility(rawValue: eligibilityText) ?? .blocked
//        
//        return Player(
//            sid: sid,
//            image: self.baseUrl + (imageUrl ?? ""),
//            team_oeid: teamOeid,
//            name: name,
//            number: number,
//            birthday: birthday,
//            teamID: UUID(), // Placeholder for the team ID, you'll need to fetch or determine this based on your data
//            nationality: nationality,
//            position: "field", // Assuming 'field' as the default position, adjust as necessary
//            eligibility: eligibility,
//            registerDate: registerDate
//        )
//    }
//    
//    // MARK: Scrape League Details Function
//    func scrapeLeagueDetails(req: Request) throws -> EventLoopFuture<League> {
//        guard let id = req.parameters.get("id", as: String.self) else {
//            throw Abort(.badRequest, reason: "Missing or invalid league ID")
//        }
//        return fetchLeagueHTML(req: req, leagueId: id).flatMapThrowing { html in
//            try self.parseLeagueHTML(html: html, leagueId: id)
//        }
//    }
//    
//    // Helper function to fetch league HTML
//    private func fetchLeagueHTML(req: Request, leagueId: String) -> EventLoopFuture<String> {
//        let url = "https://oekfb.com/?action=mannschaften&liga=\(leagueId)"
//        return req.client.get(URI(string: url)).flatMapThrowing { response in
//            guard let body = response.body else {
//                throw Abort(.badRequest, reason: "No response body")
//            }
//            return String(buffer: body)
//        }
//    }
//    
//    // Helper function to parse league HTML
//    private func parseLeagueHTML(html: String, leagueId: String) throws -> League {
//        let doc = try SwiftSoup.parse(html)
//        
//        let leagueNameElement = try doc.select("div.MainFrameTopic").first()
//        let leagueName = try leagueNameElement?.text() ?? "Unknown League"
//        
//        let teamElements = try doc.select("div.stat_name a[href^=\"?action=showTeam&data=\"]")
//        var teamLinks: [String] = []
//        for team in teamElements {
//            let link = try team.attr("href")
//            teamLinks.append("https://oekfb.com/\(link)")
//        }
//        
//        // Print each team link on a new line
//        print("Extracted team links:")
//        for link in teamLinks {
//            print(link)
//        }
//        
//        return League(
//            state: .auszuwerten,
//            code: leagueId,
//            name: leagueName
//        )
//    }
//    
//    // MARK: Scrape Team Function
//    func scrapeTeam(req: Request) throws -> EventLoopFuture<Team> {
//        guard let id = req.parameters.get("id", as: Int.self) else {
//            throw Abort(.badRequest, reason: "Missing or invalid team ID")
//        }
//        return fetchTeamHTML(req: req, teamId: id).flatMapThrowing { html in
//            try self.parseTeamHTML(html: html, teamId: id)
//        }.flatMap { (team, playerLinks) in
//            self.saveTeamAndScrapePlayers(req: req, team: team, playerLinks: playerLinks)
//        }
//    }
//    
//    // Helper function to fetch team HTML
//    private func fetchTeamHTML(req: Request, teamId: Int) -> EventLoopFuture<String> {
//        let url = "https://oekfb.com/?action=showTeam&data=\(teamId)"
//        return req.client.get(URI(string: url)).flatMapThrowing { response in
//            guard let body = response.body else {
//                throw Abort(.badRequest, reason: "No response body")
//            }
//            return String(buffer: body)
//        }
//    }
//    
//    // Helper function to parse team HTML
//    private func parseTeamHTML(html: String, teamId: Int) throws -> (Team, [String]) {
//        let doc = try SwiftSoup.parse(html)
//        
//        let teamName = try doc.select("div.MainFrameTopic").first()?.text() ?? "Unknown Team"
//        let captainImageURL = try doc.select("table:contains(Kapitän) img").first()?.attr("src") ?? "Unknown Captain"
//        let coachImageURL = try doc.select("table:contains(Trainer) img").first()?.attr("src") ?? "Unknown Coach"
//        let coachName = try doc.select("table:contains(Trainer) div font.largeWhite").first()?.text() ?? "Unknown Coach"
//        let coach = Trainer(name: coachName, imageURL: self.baseUrl + coachImageURL)
//        let leagueName = try doc.select("div.MainFrameTopicDown").first()?.text() ?? "Unknown League"
//        let coverImg = try doc.select("div.cutedImage img").first()?.attr("src") ?? "https://oekfb.com/images/mannschaften/0.jpg"
//        let logo = try doc.select("table[width='594'] img").first()?.attr("src") ?? "Nothing found"
//        let foundationYearText = try doc.select("font:contains(Gründungsjahr:)").first()?.text() ?? "Unknown"
//        let foundationYear = foundationYearText.replacingOccurrences(of: "Gründungsjahr: ", with: "")
//        let membershipSinceText = try doc.select("font:contains(Im Verband seit:)").first()?.text() ?? "Unknown"
//        let membershipSince = membershipSinceText.replacingOccurrences(of: "Im Verband seit: ", with: "")
//        let averageAgeText = try doc.select("font:contains(Altersdurchschn.:)").first()?.text() ?? "Unknown"
//        let averageAge = averageAgeText.replacingOccurrences(of: "Altersdurchschn.: ", with: "")
//        let playerLinks = try doc.select("a[href^='?action=showPlayer']").map { try $0.attr("href") }
//        
//        print("Extracted team name: \(teamName)")
//        print("Extracted Captain image URL: \(captainImageURL)")
//        print("Extracted Coach name: \(coachName), image URL: \(coachImageURL)")
//        print("Extracted league name: \(leagueName)")
//        print("Extracted cover image: \(coverImg)")
//        print("Extracted logo: \(logo)")
//        print("Extracted foundation year: \(foundationYear)")
//        print("Extracted membership since: \(membershipSince)")
//        print("Extracted average age: \(averageAge)")
//        print("Extracted player links:")
//        for link in playerLinks {
//            print(link)
//        }
//        
//        let trikot = Trikot(home: Dress(image: "none", color: .light), away: Dress(image: "none", color: .dark))
//        
//        let team = Team(
//            sid: String(teamId),
//            userId: nil,
//            leagueId: nil,
//            leagueCode: leagueName,
//            points: 0,
//            coverimg: self.baseUrl + coverImg,
//            logo: logo,
//            teamName: teamName,
//            foundationYear: foundationYear,
//            membershipSince: membershipSince,
//            averageAge: averageAge,
//            coach: coach,
//            captain: self.baseUrl + captainImageURL,
//            trikot: trikot,
//            balance: 0.0
//        )
//        
//        return (team, playerLinks)
//    }
//    
//    // Helper function to save team and scrape players
//    private func saveTeamAndScrapePlayers(req: Request, team: Team, playerLinks: [String]) -> EventLoopFuture<Team> {
//        return team.save(on: req.db).flatMap { savedTeam in
//            let futures = playerLinks.map { link -> EventLoopFuture<Void> in
//                let text = link.replacingOccurrences(of: "?action=showPlayer&id=", with: "")
//                if let playerId = Int(text) {
//                    return self.scrapePlayer(req: req, playerId: playerId).transform(to: ())
//                } else {
//                    return req.eventLoop.makeSucceededFuture(())
//                }
//            }
//            return EventLoopFuture.andAllSucceed(futures, on: req.eventLoop).map { savedTeam }
//        }
//    }
//    
//    // Added this function to use the existing scrapePlayer logic
//    func scrapePlayer(req: Request, playerId: Int) -> EventLoopFuture<Player> {
//        let url = "https://oekfb.com/index.php?action=showPlayer&id=\(playerId)"
//        return req.client.get(URI(string: url)).flatMapThrowing { response in
//            guard let body = response.body else {
//                throw Abort(.badRequest, reason: "No response body")
//            }
//            
//            let html = String(buffer: body)
//            let doc = try SwiftSoup.parse(html)
//            
//            let sid = String(playerId)
//            let name = try doc.select("div[style*='position:absolute; margin-top:-150px;'] font.megaLargeWhite").first()?.text()
//            let number = try doc.select("font:contains(Rückennummer:)").first()?.nextElementSibling()?.text()
//            let birthday = try doc.select("font:contains(Jahrgang:)").first()?.nextElementSibling()?.text()
//            let nationality = try doc.select("font:contains(Nationalität:)").first()?.nextElementSibling()?.text()
//            let eligibilityText = try doc.select("font:contains(Status:)").first()?.nextElementSibling()?.text()
//            let registerDate = try doc.select("font:contains(Angemeldet seit:)").first()?.nextElementSibling()?.text()
//            let teamOeidHref = try doc.select("font:contains(Mannschaft:)").first()?.nextElementSibling()?.select("a").attr("href")
//            let teamOeid = teamOeidHref?.split(separator: "=").last.map(String.init)
//            let imageUrl = try doc.select("td[style*=background-image:url('images/bg/player_bg.png')] img").first()?.attr("src")
//            
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
//            
//            let eligibility = PlayerEligibility(rawValue: eligibilityText) ?? .blocked
//            
//            let player = Player(
//                sid: sid,
//                image: self.baseUrl + (imageUrl ?? ""),
//                team_oeid: teamOeid,
//                name: name,
//                number: number,
//                birthday: birthday,
//                teamID: UUID(), // Placeholder for the team ID, you'll need to fetch or determine this based on your data
//                nationality: nationality,
//                position: "field", // Assuming 'field' as the default position, adjust as necessary
//                eligibility: eligibility,
//                registerDate: registerDate
//            )
//            
//            return player.save(on: req.db).flatMap { player }
//        }
//    }
//}
*/
