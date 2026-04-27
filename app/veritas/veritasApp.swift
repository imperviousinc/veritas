//
//  veritasApp.swift
//  veritas
//
//
//

import SwiftUI
import AppKit

@main
struct veritasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var veritas: Veritas!
    let viewModel = VeritasViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Initialize Veritas backend with sandbox-safe data directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dataDirURL = appSupport.appendingPathComponent("Veritas")
        try? FileManager.default.createDirectory(at: dataDirURL, withIntermediateDirectories: true)
        veritas = Veritas(dataDir: dataDirURL.path, external: nil, seeds: nil)

        viewModel.configure(veritas)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 570)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(viewModel: viewModel)
        )

        // Listen for share extension notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShareNotification(_:)),
            name: NSNotification.Name("com.impervious.veritas.shareQuery"),
            object: nil
        )
    }

    // MARK: - Share Extension Handling

    @objc private func handleShareNotification(_ notification: Notification) {
        guard let query = notification.object as? String, !query.isEmpty else { return }
        handleIncomingQuery(query)
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "veritas" else { continue }

            if url.host == "search",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItem = components.queryItems?.first(where: { $0.name == "q" }),
               let query = queryItem.value {
                handleIncomingQuery(query)
            }
        }
    }

    private func handleIncomingQuery(_ query: String) {
        // Show the popover
        if let button = statusItem.button, !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.isOpaque = false
                popoverWindow.backgroundColor = .clear
            }
        }

        // Navigate to search
        viewModel.pendingShareQuery = query
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Style the popover window for glass effect
            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.isOpaque = false
                popoverWindow.backgroundColor = .clear
            }
        }
    }
}

// Wrapper that applies the glass background
struct PopoverContentView: View {
    @ObservedObject var viewModel: VeritasViewModel

    var body: some View {
        ContentView()
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(VisualEffectBackground())
            .overlay { NostrGlowOverlay(isActive: $viewModel.showNostrGlow) }
    }
}

/// Green border glow that pulses when a verified nostr message is found.
struct NostrGlowOverlay: View {
    @Binding var isActive: Bool
    @State private var glowOpacity: Double = 0

    var body: some View {
        if isActive {
            ZStack {
                // Soft outer glow
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.green.opacity(0.4), lineWidth: 2.5)
                    .blur(radius: 8)

                // Crisp inner edge
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.green.opacity(0.3), lineWidth: 1)
            }
            .opacity(glowOpacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    glowOpacity = 1
                }
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .dark
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
