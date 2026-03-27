//
//  WebStoreScriptHandler.swift
//  Nook
//
//  Message handler for Chrome Web Store integration
//

import Foundation
import WebKit
import AppKit

@MainActor
final class WebStoreScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var browserManager: BrowserManager?
    
    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
        super.init()
    }
    
    /// Check if a URL is a Chrome Web Store page (matches BrowserConfiguration.isChromeWebStore)
    private static func isWebStorePage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return (host == "chromewebstore.google.com") ||
               (host == "chrome.google.com" && path.contains("webstore"))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nookWebStore" else { return }

        // SECURITY: Only accept install messages from Chrome Web Store pages
        guard let pageURL = message.frameInfo.request.url ?? message.webView?.url,
              Self.isWebStorePage(pageURL) else {
            print("⚠️ [WebStore] Blocked install request from untrusted origin: \(message.webView?.url?.host ?? "unknown")")
            return
        }

        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              action == "installExtension",
              let extensionId = body["extensionId"] as? String else {
            return
        }

        // SECURITY: Validate extensionId format (Chrome extension IDs are 32 lowercase a-p chars)
        guard extensionId.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else {
            print("⚠️ [WebStore] Blocked install request with invalid extensionId: \(extensionId.prefix(50))")
            return
        }

        // Install the extension
        if #available(macOS 15.5, *), let extensionManager = browserManager?.extensionManager {
            extensionManager.installFromWebStore(extensionId: extensionId) { result in
                Task { @MainActor in
                    let success = if case .success = result { true } else { false }

                    // SECURITY: Use parameterized JS to prevent XSS via extensionId
                    if let webView = message.webView {
                        let safeScript = """
                        window.dispatchEvent(new CustomEvent('nookInstallComplete', {
                            detail: { success: params.success, extensionId: params.extensionId }
                        }));
                        """
                        do {
                            _ = try await webView.callAsyncJavaScript(
                                safeScript,
                                arguments: ["params": ["success": success, "extensionId": extensionId]],
                                in: nil,
                                contentWorld: .page
                            )
                        } catch {
                            print("❌ Failed to dispatch install completion event: \(error)")
                        }
                    }

                    switch result {
                    case .success(let ext):
                        self.showSuccessNotification(extensionName: ext.name)
                    case .failure(let error):
                        self.showErrorNotification(error: error)
                    }
                }
            }
        } else {
            showErrorNotification(error: ExtensionError.unsupportedOS)
        }
    }
    
    private func showSuccessNotification(extensionName: String) {
        let alert = NSAlert()
        alert.messageText = "Extension Installed"
        alert.informativeText = "\"\(extensionName)\" has been installed successfully and is ready to use."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        
        // Show non-modal
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
    
    private func showErrorNotification(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Installation Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        // Show non-modal
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
