//
//  FilterList.swift
//  Nook
//
//  Filter list model for content blocking.
//

import Foundation

struct FilterList: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let url: URL
    let category: Category
    var isEnabled: Bool
    var lastUpdated: Date?
    var etag: String?
    var ruleCount: Int?

    enum Category: String, Codable, CaseIterable {
        case ads
        case privacy
        case annoyances
        case regional
        case custom

        var displayName: String {
            switch self {
            case .ads: return "Ads"
            case .privacy: return "Privacy"
            case .annoyances: return "Annoyances"
            case .regional: return "Regional"
            case .custom: return "Custom"
            }
        }
    }

    static let defaultCatalog: [FilterList] = [
        FilterList(
            id: "easylist",
            name: "EasyList",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            category: .ads,
            isEnabled: true
        ),
        FilterList(
            id: "easyprivacy",
            name: "EasyPrivacy",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            category: .privacy,
            isEnabled: true
        ),
        FilterList(
            id: "peter-lowe",
            name: "Peter Lowe's Ad Servers",
            url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext")!,
            category: .ads,
            isEnabled: false
        ),
        FilterList(
            id: "fanboy-annoyance",
            name: "Fanboy's Annoyances",
            url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!,
            category: .annoyances,
            isEnabled: false
        ),
    ]
}
