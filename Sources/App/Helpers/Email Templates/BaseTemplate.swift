//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Foundation

import Foundation

struct BaseTemplate {
    let logoUrl: String
    let title: String
    let description: String
    let buttonText: String
    let buttonUrl: String
    let assurance: String
    let disclaimer: String
    
    func generateHTML() -> String {
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    body {
                        font-family: Arial, sans-serif;
                        margin: 0;
                        padding: 30px;
                        background-color: #f2f2f7;
                        text-align: center;
                    }
                    .wrapper {
                        padding: 20px;
                        background-color: #ffffff;
                        border-radius: 5px;
                        display: inline-block;
                        text-align: center;
                    }
                    .logo {
                        display: block;
                        width: 150px;
                        height: auto;
                        margin: 0 auto;
                    }
                    h2 {
                        font-size: 24px;
                    }
                    h3 {
                        font-size: 18px;
                    }
                    p {
                        font-size: 14px;
                        line-height: 1.5;
                    }
                    a.button {
                        display: inline-block;
                        padding: 10px 20px;
                        font-size: 14px;
                        text-align: center;
                        text-decoration: none;
                        color: #fff;
                        background-color: #007BFF;
                        border-radius: 5px;
                    }
                    .disclaimer {
                        font-size: 12px;
                        color: #888;
                    }
                </style>
            </head>
            <body>
                <img src="\(logoUrl)" alt="Logo" class="logo">
                <div class="wrapper">
                    <h2>\(title)</h2>
                    <h3>\(description)</h3>
                    <a href="\(buttonUrl)" class="button" target="_blank" rel="noopener noreferrer">\(buttonText)</a>
                    <p>\(assurance)</p>
                    <p class="disclaimer">\(disclaimer)</p>
                </div>
            </body>
            </html>
            """
        return html
    }
}
