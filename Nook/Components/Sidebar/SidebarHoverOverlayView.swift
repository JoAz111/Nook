//
//  SidebarHoverOverlayView.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import SwiftUI
import UniversalGlass
import AppKit

struct SidebarHoverOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var hoverManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings

    var body: some View {
        let cornerRadius: CGFloat = windowState.isImmersiveFullScreen ? 0 : 12
        let horizontalInset: CGFloat = windowState.isImmersiveFullScreen ? 0 : 7
        let verticalInset: CGFloat = windowState.isImmersiveFullScreen ? 0 : 7

        // Only render overlay plumbing when the real sidebar is collapsed
        if !windowState.isSidebarVisible {
            ZStack(alignment: nookSettings.sidebarPosition == .left ? .leading : .trailing) {
                // Edge hover hotspot
                Color.clear
                    .frame(width: hoverManager.triggerWidth)
                    .contentShape(Rectangle())
                    .onHover { isIn in
                        if isIn && !windowState.isSidebarVisible {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                hoverManager.isOverlayVisible = true
                            }
                        }
                        NSCursor.arrow.set()
                    }

                if hoverManager.isOverlayVisible {
                    SpacesSideBarView()
                        .frame(width: windowState.sidebarWidth)
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .environment(commandPalette)
                        .environmentObject(browserManager.gradientColorManager)
                        .frame(maxHeight: .infinity)
                        .background{
                            
                            
                            SpaceGradientBackgroundView()
                                .environmentObject(browserManager)
                                .environmentObject(browserManager.gradientColorManager)
                                .environment(windowState)
                                .clipShape(.rect(cornerRadius: cornerRadius))
                            
                                Rectangle()
                                    .fill(Color.clear)
                                    .universalGlassEffect(.regular.tint(Color(.windowBackgroundColor).opacity(0.35)), in: .rect(cornerRadius: cornerRadius))
                        }
                        .alwaysArrowCursor()
                        .padding(nookSettings.sidebarPosition == .left ? .leading : .trailing, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .transition(
                            .move(edge: nookSettings.sidebarPosition == .left ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: nookSettings.sidebarPosition == .left ? .topLeading : .topTrailing)
            // Container remains passive; only overlay/hotspot intercept
        }
    }
}
