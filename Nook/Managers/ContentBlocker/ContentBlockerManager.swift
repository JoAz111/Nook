//
//  ContentBlockerManager.swift
//  Nook
//
//  Orchestrates filter-list downloads, ABP→JSON parsing, WKContentRuleList compilation,
//  and per-WebView application of content-blocking rules.
//
//  Storage layout
//  ──────────────
//  Raw filter text  : ~/Library/Application Support/Nook/FilterLists/{listId}.txt
//  Compiled rules   : WKContentRuleListStore (keyed by list ID)
//  List metadata    : UserDefaults  "contentBlocker.filterLists"    (JSON-encoded [FilterList])
//  Allowed domains  : UserDefaults  "contentBlocker.allowedDomains" ([String])
//

import Foundation
import WebKit

@MainActor
final class ContentBlockerManager {

    // MARK: - Singleton / attachment

    static let shared = ContentBlockerManager()

    weak var browserManager: BrowserManager?

    private(set) var isEnabled: Bool = false

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    // MARK: - Filter list state

    /// Current filter list metadata (default catalog + any user-added lists).
    private(set) var filterLists: [FilterList] = []

    /// Compiled rule lists keyed by FilterList.id.
    private var compiledLists: [String: WKContentRuleList] = [:]

    // MARK: - Exception state

    private var temporarilyDisabledTabs: [UUID: Date] = [:]
    private var allowedDomains: Set<String> = []

    // MARK: - Constants

    private static let filterListsKey      = "contentBlocker.filterLists"
    private static let allowedDomainsKey   = "contentBlocker.allowedDomains"
    private static let staleAfterDays: Double = 4

    // MARK: - Init

    init() {
        loadMetadata()
        loadAllowedDomains()
    }

    // MARK: - Third-party cookie script (mirrors TrackingProtectionManager)

    private var thirdPartyCookieScript: WKUserScript {
        let js = """
        (function() {
          try {
            if (window.top === window) return;
            var ref = document.referrer || "";
            var thirdParty = false;
            try {
              var refHost = ref ? new URL(ref).hostname : null;
              thirdParty = !!refHost && refHost !== window.location.hostname;
            } catch (e) { thirdParty = false; }
            if (!thirdParty) return;
            Object.defineProperty(document, 'cookie', {
              configurable: false,
              enumerable: false,
              get: function() { return ''; },
              set: function(_) { return true; }
            });
            try {
              document.requestStorageAccess = function() {
                return Promise.reject(new DOMException('Blocked by Nook', 'NotAllowedError'));
              };
            } catch (e) {}
          } catch (e) {}
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - Public interface for settings UI

    var totalRuleCount: Int {
        filterLists.filter(\.isEnabled).compactMap(\.ruleCount).reduce(0, +)
    }

    var enabledListCount: Int {
        filterLists.filter(\.isEnabled).count
    }

    /// Toggle a filter list on/off by its ID.
    func setListEnabled(_ listId: String, enabled: Bool) {
        guard let idx = filterLists.firstIndex(where: { $0.id == listId }) else { return }
        filterLists[idx].isEnabled = enabled
        saveMetadata()

        Task {
            if enabled {
                // Compile if we have raw text cached; otherwise download
                if await loadCompiledList(id: listId) == nil {
                    await downloadAndCompile(listId: listId)
                }
            } else {
                removeCompiledList(id: listId)
            }
            rebuildSharedConfiguration()
            applyToExistingWebViews()
        }
    }

    /// Add a user-defined custom filter list.
    func addCustomList(name: String, url: URL) {
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let list = FilterList(id: id, name: name, url: url, category: .custom, isEnabled: true)
        filterLists.append(list)
        saveMetadata()
        Task {
            await downloadAndCompile(listId: id)
            rebuildSharedConfiguration()
            applyToExistingWebViews()
        }
    }

    /// Remove a custom filter list.
    func removeCustomList(_ listId: String) {
        guard let idx = filterLists.firstIndex(where: { $0.id == listId && $0.category == .custom }) else { return }
        filterLists.remove(at: idx)
        saveMetadata()
        removeCompiledList(id: listId)
        // Delete cached raw text
        let textURL = filterListTextURL(for: listId)
        try? FileManager.default.removeItem(at: textURL)
        rebuildSharedConfiguration()
        applyToExistingWebViews()
    }

    // MARK: - Enable / disable (top-level switch)

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Task {
            if enabled {
                await loadAllCompiledLists()
                rebuildSharedConfiguration()
                applyToExistingWebViews()
            } else {
                removeFromSharedConfiguration()
                removeFromExistingWebViews()
            }
        }
    }

    // MARK: - Update flows

    /// Check each enabled list; download ones that are stale (>4 days) or never fetched.
    func checkForUpdates() {
        let staleThreshold = TimeInterval(Self.staleAfterDays * 86_400)
        let now = Date()
        let listsToUpdate = filterLists.filter { list in
            guard list.isEnabled else { return false }
            guard let updated = list.lastUpdated else { return true }   // never fetched
            return now.timeIntervalSince(updated) > staleThreshold
        }
        guard !listsToUpdate.isEmpty else { return }
        Task {
            for list in listsToUpdate {
                await fetchAndProcess(list: list, force: false)
            }
            if isEnabled {
                rebuildSharedConfiguration()
                applyToExistingWebViews()
            }
        }
    }

    /// Force-download all enabled lists, ignoring cache headers.
    func forceUpdateAll() {
        Task {
            let enabled = filterLists.filter(\.isEnabled)
            for list in enabled {
                await fetchAndProcess(list: list, force: true)
            }
            if isEnabled {
                rebuildSharedConfiguration()
                applyToExistingWebViews()
            }
        }
    }

    // MARK: - Exception interface (mirrors TrackingProtectionManager)

    func isTemporarilyDisabled(tabId: UUID) -> Bool {
        if let until = temporarilyDisabledTabs[tabId] {
            if until > Date() { return true }
            temporarilyDisabledTabs.removeValue(forKey: tabId)
        }
        return false
    }

    func disableTemporarily(for tab: Tab, duration: TimeInterval) {
        temporarilyDisabledTabs[tab.id] = Date().addingTimeInterval(duration)
        if let wv = tab.webView {
            removeBlocking(from: wv)
            wv.reloadFromOrigin()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak tab] in
            guard let self, let tab else { return }
            if let exp = self.temporarilyDisabledTabs[tab.id], exp <= Date() {
                self.temporarilyDisabledTabs.removeValue(forKey: tab.id)
                if self.shouldApplyBlocking(to: tab), let wv = tab.webView {
                    self.applyBlocking(to: wv)
                    wv.reloadFromOrigin()
                }
            }
        }
    }

    func allowDomain(_ host: String, allowed: Bool = true) {
        let norm = host.lowercased()
        if allowed { allowedDomains.insert(norm) } else { allowedDomains.remove(norm) }
        saveAllowedDomains()
        if let bm = browserManager {
            for tab in bm.tabManager.allTabs() {
                if tab.webView?.url?.host?.lowercased() == norm, let wv = tab.webView {
                    if allowed { removeBlocking(from: wv) } else { applyBlocking(to: wv) }
                    wv.reloadFromOrigin()
                }
            }
        }
    }

    func isDomainAllowed(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return allowedDomains.contains(h)
    }

    func refreshFor(tab: Tab) {
        guard let wv = tab.webView else { return }
        if shouldApplyBlocking(to: tab) {
            applyBlocking(to: wv)
        } else {
            removeBlocking(from: wv)
        }
        wv.reloadFromOrigin()
    }

    // MARK: - Apply / remove from shared configuration

    private func rebuildSharedConfiguration() {
        guard isEnabled else { return }
        let ucc = BrowserConfiguration.shared.webViewConfiguration.userContentController
        ucc.removeAllContentRuleLists()
        for list in compiledLists.values {
            ucc.add(list)
        }
        ensureThirdPartyCookieScript(in: ucc)
    }

    private func removeFromSharedConfiguration() {
        let ucc = BrowserConfiguration.shared.webViewConfiguration.userContentController
        ucc.removeAllContentRuleLists()
        removeThirdPartyCookieScript(from: ucc)
    }

    // MARK: - Apply / remove to / from existing WebViews

    private func applyToExistingWebViews() {
        guard let bm = browserManager else { return }
        for tab in bm.tabManager.allTabs() {
            guard let wv = tab.webView else { continue }
            if shouldApplyBlocking(to: tab) {
                applyBlocking(to: wv)
            } else {
                removeBlocking(from: wv)
            }
        }
    }

    private func removeFromExistingWebViews() {
        guard let bm = browserManager else { return }
        for tab in bm.tabManager.allTabs() {
            guard let wv = tab.webView else { continue }
            removeBlocking(from: wv)
        }
    }

    // MARK: - Per-WebView helpers

    private func shouldApplyBlocking(to tab: Tab) -> Bool {
        if !isEnabled { return false }
        if isTemporarilyDisabled(tabId: tab.id) { return false }
        if isDomainAllowed(tab.webView?.url?.host) { return false }
        if tab.isOAuthFlow { return false }
        return true
    }

    private func applyBlocking(to webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        for list in compiledLists.values {
            ucc.add(list)
        }
        ensureThirdPartyCookieScript(in: ucc)
    }

    private func removeBlocking(from webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        removeThirdPartyCookieScript(from: ucc)
    }

    // MARK: - Cookie script helpers

    private func ensureThirdPartyCookieScript(in ucc: WKUserContentController) {
        guard !ucc.userScripts.contains(where: { $0.source.contains("document.referrer") }) else { return }
        ucc.addUserScript(thirdPartyCookieScript)
    }

    private func removeThirdPartyCookieScript(from ucc: WKUserContentController) {
        let remaining = ucc.userScripts.filter { !$0.source.contains("document.referrer") }
        ucc.removeAllUserScripts()
        remaining.forEach { ucc.addUserScript($0) }
    }

    // MARK: - Network fetch

    /// Fetch a filter list, respecting ETag/If-Modified-Since unless `force` is true.
    private func fetchAndProcess(list: FilterList, force: Bool) async {
        var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if !force {
            if let etag = list.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastUpdated = list.lastUpdated {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                formatter.timeZone = TimeZone(abbreviation: "GMT")
                request.setValue(formatter.string(from: lastUpdated), forHTTPHeaderField: "If-Modified-Since")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 304 {
                // Not modified — bump the timestamp only
                if let idx = filterLists.firstIndex(where: { $0.id == list.id }) {
                    filterLists[idx].lastUpdated = Date()
                    saveMetadata()
                }
                return
            }

            guard http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return }

            // Save raw text to disk
            let textURL = filterListTextURL(for: list.id)
            try text.write(to: textURL, atomically: true, encoding: .utf8)

            // Parse on background thread
            let parseResult = await Task.detached(priority: .utility) {
                FilterListParser.parse(text)
            }.value

            // Compile via WKContentRuleListStore
            guard let store = WKContentRuleListStore.default() else { return }
            let compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                store.compileContentRuleList(
                    forIdentifier: list.id,
                    encodedContentRuleList: parseResult.json
                ) { ruleList, error in
                    if let error {
                        print("[ContentBlocker] Compile error for \(list.id): \(error)")
                    }
                    cont.resume(returning: ruleList)
                }
            }

            if let compiled {
                compiledLists[list.id] = compiled
            }

            // Update metadata
            if let idx = filterLists.firstIndex(where: { $0.id == list.id }) {
                filterLists[idx].lastUpdated = Date()
                filterLists[idx].etag = (http.allHeaderFields["ETag"] as? String)
                    ?? (http.allHeaderFields["etag"] as? String)
                filterLists[idx].ruleCount = parseResult.ruleCount
                saveMetadata()
            }

            print("[ContentBlocker] Updated \(list.id): \(parseResult.ruleCount) rules, \(parseResult.skippedCount) skipped")

        } catch {
            print("[ContentBlocker] Fetch error for \(list.id): \(error)")
        }
    }

    // MARK: - Compile without fetch (uses cached raw text)

    private func downloadAndCompile(listId: String) async {
        guard let list = filterLists.first(where: { $0.id == listId }) else { return }
        let textURL = filterListTextURL(for: listId)
        if let text = try? String(contentsOf: textURL, encoding: .utf8) {
            // We have cached raw text — just recompile
            let parseResult = await Task.detached(priority: .utility) {
                FilterListParser.parse(text)
            }.value
            await compile(id: listId, json: parseResult.json, ruleCount: parseResult.ruleCount)
        } else {
            // No cache — download
            await fetchAndProcess(list: list, force: true)
        }
    }

    /// Compile JSON into WKContentRuleList and cache in `compiledLists`.
    private func compile(id: String, json: String, ruleCount: Int) async {
        guard let store = WKContentRuleListStore.default() else { return }
        let compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { print("[ContentBlocker] Compile error for \(id): \(error)") }
                cont.resume(returning: list)
            }
        }
        if let compiled {
            compiledLists[id] = compiled
            if let idx = filterLists.firstIndex(where: { $0.id == id }) {
                filterLists[idx].ruleCount = ruleCount
                saveMetadata()
            }
        }
    }

    // MARK: - Load compiled lists from WKContentRuleListStore

    private func loadAllCompiledLists() async {
        let enabled = filterLists.filter(\.isEnabled)
        for list in enabled {
            if compiledLists[list.id] == nil {
                _ = await loadCompiledList(id: list.id)
            }
        }
        // Kick off updates for lists that are missing or stale
        checkForUpdates()
    }

    /// Try to load a compiled rule list from the store. Returns the list if found, nil otherwise.
    @discardableResult
    private func loadCompiledList(id: String) async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        let existing = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in cont.resume(returning: list) }
        }
        if let existing {
            compiledLists[id] = existing
        }
        return existing
    }

    // MARK: - Remove compiled list

    private func removeCompiledList(id: String) {
        compiledLists.removeValue(forKey: id)
        guard let store = WKContentRuleListStore.default() else { return }
        store.removeContentRuleList(forIdentifier: id) { _ in }
    }

    // MARK: - Persistence helpers

    private func filterListTextURL(for listId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Nook/FilterLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(listId).txt")
    }

    private func loadMetadata() {
        if let data = UserDefaults.standard.data(forKey: Self.filterListsKey),
           let lists = try? JSONDecoder().decode([FilterList].self, from: data) {
            filterLists = lists
        } else {
            filterLists = FilterList.defaultCatalog
        }
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(filterLists) {
            UserDefaults.standard.set(data, forKey: Self.filterListsKey)
        }
    }

    private func loadAllowedDomains() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.allowedDomainsKey) ?? []
        allowedDomains = Set(stored)
    }

    private func saveAllowedDomains() {
        UserDefaults.standard.set(Array(allowedDomains), forKey: Self.allowedDomainsKey)
    }
}
