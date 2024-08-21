import Vapor
import Fluent
import SwiftSoup

final class ScraperController {
    let baseUrl = "https://oekfb.com/"
    private let apiClient = APIClient()
    
    func scrapeLeagueDetails(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let leagueId = req.parameters.get("id", as: String.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID")
        }
        
        let url = URL(string: "https://oekfb.com/?action=mannschaften&liga=\(leagueId)")!
        
        return fetchHTML(from: url, on: req).flatMap { html in
            do {
                let doc: Document = try SwiftSoup.parse(html)
                let leagueNameElement: Element = try doc.select("div.MainFrameTopic").first()!
                let leagueName = try leagueNameElement.text()
                
                let teamElements: Elements = try doc.select("div.stat_name a[href^=\"?action=showTeam&data=\"]")
                let teamLinks: [String] = try teamElements.map { try $0.attr("href") }
                
                let league = League(state: .auszuwerten, teamcount: teamLinks.count, code: leagueId, name: leagueName)
                
                print("Saving league: \(leagueName)")
                
                return league.save(on: req.db).flatMap {
                    guard let leagueUUID = league.id else {
                        return req.eventLoop.future(error: Abort(.internalServerError))
                    }
                    return self.scrapeTeamsSequentially(for: teamLinks, leagueUUID: leagueUUID, req: req).transform(to: .ok)
                }
            } catch {
                print("Failed to parse league HTML: \(error.localizedDescription)")
                return req.eventLoop.future(error: error)
            }
        }
    }
    
    private func scrapeTeamsSequentially(for teamLinks: [String], leagueUUID: UUID, req: Request) -> EventLoopFuture<Void> {
        var future: EventLoopFuture<Void> = req.eventLoop.makeSucceededFuture(())
        
        for link in teamLinks {
            let teamId = link.split(separator: "=").last.map(String.init) ?? ""
            guard let teamIdInt = Int(teamId) else {
                print("Invalid team ID: \(teamId)")
                continue
            }
            
            future = future.flatMap {
                self.scrapeTeam(id: teamIdInt, leagueId: leagueUUID, req: req)
            }
        }
        
        return future
    }
    
    private func scrapeTeam(id: Int, leagueId: UUID, req: Request) -> EventLoopFuture<Void> {
        let url = URL(string: "https://oekfb.com/?action=showTeam&data=\(id)")!
        print("Start Counting.")
        return req.eventLoop.scheduleTask(in: .seconds(3)) {
            return self.fetchHTML(from: url, on: req).flatMap { html in
                do {
                    let doc: Document = try SwiftSoup.parse(html)
                    
                    let teamName = try doc.select("div.MainFrameTopic").first()?.text() ?? "Unknown Team"
                    let captainImageURL = try doc.select("table:contains(Kapitän) img").first()?.attr("src") ?? "Unknown Captain"
                    let coachImageURL = try doc.select("table:contains(Trainer) img").first()?.attr("src") ?? "Unknown Coach"
                    let coachName = try doc.select("table:contains(Trainer) div font.largeWhite").first()?.text() ?? "Unknown Coach"
                    let coach = Trainer(name: coachName, imageURL: self.baseUrl + coachImageURL)
                    
                    let leagueName = try doc.select("div.MainFrameTopicDown").first()?.text() ?? "Unknown League"
                    let coverImg = try doc.select("div.cutedImage img").first()?.attr("src") ?? "https://oekfb.com/images/mannschaften/0.jpg"
                    let logo = try doc.select("table[width='594'] img").first()?.attr("src") ?? "Nothing found"
                    
                    let foundationYearText = try doc.select("font:contains(Gründungsjahr:)").first()?.text() ?? "Unknown"
                    let foundationYear = foundationYearText.replacingOccurrences(of: "Gründungsjahr: ", with: "")
                    
                    let membershipSinceText = try doc.select("font:contains(Im Verband seit:)").first()?.text() ?? "Unknown"
                    let membershipSince = membershipSinceText.replacingOccurrences(of: "Im Verband seit: ", with: "")
                    
                    let averageAgeText = try doc.select("font:contains(Altersdurchschn.:)").first()?.text() ?? "Unknown"
                    let averageAge = averageAgeText.replacingOccurrences(of: "Altersdurchschn.: ", with: "")
                    
                    let trikot = Trikot(home: "", away: "")
                    
                    let randomMail = String.randomString(length: 5) + "@oekfb.eu"
                    let randomPass = String.randomString(length: 8)
                    
                    let team = Team(
                        sid: String(id),
                        userId: nil,
                        leagueId: leagueId,
                        leagueCode: nil,
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
                        balance: 0.0, referCode: String.randomString(length: 6),
                        usremail: randomMail,
                        usrpass: randomPass, usrtel: ""
                    )
                    
                    print("Saving team: \(teamName)")
                    
                    return team.save(on: req.db).flatMap {
                        guard let teamUUID = team.id else {
                            return req.eventLoop.future(error: Abort(.internalServerError))
                        }
                        return self.scrapePlayers(for: team, req: req)
                    }
                } catch {
                    print("Failed to parse team HTML: \(error.localizedDescription)")
                    return req.eventLoop.future(error: error)
                }
            }
        }.futureResult.flatMap { $0 }
    }

    private func scrapePlayers(for team: Team, req: Request) -> EventLoopFuture<Void> {
        let url = URL(string: "https://oekfb.com/?action=showTeam&data=\(team.sid)")!
        
        return fetchHTML(from: url, on: req).flatMap { html in
            do {
                let doc: Document = try SwiftSoup.parse(html)
                let playerLinks: [String] = try doc.select("a[href^='?action=showPlayer']").map { try $0.attr("href") }
                
                let playerScrapingFutures = playerLinks.map { link -> EventLoopFuture<Void> in
                    let playerId = link.split(separator: "=").last.map(String.init) ?? ""
                    guard let playerIdInt = Int(playerId) else {
                        print("Invalid player ID: \(playerId)")
                        return req.eventLoop.future()
                    }
                    return self.scrapePlayer(id: playerIdInt, teamId: team.id!, req: req)
                }
                
                return playerScrapingFutures.flatten(on: req.eventLoop)
            } catch {
                print("Failed to parse player links HTML: \(error.localizedDescription)")
                return req.eventLoop.future(error: error)
            }
        }
    }
    
    private func scrapePlayer(id: Int, teamId: UUID, req: Request) -> EventLoopFuture<Void> {
        let url = URL(string: "https://oekfb.com/index.php?action=showPlayer&id=\(id)")!
        
        return fetchHTML(from: url, on: req).flatMap { html in
            do {
                let doc = try SwiftSoup.parse(html)
                
                let sid = String(id)
                let name = try doc.select("div[style*='position:absolute; margin-top:-150px;'] font.megaLargeWhite").first()?.text()
                let number = try doc.select("font:contains(Rückennummer:)").first()?.nextElementSibling()?.text()
                let birthday = try doc.select("font:contains(Jahrgang:)").first()?.nextElementSibling()?.text()
                let nationality = try doc.select("font:contains(Nationalität:)").first()?.nextElementSibling()?.text()
                let eligibilityText = try doc.select("font:contains(Status:)").first()?.nextElementSibling()?.text()
                let registerDate = try doc.select("font:contains(Angemeldet seit:)").first()?.nextElementSibling()?.text()
                let teamOeidHref = try doc.select("font:contains(Mannschaft:)").first()?.nextElementSibling()?.select("a").attr("href")
                let teamOeid = teamOeidHref?.split(separator: "=").last.map(String.init)
                let imageUrl = try doc.select("td[style*=background-image:url('images/bg/player_bg.png')] img").first()?.attr("src")
                
                guard
                    let name = name,
                    let number = number,
                    let birthday = birthday,
                    let nationality = nationality,
                    let eligibilityText = eligibilityText,
                    let registerDate = registerDate,
                    let teamOeid = teamOeid
                else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse player data"])
                }
                
                let eligibility = PlayerEligibility(rawValue: eligibilityText) ?? .Gesperrt
                
                let player = Player(
                    sid: sid,
                    image: self.baseUrl + (imageUrl ?? ""),
                    team_oeid: teamOeid,
                    email: "",
                    name: name,
                    number: number,
                    birthday: birthday,
                    teamID: teamId,
                    nationality: nationality,
                    position: "field", // Assuming 'field' as the default position, adjust as necessary
                    eligibility: eligibility,
                    registerDate: registerDate, 
                    identification: nil,
                    status: true
                )
                
                print("Saving player: \(name ?? "Unknown Player")")
                
                return player.save(on: req.db)
            } catch {
                print("Failed to parse player HTML: \(error.localizedDescription)")
                return req.eventLoop.future(error: error)
            }
        }
    }

    private func fetchHTML(from url: URL, on req: Request, retryCount: Int = 3) -> EventLoopFuture<String> {
        let promise = req.eventLoop.makePromise(of: String.self)
        
        func attemptFetch(retriesLeft: Int) {
            apiClient.getHTMLDocument(from: url, on: req.eventLoop).whenComplete { result in
                switch result {
                case .success(let document):
                    do {
                        let html = try document.outerHtml()
                        promise.succeed(html)
                    } catch {
                        promise.fail(error)
                    }
                case .failure(let error):
                    if retriesLeft > 0 && (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == -1011 {
                        print("Retrying fetch HTML: \(url). Retries left: \(retriesLeft - 1)")
                        attemptFetch(retriesLeft: retriesLeft - 1)
                    } else {
                        print("Error fetching HTML: \(url). Error: \(error.localizedDescription)")
                        promise.fail(error)
                    }
                }
            }
        }
        
        attemptFetch(retriesLeft: retryCount)
        
        return promise.futureResult
    }

}
