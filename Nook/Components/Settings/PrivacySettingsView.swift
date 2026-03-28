//
//  PrivacySettingsView.swift
//  Nook
//
//  Created by Jonathan Caudill on 15/08/2025.
//

import SwiftUI
import WebKit

struct PrivacySettingsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.nookSettings) var nookSettings
    @StateObject private var cookieManager = CookieManager()
    @StateObject private var cacheManager = CacheManager()
    @State private var showingCookieManager = false
    @State private var showingCacheManager = false
    @State private var isClearing = false
    @State private var customListURL = ""
    @State private var customListName = ""
    @State private var showingAddCustomList = false

    var body: some View {
        @Bindable var settings = nookSettings

        return
        VStack(alignment: .leading, spacing: 20) {
            // Cookie Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cookie Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cookieStatsView
                    
                    HStack {
                        Button("Manage Cookies") {
                            showingCookieManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Data") {
                            Button("Clear Expired Cookies") {
                                clearExpiredCookies()
                            }
                            
                            Button("Clear Third-Party Cookies") {
                                clearThirdPartyCookies()
                            }
                            
                            Button("Clear High-Risk Cookies") {
                                clearHighRiskCookies()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cookies") {
                                clearAllCookies()
                            }
                            
                            Button("Privacy Cleanup") {
                                performCookiePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Website Data", role: .destructive) {
                                clearAllWebsiteData()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Cache Management Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Cache Management")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    cacheStatsView
                    
                    HStack {
                        Button("Manage Cache") {
                            showingCacheManager = true
                        }
                        .buttonStyle(.bordered)
                        
                        Menu("Clear Cache") {
                            Button("Clear Stale Cache") {
                                clearStaleCache()
                            }
                            
                            Button("Clear Personal Data Cache") {
                                clearPersonalDataCache()
                            }
                            
                            Button("Clear Disk Cache") {
                                clearDiskCache()
                            }
                            
                            Button("Clear Memory Cache") {
                                clearMemoryCache()
                            }
                            
                            Divider()
                            
                            Button("Privacy Cleanup") {
                                performCachePrivacyCleanup()
                            }
                            
                            Divider()
                            
                            Button("Clear All Cache", role: .destructive) {
                                clearAllCache()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                        
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Content Blocker Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Content Blocker")
                        .font(.headline)
                    Spacer()
                    if browserManager.contentBlockerManager.isEnabled {
                        Text("\(browserManager.contentBlockerManager.totalRuleCount) rules across \(browserManager.contentBlockerManager.enabledListCount) lists")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Content Blocker", isOn: $settings.blockCrossSiteTracking)
                        .onChange(of: nookSettings.blockCrossSiteTracking) { _, enabled in
                            browserManager.contentBlockerManager.setEnabled(enabled)
                        }

                    if nookSettings.blockCrossSiteTracking {
                        Divider()

                        // Filter lists grouped by category
                        ForEach(FilterList.Category.allCases, id: \.self) { category in
                            let listsInCategory = browserManager.contentBlockerManager.filterLists.filter { $0.category == category }
                            if !listsInCategory.isEmpty {
                                Text(category.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)

                                ForEach(listsInCategory) { list in
                                    HStack {
                                        Toggle(list.name, isOn: Binding(
                                            get: { list.isEnabled },
                                            set: { browserManager.contentBlockerManager.setListEnabled(list.id, enabled: $0) }
                                        ))

                                        Spacer()

                                        if let count = list.ruleCount {
                                            Text("\(count) rules")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }

                                        if list.category == .custom {
                                            Button(action: {
                                                browserManager.contentBlockerManager.removeCustomList(list.id)
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundStyle(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        // Add custom list
                        DisclosureGroup("Add Custom List", isExpanded: $showingAddCustomList) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("List name", text: $customListName)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Filter list URL", text: $customListURL)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Button("Add") {
                                        guard let url = URL(string: customListURL),
                                              !customListName.isEmpty else { return }
                                        browserManager.contentBlockerManager.addCustomList(name: customListName, url: url)
                                        customListName = ""
                                        customListURL = ""
                                        showingAddCustomList = false
                                    }
                                    .disabled(customListURL.isEmpty || customListName.isEmpty)
                                }
                            }
                            .padding(.top, 4)
                        }

                        Divider()

                        HStack {
                            Button("Update All Now") {
                                browserManager.contentBlockerManager.forceUpdateAll()
                            }
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // Website Data Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Website Data")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clear Browsing History") {
                        clearBrowsingHistory()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Clear Cache") {
                        clearCache()
                    }
                    .buttonStyle(.bordered)
                    
                                    }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            Task {
                await cookieManager.loadCookies()
                await cacheManager.loadCacheData()
            }
        }
        .sheet(isPresented: $showingCookieManager) {
            CookieManagementView()
        }
        .sheet(isPresented: $showingCacheManager) {
            CacheManagementView()
        }
    }
    
    // MARK: - Cache Stats View
    
    private var cacheStatsView: some View {
        let stats = cacheManager.getCacheStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.blue)
                Text("Stored Cache")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Disk: \(formatSize(stats.diskSize))")
                            Text("•")
                            Text("Memory: \(formatSize(stats.memorySize))")
                            if stats.staleCount > 0 {
                                Text("•")
                                Text("Stale: \(stats.staleCount)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Cookie Stats View
    
    private var cookieStatsView: some View {
        let stats = cookieManager.getCookieStats()
        
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.blue)
                Text("Stored Cookies")
                    .fontWeight(.medium)
                Spacer()
                Text("\(stats.total)")
                    .foregroundColor(.secondary)
            }
            
            if stats.total > 0 {
                HStack {
                    Spacer().frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Session: \(stats.session)")
                            Text("•")
                            Text("Persistent: \(stats.persistent)")
                            if stats.expired > 0 {
                                Text("•")
                                Text("Expired: \(stats.expired)")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text("Total size: \(formatSize(stats.totalSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func clearExpiredCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteExpiredCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteAllCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllWebsiteData() {
        isClearing = true
        Task {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast)
            await cookieManager.loadCookies()
            await cacheManager.loadCacheData()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearBrowsingHistory() {
        browserManager.historyManager.clearHistory()
    }
    
    private func clearCache() {
        Task {
            let dataStore = WKWebsiteDataStore.default()
            await dataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast)
        }
    }
    
        
    // MARK: - Helper Methods
    
    // MARK: - Cache Action Methods
    
    private func clearStaleCache() {
        isClearing = true
        Task {
            await cacheManager.clearStaleCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearDiskCache() {
        isClearing = true
        Task {
            await cacheManager.clearDiskCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearMemoryCache() {
        isClearing = true
        Task {
            await cacheManager.clearMemoryCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearAllCache() {
        isClearing = true
        Task {
            await cacheManager.clearAllCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    // MARK: - Privacy-Compliant Actions
    
    private func clearThirdPartyCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteThirdPartyCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearHighRiskCookies() {
        isClearing = true
        Task {
            await cookieManager.deleteHighRiskCookies()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCookiePrivacyCleanup() {
        isClearing = true
        Task {
            await cookieManager.performPrivacyCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func clearPersonalDataCache() {
        isClearing = true
        Task {
            await cacheManager.clearPersonalDataCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func performCachePrivacyCleanup() {
        isClearing = true
        Task {
            await cacheManager.performPrivacyCompliantCleanup()
            await MainActor.run {
                isClearing = false
            }
        }
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    PrivacySettingsView()
        .environmentObject(BrowserManager())
}
