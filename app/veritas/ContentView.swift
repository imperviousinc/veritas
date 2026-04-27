//
//  ContentView.swift
//  veritas
//
//

import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Navigation

enum AppScreen {
    case welcome
    case syncing
    case home
    case search
    case settings
}

// MARK: - View Model

@MainActor
class VeritasViewModel: ObservableObject {
    @Published var trustAnchor: String = ""
    @Published var anchorHeight: UInt32 = 0
    @Published var tipHeight: String = ""
    @Published var serverInfo: ServerInfo?
    @Published var ready = false
    @Published var pendingShareQuery: String?
    @Published var showNostrGlow = false

    /// Anchor status color: green (fresh), yellow (36+ blocks behind), red (2016+ blocks / ~2 weeks)
    var anchorColor: Color {
        guard let info = serverInfo, anchorHeight > 0 else { return .green }
        let behind = info.chainHeaders - anchorHeight
        if behind >= 2016 { return .red }
        if behind >= 36 { return .yellow }
        return .green
    }

    // Checkpoint choice state
    @Published var pendingCheckpoint: CheckpointInfo?
    @Published var checkpointLoading = false

    // Sync state
    @Published var syncPhase: SyncPhase?
    @Published var syncProgress: Float = 0
    @Published var syncMessage: String = ""
    @Published var startError: VeritasError?
    @Published var latestLogLine: String = ""

    private(set) var veritas: Veritas?
    private var pollTask: Task<Void, Never>?

    func configure(_ veritas: Veritas) {
        self.veritas = veritas
    }

    /// Re-create a fresh Veritas instance after a reset
    func reconfigure() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dataDirURL = appSupport.appendingPathComponent("Veritas")
        try? FileManager.default.createDirectory(at: dataDirURL, withIntermediateDirectories: true)
        self.veritas = Veritas(dataDir: dataDirURL.path, external: nil, seeds: nil)
    }

    /// Check checkpoint status and start services - prompts user if a non-hardcoded checkpoint is available.
    /// `onDirectStart` is called when services start without needing a checkpoint choice.
    /// `skipChoice` bypasses the checkpoint choice UI (used for retries).
    func checkAndStart(skipChoice: Bool = false, onDirectStart: (() -> Void)? = nil) {
        guard let veritas else { return }
        startError = nil
        syncPhase = nil
        checkpointLoading = true

        // checkCheckpoint() may do a network call - run off main thread
        Task.detached { [weak self] in
            let checkpoint = veritas.checkCheckpoint()
            print("[Veritas] checkCheckpoint - needs: \(checkpoint.needsCheckpoint), hardcoded: \(checkpoint.hardcodedHeight), latest: \(checkpoint.latest?.height ?? 0)")

            await MainActor.run {
                guard let self else { return }
                self.checkpointLoading = false

                if !checkpoint.needsCheckpoint {
                    // Already have data, just start
                    self.startServices()
                    onDirectStart?()
                    return
                }

                // If there's a server checkpoint that differs from hardcoded, ask the user
                if !skipChoice,
                   let latest = checkpoint.latest,
                   latest.height != checkpoint.hardcodedHeight {
                    self.pendingCheckpoint = checkpoint
                    return
                }

                // Use best available checkpoint directly
                if let latest = checkpoint.latest {
                    veritas.useCheckpoint(checkpoint: latest)
                } else if checkpoint.hardcodedHeight == 0 {
                    // No checkpoint available at all - sync from scratch
                    veritas.skipCheckpoint()
                }
                self.startServices()
                onDirectStart?()
            }
        }
    }

    /// Start using the server-provided checkpoint (user explicitly chose it)
    func startWithServerCheckpoint(_ checkpoint: CheckpointInfo) {
        pendingCheckpoint = nil
        if let latest = checkpoint.latest {
            veritas?.useCheckpoint(checkpoint: latest)
        }
        startServices()
    }

    /// Start using only the hardcoded checkpoint (user declined server checkpoint)
    func startWithHardcodedCheckpoint() {
        pendingCheckpoint = nil
        startServices()
    }

    /// Start syncing from scratch with no checkpoint
    func startFromScratch() {
        pendingCheckpoint = nil
        veritas?.skipCheckpoint()
        startServices()
    }

    /// Start Veritas services on a background thread
    func startServices() {
        startError = nil
        UserDefaults.standard.set(true, forKey: "veritasHasStarted")
        Task.detached { [veritas] in
            guard let veritas else { return }
            do {
                try veritas.start()
            } catch let error as VeritasError {
                await MainActor.run { [weak self] in
                    self?.startError = error
                }
            } catch {
                print("[Veritas] start failed: \(error)")
            }
        }
    }

    /// Start polling getSyncStatus() and backend logs every 100ms
    func startPolling(onReady: @escaping () -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let veritas = self.veritas else { break }
                let status = await veritas.getSyncStatus()
                self.syncPhase = status.phase
                self.syncProgress = status.progress
                self.syncMessage = status.message

                // Fetch backend logs and pipe into LogStore
                let logs = veritas.getLogs()
                let store = LogStore.shared
                for entry in logs {
                    let level: LogStore.AppLogEntry.Level = switch entry.level.lowercased() {
                    case "error": .error
                    case "warn", "warning": .warn
                    default: .info
                    }
                    store.log("[\(entry.target)] \(entry.message)", level: level)
                }
                if let last = logs.last {
                    self.latestLogLine = last.message
                }

                if status.phase == .ready {
                    onReady()
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var refreshTask: Task<Void, Never>?

    /// Start periodic refresh of trust ID and block height every 10s
    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.fetchData()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Recreate Veritas with an external spaced connection
    func configureExternal(dataDir: String?, url: String, user: String, password: String) {
        veritas = Veritas(dataDir: dataDir, external: ExternalSpaced(
            url: url,
            user: user,
            password: password
        ), seeds: nil)
    }

    func fetchData() async {
        guard let veritas else { return }
        do {
            let info = try await veritas.getServerInfo()
            serverInfo = info
            tipHeight = "\(info.tipHeight)"
            ready = info.ready

            let anchor = try await veritas.updateTrustId()
            trustAnchor = anchor.trustId
            anchorHeight = anchor.height
        } catch {
            print("[Veritas] fetchData failed: \(error)")
        }
    }
}

// MARK: - Root View

struct ContentView: View {
    @EnvironmentObject var viewModel: VeritasViewModel
    @State private var currentScreen: AppScreen
    @State private var resolveQuery = ""
    @State private var isPastedEntry = false

    init() {
        let hasStartedBefore = UserDefaults.standard.bool(forKey: "veritasHasStarted")
        _currentScreen = State(initialValue: hasStartedBefore ? .syncing : .welcome)
    }

    var body: some View {
        ZStack {
            switch currentScreen {
            case .welcome:
                WelcomeView(
                    viewModel: viewModel,
                    onStartSync: {
                        viewModel.checkAndStart {
                            currentScreen = .syncing
                        }
                    },
                    onSyncStarted: {
                        currentScreen = .syncing
                    },
                    onConnectExternal: {
                        currentScreen = .home
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))

            case .syncing:
                SyncProgressView(
                    viewModel: viewModel,
                    onReady: {
                        Task { await viewModel.fetchData() }
                        currentScreen = .home
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))

            case .home:
                HomeView(
                    viewModel: viewModel,
                    onSearch: {
                        isPastedEntry = false
                        currentScreen = .search
                    },
                    onSettings: { currentScreen = .settings },
                    onImageReceived: { image in
                        Task {
                            let query = await ImageOCR.extractQuery(from: image)
                            print("[Veritas] onImageReceived OCR result: \(query ?? "nil")")
                            if let query, !query.isEmpty {
                                resolveQuery = query
                                isPastedEntry = true
                                currentScreen = .search
                            }
                        }
                    },
                    onTextReceived: { text in
                        resolveQuery = text
                        isPastedEntry = true
                        currentScreen = .search
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))

            case .search:
                SearchView(
                    query: $resolveQuery,
                    isPastedEntry: isPastedEntry,
                    veritas: viewModel.veritas,
                    onBack: { currentScreen = .home }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))

            case .settings:
                SettingsView(
                    viewModel: viewModel,
                    onBack: { currentScreen = .home },
                    onReset: {
                        currentScreen = .welcome
                    }
                )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: currentScreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(viewModel)
        .onAppear {
            // On subsequent launches, auto-start services (skip checkpoint choice)
            if currentScreen == .syncing {
                viewModel.checkAndStart(skipChoice: true)
            }
        }
        .onChange(of: viewModel.pendingShareQuery) { _, newQuery in
            if let query = newQuery, !query.isEmpty {
                resolveQuery = query
                isPastedEntry = true
                currentScreen = .search
                viewModel.pendingShareQuery = nil
            }
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @ObservedObject var viewModel: VeritasViewModel
    @State private var copied = false
    @State private var isDropTargeted = false
    @State private var pasteMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var isCmdHeld = false
    @State private var showServerInfo = false

    var onSearch: () -> Void
    var onSettings: () -> Void
    var onImageReceived: (NSImage) -> Void
    var onTextReceived: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 28)
                .padding(.top, 15)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                Group {
                    if showServerInfo, let info = viewModel.serverInfo {
                        serverInfoCard(info)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        qrSection
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .frame(height: 370)
                .clipped()

                footerCard
            }
            .padding(.horizontal, 40)
            .animation(.easeInOut(duration: 0.25), value: showServerInfo)
        }
        .onAppear {
            viewModel.startRefreshing()
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                    let pb = NSPasteboard.general
                    let types = pb.types ?? []
                    print("[Veritas] Cmd-V detected, pasteboard types: \(types)")

                    if let image = NSImage(pasteboard: pb) {
                        print("[Veritas] Paste: image found on pasteboard, running OCR")
                        onImageReceived(image)
                        return nil
                    } else if let string = pb.string(forType: .string),
                              !string.isEmpty {
                        print("[Veritas] Paste: text found on pasteboard: \(string.prefix(80))")
                        onTextReceived(string)
                        return nil
                    } else {
                        print("[Veritas] Paste: nothing useful on pasteboard")
                    }
                }
                return event
            }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                isCmdHeld = event.modifierFlags.contains(.command)
                return event
            }
        }
        .onDisappear {
            viewModel.stopRefreshing()
            if let monitor = pasteMonitor {
                NSEvent.removeMonitor(monitor)
                pasteMonitor = nil
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
            isCmdHeld = false
        }
    }

    private func loadImage(from providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { image, _ in
                if let nsImage = image as? NSImage {
                    DispatchQueue.main.async { onImageReceived(nsImage) }
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let urlData = data as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil),
                      let nsImage = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { onImageReceived(nsImage) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var qrSection: some View {
        VStack(spacing: 14) {
            Text("SOURCE OF TRUTH")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.38))

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.10),
                                .white.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.05), lineWidth: 0.5)
                            .blur(radius: 6)
                    }

                VStack {
                    Image(nsImage: generateCleanQRCode(from: viewModel.trustAnchor))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 248, height: 248)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.035))
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .overlay {
                if isDropTargeted || isCmdHeld {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)

                        VStack(spacing: 14) {
                            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.on.clipboard.fill")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.white.opacity(0.8))

                            if isDropTargeted {
                                Text("Drop to verify")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7))
                            } else {
                                // Keyboard shortcut pill
                                HStack(spacing: 6) {
                                    Text("⌘")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("V")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.white.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(.white.opacity(0.2), lineWidth: 1)
                                        )
                                )

                                Text("Paste text or image to verify")
                                    .font(.system(size: 12, weight: .regular, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isCmdHeld)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                loadImage(from: providers)
                return true
            }
            .contextMenu {
                Button {
                    if let image = NSImage(pasteboard: NSPasteboard.general) {
                        onImageReceived(image)
                    } else if let string = NSPasteboard.general.string(forType: .string),
                              !string.isEmpty {
                        onTextReceived(string)
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    private var footerCard: some View {
        HStack(spacing: 10) {
            GlowingDot(
                color: viewModel.anchorColor,
                tooltip: "Anchor #\(viewModel.anchorHeight)",
                onTap: { showServerInfo.toggle() }
            )

            Text(compactHash(viewModel.trustAnchor))
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineSpacing(4)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.trustAnchor, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func compactHash(_ hex: String) -> String {
        func groupedLine(_ s: Substring) -> String {
            var groups: [String] = []
            let chars = Array(s)
            for i in stride(from: 0, to: chars.count, by: 4) {
                let end = min(i + 4, chars.count)
                groups.append(String(chars[i..<end]))
            }
            return groups.joined(separator: "  ")
        }
        let line1 = groupedLine(hex.prefix(16))
        let line2 = groupedLine(hex.suffix(16))
        return "\(line1)\n\(line2)"
    }

    private func serverInfoCard(_ info: ServerInfo) -> some View {
        VStack(spacing: 0) {
            Text("DETAILS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Button {
                        showServerInfo = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 14) {
                serverInfoRow("Network", info.network)
                serverInfoRow("Tip Height", "#\(info.tipHeight)")
                serverInfoRow("Anchor", "#\(viewModel.anchorHeight)")
                serverInfoRow("Tip Hash", compactTipHash(info.tipHash), copyValue: info.tipHash)
                serverInfoRow("Blocks", "\(info.chainBlocks)")
                serverInfoRow("Headers", "\(info.chainHeaders)")
                serverInfoRow("Progress", "\(Int(info.progress * 100))%")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func compactTipHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return "\(hash.prefix(4))…\(hash.suffix(8))"
    }

    private func serverInfoRow(_ label: String, _ value: String, copyValue: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .textSelection(.enabled)
            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.2))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @ObservedObject var viewModel: VeritasViewModel
    var onStartSync: () -> Void
    var onSyncStarted: () -> Void
    var onConnectExternal: () -> Void

    @State private var showAdvanced = false
    @State private var spacedUrl = ""
    @State private var spacedUser = ""
    @State private var spacedPass = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let checkpoint = viewModel.pendingCheckpoint {
                // Checkpoint choice - a non-hardcoded checkpoint was found
                checkpointChoiceView(checkpoint)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if viewModel.checkpointLoading {
                // Checking for checkpoints
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for checkpoints…")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
            } else {
                // Default welcome screen
                welcomeContent
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.pendingCheckpoint != nil)
        .animation(.easeInOut(duration: 0.25), value: viewModel.checkpointLoading)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            // Logo area
            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.white.opacity(0.5))

                Text("VERITAS")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.6))

                Text("Veritas verifies spaces handles\nlocally on your device.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer().frame(height: 40)

            // Start Sync button
            Button(action: onStartSync) {
                HStack(spacing: 8) {
                    Text("Start Verification")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)

            Spacer().frame(height: 20)

            // Advanced Options
            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Advanced Options")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.25))
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    VStack(spacing: 10) {
                        advancedField(title: "URL", placeholder: "http://127.0.0.1:12888", text: $spacedUrl)
                        advancedField(title: "User", placeholder: "test", text: $spacedUser)
                        SecureField("", text: $spacedPass, prompt:
                            Text("Password")
                                .foregroundStyle(.white.opacity(0.18))
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        }

                        Button {
                            let appSupport = FileManager.default.urls(
                                for: .applicationSupportDirectory, in: .userDomainMask
                            ).first!
                            let dataDirURL = appSupport.appendingPathComponent("Veritas")
                            try? FileManager.default.createDirectory(at: dataDirURL, withIntermediateDirectories: true)
                            viewModel.configureExternal(
                                dataDir: dataDirURL.path,
                                url: spacedUrl,
                                user: spacedUser,
                                password: spacedPass
                            )
                            viewModel.veritas?.skipCheckpoint()
                            viewModel.startServices()
                            onConnectExternal()
                        } label: {
                            Text("Connect")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(spacedUrl.isEmpty)
                    }
                    .padding(.horizontal, 40)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func checkpointChoiceView(_ checkpoint: CheckpointInfo) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.yellow.opacity(0.6))

            VStack(spacing: 8) {
                Text("Checkpoint Available")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))

                Text("A newer checkpoint was found on the server.\nThis checkpoint is not hardcoded in the software.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Checkpoint details
            VStack(spacing: 6) {
                if let latest = checkpoint.latest {
                    checkpointDetailRow("Block", "#\(latest.height)")
                    checkpointDetailRow("Hash", latest.blockHash)
                    checkpointDetailRow("Digest", latest.digest)
                }
                if checkpoint.hardcodedHeight > 0 {
                    checkpointDetailRow("Hardcoded", "#\(checkpoint.hardcodedHeight)")
                }
            }
            .padding(12)
            .background(.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 30)

            // Choice buttons
            VStack(spacing: 10) {
                Button {
                    viewModel.startWithServerCheckpoint(checkpoint)
                    onSyncStarted()
                } label: {
                    Text("Use Server Checkpoint")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                if checkpoint.hardcodedHeight > 0 {
                    Button {
                        viewModel.startWithHardcodedCheckpoint()
                        onSyncStarted()
                    } label: {
                        Text("Use Hardcoded Checkpoint (#\(checkpoint.hardcodedHeight))")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.startFromScratch()
                    onSyncStarted()
                } label: {
                    Text("Sync from Scratch")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 40)
        }
    }

    private func checkpointDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func advancedField(title: String, placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt:
            Text(placeholder)
                .foregroundStyle(.white.opacity(0.18))
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - Sync Progress View

struct SyncProgressView: View {
    @ObservedObject var viewModel: VeritasViewModel
    var onReady: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let error = viewModel.startError {
                // Error state
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.red.opacity(0.6))

                    Text(error.localizedDescription)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 40)

                    HStack(spacing: 12) {
                        Button {
                            viewModel.startError = nil
                            viewModel.checkAndStart(skipChoice: true)
                        } label: {
                            Text("Retry")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            viewModel.startError = nil
                            viewModel.veritas?.skipCheckpoint()
                            viewModel.startServices()
                        } label: {
                            Text("Start from Scratch")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Sync progress
                VStack(spacing: 20) {
                    if let phase = viewModel.syncPhase {
                        switch phase {
                        case .downloadingCheckpoint, .syncingHeaders, .syncingBlocks:
                            VStack(spacing: 12) {
                                if viewModel.syncProgress > 0 {
                                    // Determinate progress
                                    ProgressView(value: viewModel.syncProgress)
                                        .progressViewStyle(.linear)
                                        .tint(.white.opacity(0.4))
                                        .frame(width: 200)
                                } else {
                                    // Backend hasn't reported progress yet - show indeterminate
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(viewModel.syncMessage)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.35))

                                if viewModel.syncProgress > 0 && viewModel.syncProgress < 1.0 {
                                    Text("\(Int(viewModel.syncProgress * 100))%")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.2))
                                }
                            }

                        case .ready:
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 32, weight: .thin))
                                .foregroundStyle(.green.opacity(0.6))
                            Text("Ready")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))

                        default:
                            // Indeterminate phases: verifying, extracting, starting
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.syncMessage)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    } else {
                        // No status yet
                        ProgressView()
                            .controlSize(.small)
                        Text("Initializing...")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }

            Spacer()

            // Detach log button
            HStack {
                Spacer()
                Button {
                    LogWindowController.shared.showWindow()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.startPolling {
                onReady()
            }
        }
        .onDisappear {
            viewModel.stopPolling()
        }
    }


}

// MARK: - Helpers

private func parseRecords(_ data: Data?) -> [ParsedRecord] {
    guard let data, !data.isEmpty else { return [] }
    let rs = RecordSet(data: data)
    return (try? rs.unpack()) ?? []
}

private func trimNoteId(_ noteId: String) -> String {
    guard noteId.count > 16 else { return noteId }
    return "\(noteId.prefix(8))…\(noteId.suffix(8))"
}

private func cleanMessageContent(_ content: String) -> String {
    content.replacingOccurrences(of: "#veritas", with: "")
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func relativeTime(_ timestamp: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let interval = Date().timeIntervalSince(date)
    let seconds = Int(interval)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    if seconds < 604800 { return "\(seconds / 86400)d ago" }
    return "\(seconds / 604800)w ago"
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Search View

struct SearchView: View {
    @Binding var query: String
    var isPastedEntry: Bool
    var veritas: Veritas?
    var onBack: () -> Void
    @EnvironmentObject private var viewModel: VeritasViewModel

    @State private var zone: Zone?
    @State private var records: [ParsedRecord] = []
    @State private var nostrMessages: [NostrMessage] = []
    @State private var isLoading = false
    @State private var isSearchingNostr = false
    @State private var errorMessage: String?
    @State private var showRaw = false
    @State private var showNostrDetail = false
    @State private var copiedKey: String?

    var body: some View {
        Group {
            if showNostrDetail {
                NostrMessageDetailView(
                    messages: nostrMessages,
                    handle: zone?.handle ?? "",
                    onDismiss: {
                        withAnimation(.spring(duration: 0.3)) {
                            showNostrDetail = false
                        }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    // Header with back button and search field
                    searchHeader

                    // Content
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Resolving...")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer()
                    } else if let error = errorMessage {
                        errorView(error)
                    } else if let zone {
                        zoneView(zone)
                    } else {
                        Spacer()
                        Text("Type a handle to resolve")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.2))
                        Spacer()
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: showNostrDetail)
        .onAppear {
            if isPastedEntry && !query.isEmpty {
                performSearch()
            }
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button(action: {
                zone = nil
                records = []
                nostrMessages = []
                errorMessage = nil
                onBack()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))

                TextField("", text: $query, prompt:
                    Text("alice@bitcoin")
                        .foregroundStyle(.white.opacity(0.22))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .onSubmit { performSearch() }

                if !query.isEmpty {
                    Button {
                        query = ""
                        zone = nil
                        records = []
                        nostrMessages = []
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 16)
    }

    // MARK: - Search Logic

    /// Extract a spaces handle (e.g. `@buffrr`, `alice@bitcoin`) from freeform text
    private func extractHandle(from text: String) -> String? {
        // Match @name or name@name patterns (dots allowed in names)
        let pattern = #"(?:^|(?<=\s))(@[a-zA-Z0-9._-]+|[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Remove the handle from text to get the plain message content for nostr search
    private func stripHandle(from text: String, handle: String) -> String {
        text.replacingOccurrences(of: handle, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract npub and relay URLs from parsed records.
    /// Nostr data comes as an `.addr` record: first value is the npub, rest are relay URLs.
    private func extractNostrInfo(from records: [ParsedRecord]) -> (npub: String?, relays: [String]) {
        for record in records {
            if case .addr(let key, let values) = record,
               key.lowercased() == "nostr",
               let first = values.first {
                return (first, Array(values.dropFirst()))
            }
        }
        return (nil, [])
    }

    private func performSearch() {
        guard let veritas, !query.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        zone = nil
        records = []
        nostrMessages = []
        isSearchingNostr = false

        // If pasted text, extract the handle from it; otherwise use query directly
        let handle: String
        let originalText = query
        if isPastedEntry {
            guard let extracted = extractHandle(from: query) else {
                errorMessage = "No handle found in text"
                isLoading = false
                return
            }
            handle = extracted
        } else {
            handle = query
        }

        Task {
            do {
                // Step 1: Resolve the handle (fast)
                guard let resolved = try await veritas.resolve(handle: handle) else {
                    errorMessage = "Name not found"
                    isLoading = false
                    return
                }
                zone = resolved
                let data = resolved.records ?? resolved.fallbackRecords
                let parsedRecords = parseRecords(data)
                records = parsedRecords
                isLoading = false

                // Step 2: If pasted entry, extract npub + relays and search for nostr messages
                if isPastedEntry {
                    let nostrInfo = extractNostrInfo(from: parsedRecords)

                    if let npub = nostrInfo.npub {
                        let searchText = stripHandle(from: originalText, handle: handle)
                        isSearchingNostr = true
                        Task {
                            do {
                                let messages = try await veritas.findNostr(
                                    npub: npub,
                                    relays: nostrInfo.relays,
                                    text: searchText.isEmpty ? nil : searchText
                                )
                                print("[Veritas] findNostr returned \(messages.count) messages for npub=\(npub)")
                                if !messages.isEmpty {
                                    withAnimation(.spring(duration: 0.5)) {
                                        nostrMessages = messages
                                        showNostrDetail = true
                                        viewModel.showNostrGlow = true
                                    }
                                }
                            } catch {
                                print("[Veritas] findNostr failed: \(error)")
                            }
                            isSearchingNostr = false
                        }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Zone View

    private func zoneView(_ zone: Zone) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Handle + badge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(zone.handle)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        badgeView(zone.badge)
                    }
                    Text(zone.sovereignty.capitalized)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }

                // Nostr message card - appears under the name
                if !nostrMessages.isEmpty {
                    nostrMessageCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Records (no heading)
                if !records.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(displayRecords.enumerated()), id: \.offset) { _, record in
                            recordRow(record)
                        }
                    }
                }

                // More (raw data + export cert)
                moreSection(zone)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Badge

    @ViewBuilder
    private func badgeView(_ badge: String) -> some View {
        switch badge {
        case "orange":
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .shadow(color: .orange.opacity(0.4), radius: 3)
        case "unverified":
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14))
                .foregroundStyle(.gray.opacity(0.4))
        default:
            EmptyView()
        }
    }

    // MARK: - Records

    private var displayRecords: [ParsedRecord] {
        records.filter { record in
            switch record {
            case .txt, .addr, .blob: return true
            case .seq, .sig, .malformed, .unknown: return false
            }
        }
    }

    private func recordRow(_ record: ParsedRecord) -> some View {
        Group {
            switch record {
            case .txt(let key, let values):
                // TXT is now multi-value
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 8) {
                            recordIcon(key)
                                .frame(width: 14)
                                .opacity(index == 0 ? 1 : 0)

                            Text(index == 0 ? key.uppercased() : "")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: 44, alignment: .leading)

                            Text(value)
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(index == 0 ? 0.55 : 0.35))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button {
                                handleRecordTap(key: key, value: value)
                            } label: {
                                Image(systemName: copiedKey == "\(key)_\(index)" ? "checkmark" : recordAction(key))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

            case .addr(let key, let values):
                // ADDR: first value is the address, rest are relay URLs (for nostr)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 8) {
                            recordIcon(key)
                                .frame(width: 14)
                                .opacity(index == 0 ? 1 : 0)

                            Text(index == 0 ? key.uppercased() : "RELAY")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: 44, alignment: .leading)

                            Text(value)
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(index == 0 ? 0.55 : 0.35))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button {
                                handleRecordTap(key: index == 0 ? key : "relay", value: value)
                            } label: {
                                Image(systemName: copiedKey == "\(key)_\(index)" ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

            case .blob(let key, let value):
                if key == "avatar", let image = NSImage(data: value) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 14)

                        Text(key.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))

                        Text("\(value.count) bytes")
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func recordIcon(_ key: String) -> some View {
        switch key.lowercased() {
        case "btc":
            Image(systemName: "bitcoinsign.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange.opacity(0.6))
        case "nostr", "npub":
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.purple.opacity(0.6))
        case "relay":
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.purple.opacity(0.4))
        case "email":
            Image(systemName: "envelope")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue.opacity(0.6))
        case "web":
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.6))
        default:
            Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func recordAction(_ key: String) -> String {
        switch key.lowercased() {
        case "web": return "arrow.up.right"
        case "email": return "envelope"
        default: return "doc.on.doc"
        }
    }

    private func handleRecordTap(key: String, value: String) {
        switch key.lowercased() {
        case "email":
            if let url = URL(string: "mailto:\(value)") {
                NSWorkspace.shared.open(url)
            }
        case "web":
            var urlString = value
            if !urlString.hasPrefix("http") { urlString = "https://\(urlString)" }
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        default:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        copiedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedKey == key { copiedKey = nil }
        }
    }

    // MARK: - Nostr Message Card (compact, shimmering)

    private var nostrMessageCard: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) {
                showNostrDetail = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green.opacity(0.6))

                if let msg = nostrMessages.first {
                    Text(cleanMessageContent(msg.content))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.2))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.green.opacity(0.03))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.green.opacity(0.18), lineWidth: 1)
                    ShimmerView()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - More (Raw Data + Export)

    private func moreSection(_ zone: Zone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showRaw.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("More")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.25))
            }
            .buttonStyle(.plain)

            if showRaw {
                VStack(alignment: .leading, spacing: 6) {
                    rawRow("Canonical", zone.canonical)
                    rawRow("Anchor", "Block #\(zone.anchor)")
                    rawRow("Sovereignty", zone.sovereignty)
                    rawRow("Script", zone.scriptPubkey.hexString)

                    if case .exists(let sr, _, let rh, let bh, let receipt) = zone.commitment {
                        Text("Commitment")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 4)
                        rawRow("State root", sr.hexString)
                        rawRow("Rolling hash", rh.hexString)
                        rawRow("Block", "#\(bh)")
                        if let receipt {
                            rawRow("ZK receipt", receipt.hexString)
                        }
                    }

                    if case .exists(let sp, _, _) = zone.delegate {
                        Text("Delegate")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 4)
                        rawRow("Script", sp.hexString)
                    }

                    // Nostr message search status
                    if isSearchingNostr {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Searching for verified messages...")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .padding(.top, 4)
                    }

                    // Export Certificate
                    Button {
                        exportCertificate(handle: zone.handle)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 10, weight: .medium))
                            Text("Export Certificate")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
    }

    private func rawRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.25))
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func exportCertificate(handle: String) {
        guard let veritas else { return }
        Task {
            do {
                let certData = try await veritas.exportCertificate(handle: handle)
                await MainActor.run {
                    let panel = NSSavePanel()
                    let safeHandle = handle.replacingOccurrences(of: "/", with: "_")
                    panel.nameFieldStringValue = "\(safeHandle).spacecert"
                    panel.allowedContentTypes = [.data]
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            try certData.write(to: url)
                        } catch {
                            print("[Veritas] Failed to write certificate: \(error)")
                        }
                    }
                }
            } catch {
                print("[Veritas] Export certificate failed: \(error)")
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.15))
            Text(error)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
    }
}

// MARK: - Shimmer Effect

struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: max(0, phase - 0.3)),
                    .init(color: .green.opacity(0.08), location: phase),
                    .init(color: .clear, location: min(1, phase + 0.3)),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: false)
            ) {
                phase = 2
            }
        }
    }
}

// MARK: - Verified Checkmark Seal

struct VerifiedCheckmarkSeal: View {
    @State private var glowOpacity: Double = 0.15

    var body: some View {
        ZStack {
            // Glow ring - fades in and out
            Circle()
                .stroke(.green.opacity(0.35), lineWidth: 2)
                .frame(width: 34, height: 34)
                .opacity(glowOpacity)

            // Base circle
            Circle()
                .stroke(.green.opacity(0.12), lineWidth: 1)
                .frame(width: 34, height: 34)

            // Checkmark
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green.opacity(0.7))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glowOpacity = 1
            }
        }
    }
}

// MARK: - Quote Mark Shapes

struct OpenQuoteMark: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 24
            let scaleY = size.height / 18
            var path1 = Path()
            path1.move(to: CGPoint(x: 14.017 * scaleX, y: 18 * scaleY))
            path1.addLine(to: CGPoint(x: 14.017 * scaleX, y: 10.609 * scaleY))
            path1.addCurve(
                to: CGPoint(x: 23 * scaleX, y: 0),
                control1: CGPoint(x: 14.017 * scaleX, y: 4.905 * scaleY),
                control2: CGPoint(x: 17.748 * scaleX, y: 1.039 * scaleY)
            )
            path1.addLine(to: CGPoint(x: 23.995 * scaleX, y: 2.151 * scaleY))
            path1.addCurve(
                to: CGPoint(x: 20 * scaleX, y: 8 * scaleY),
                control1: CGPoint(x: 21.563 * scaleX, y: 3.068 * scaleY),
                control2: CGPoint(x: 20 * scaleX, y: 5.789 * scaleY)
            )
            path1.addLine(to: CGPoint(x: 24 * scaleX, y: 8 * scaleY))
            path1.addLine(to: CGPoint(x: 24 * scaleX, y: 18 * scaleY))
            path1.closeSubpath()

            var path2 = Path()
            path2.move(to: CGPoint(x: 0, y: 18 * scaleY))
            path2.addLine(to: CGPoint(x: 0, y: 10.609 * scaleY))
            path2.addCurve(
                to: CGPoint(x: 9 * scaleX, y: 0),
                control1: CGPoint(x: 0, y: 4.905 * scaleY),
                control2: CGPoint(x: 3.748 * scaleX, y: 1.038 * scaleY)
            )
            path2.addLine(to: CGPoint(x: 9.996 * scaleX, y: 2.151 * scaleY))
            path2.addCurve(
                to: CGPoint(x: 6 * scaleX, y: 8 * scaleY),
                control1: CGPoint(x: 7.563 * scaleX, y: 3.068 * scaleY),
                control2: CGPoint(x: 6 * scaleX, y: 5.789 * scaleY)
            )
            path2.addLine(to: CGPoint(x: 9.983 * scaleX, y: 8 * scaleY))
            path2.addLine(to: CGPoint(x: 9.983 * scaleX, y: 18 * scaleY))
            path2.closeSubpath()

            context.fill(path1, with: .color(.green.opacity(0.25)))
            context.fill(path2, with: .color(.green.opacity(0.25)))
        }
    }
}

struct CloseQuoteMark: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 24
            let scaleY = size.height / 18
            var path1 = Path()
            path1.move(to: CGPoint(x: 9.983 * scaleX, y: 0))
            path1.addLine(to: CGPoint(x: 9.983 * scaleX, y: 7.391 * scaleY))
            path1.addCurve(
                to: CGPoint(x: 1 * scaleX, y: 18 * scaleY),
                control1: CGPoint(x: 9.983 * scaleX, y: 13.095 * scaleY),
                control2: CGPoint(x: 6.252 * scaleX, y: 16.961 * scaleY)
            )
            path1.addLine(to: CGPoint(x: 0.005 * scaleX, y: 15.849 * scaleY))
            path1.addCurve(
                to: CGPoint(x: 4 * scaleX, y: 10 * scaleY),
                control1: CGPoint(x: 2.437 * scaleX, y: 14.932 * scaleY),
                control2: CGPoint(x: 4 * scaleX, y: 12.211 * scaleY)
            )
            path1.addLine(to: CGPoint(x: 0, y: 10 * scaleY))
            path1.addLine(to: CGPoint(x: 0, y: 0))
            path1.closeSubpath()

            var path2 = Path()
            path2.move(to: CGPoint(x: 24 * scaleX, y: 0))
            path2.addLine(to: CGPoint(x: 24 * scaleX, y: 7.391 * scaleY))
            path2.addCurve(
                to: CGPoint(x: 15 * scaleX, y: 18 * scaleY),
                control1: CGPoint(x: 24 * scaleX, y: 13.095 * scaleY),
                control2: CGPoint(x: 20.252 * scaleX, y: 16.962 * scaleY)
            )
            path2.addLine(to: CGPoint(x: 14.004 * scaleX, y: 15.849 * scaleY))
            path2.addCurve(
                to: CGPoint(x: 18 * scaleX, y: 10 * scaleY),
                control1: CGPoint(x: 16.437 * scaleX, y: 14.932 * scaleY),
                control2: CGPoint(x: 18 * scaleX, y: 12.211 * scaleY)
            )
            path2.addLine(to: CGPoint(x: 14.017 * scaleX, y: 0))
            path2.addLine(to: CGPoint(x: 24 * scaleX, y: 0))
            path2.closeSubpath()

            context.fill(path1, with: .color(.green.opacity(0.25)))
            context.fill(path2, with: .color(.green.opacity(0.25)))
        }
    }
}

// MARK: - Nostr Message Detail View

struct NostrMessageDetailView: View {
    let messages: [NostrMessage]
    let handle: String
    var onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var copyHovered = false

    private var primaryMessage: NostrMessage { messages[selectedIndex] }

    var body: some View {
        VStack(spacing: 0) {
            // Header - back button + checkmark seal centered
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 6) {
                    VerifiedCheckmarkSeal()

                    Text("Verified")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.green.opacity(0.5))
                        .tracking(1)
                        .textCase(.uppercase)
                }

                Spacer()

                Color.clear.frame(width: 28, height: 28)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Message content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Open quote + message text
                    HStack(alignment: .top, spacing: 10) {
                        OpenQuoteMark()
                            .frame(width: 11, height: 8)
                            .padding(.top, 5)

                        Text(cleanMessageContent(primaryMessage.content))
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    // Close quote aligned to trailing
                    HStack {
                        Spacer()
                        CloseQuoteMark()
                            .frame(width: 11, height: 8)
                    }
                    .padding(.top, 4)

                    // Metadata - below a faint divider
                    Rectangle()
                        .fill(.white.opacity(0.04))
                        .frame(height: 1)
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                    HStack(spacing: 8) {
                        Text(relativeTime(primaryMessage.createdAt))
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.2))

                        if !primaryMessage.noteId.isEmpty {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.1))
                            Text(trimNoteId(primaryMessage.noteId))
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.15))
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cleanMessageContent(primaryMessage.content), forType: .string)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                                Text("Copy")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(copyHovered ? .green.opacity(0.6) : .white.opacity(0.2))
                        }
                        .buttonStyle(.plain)
                        .onHover { copyHovered = $0 }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }

            // Other messages at the bottom
            if messages.count > 1 {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.white.opacity(0.04))
                        .frame(height: 1)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(messages.enumerated()), id: \.offset) { index, msg in
                                if index != selectedIndex {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedIndex = index
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(cleanMessageContent(msg.content))
                                                .font(.system(size: 10, weight: .regular))
                                                .foregroundStyle(.white.opacity(0.4))
                                                .lineLimit(2)
                                                .truncationMode(.tail)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(relativeTime(msg.createdAt))
                                                .font(.system(size: 8, weight: .regular, design: .rounded))
                                                .foregroundStyle(.white.opacity(0.18))
                                        }
                                        .padding(10)
                                        .frame(width: 200)
                                        .background(.white.opacity(0.03))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(.white.opacity(0.05), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Log Store

@MainActor
class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published var entries: [AppLogEntry] = []

    struct AppLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: Level

        enum Level: String {
            case info = "INFO"
            case warn = "WARN"
            case error = "ERR "
        }
    }

    func log(_ message: String, level: AppLogEntry.Level = .info) {
        entries.append(AppLogEntry(timestamp: Date(), message: message, level: level))
        if entries.count > 500 { entries.removeFirst() }
    }

    private init() {}
}

// MARK: - Log Window

class LogWindowController {
    static let shared = LogWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let window = window {
            window.setContentSize(NSSize(width: 800, height: 500))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let logView = LogWindowView()
        let hostingController = NSHostingController(rootView: logView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Veritas Logs"
        win.contentViewController = hostingController
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }
}

struct LogWindowView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var searchText = ""

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var filteredEntries: [LogStore.AppLogEntry] {
        if searchText.isEmpty { return store.entries }
        return store.entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText) ||
            $0.level.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                    TextField("Filter logs…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("\(filteredEntries.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                Spacer()

                Button("Clear") {
                    store.entries.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Button("Copy All") {
                    let text = filteredEntries.map { entry in
                        "\(dateFormatter.string(from: entry.timestamp)) [\(entry.level.rawValue)] \(entry.message)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log entries - selectable text via NSTextView
            SelectableLogTextView(entries: filteredEntries, dateFormatter: dateFormatter)
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}

// MARK: - Selectable Log Text View (NSTextView wrapper)

struct SelectableLogTextView: NSViewRepresentable {
    let entries: [LogStore.AppLogEntry]
    let dateFormatter: DateFormatter

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // Use finder bar for search
        textView.isIncrementalSearchingEnabled = true
        textView.usesFindBar = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let attributed = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: 70),
            NSTextTab(textAlignment: .left, location: 110),
        ]

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let dimColor = NSColor.secondaryLabelColor

        for (i, entry) in entries.enumerated() {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let levelColor: NSColor = switch entry.level {
            case .info: .secondaryLabelColor
            case .warn: .systemOrange
            case .error: .systemRed
            }

            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: timestamp, attributes: [
                .font: monoFont,
                .foregroundColor: dimColor,
                .paragraphStyle: paragraphStyle,
            ]))
            line.append(NSAttributedString(string: "\t", attributes: [.font: monoFont]))
            line.append(NSAttributedString(string: entry.level.rawValue, attributes: [
                .font: monoFont,
                .foregroundColor: levelColor,
            ]))
            line.append(NSAttributedString(string: "\t", attributes: [.font: monoFont]))
            line.append(NSAttributedString(string: entry.message, attributes: [
                .font: monoFont,
                .foregroundColor: NSColor.labelColor,
            ]))
            if i < entries.count - 1 {
                line.append(NSAttributedString(string: "\n"))
            }
            attributed.append(line)
        }

        textView.textStorage?.setAttributedString(attributed)

        // Auto-scroll to bottom
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: VeritasViewModel
    var onBack: () -> Void
    var onReset: () -> Void

    @State private var showResetConfirm = false
    @State private var copiedRpc = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Settings")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 20)

            VStack(spacing: 14) {
                // View Logs
                Button {
                    LogWindowController.shared.showWindow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .medium))
                        Text("View Logs")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                // RPC Credentials
                if let creds = viewModel.veritas?.rpcCredentials() {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "key")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("RPC Credentials")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                            Button {
                                let text = "\(creds.user):\(creds.password)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                copiedRpc = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedRpc = false
                                }
                            } label: {
                                Text(copiedRpc ? "Copied" : "Copy")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("User")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 32, alignment: .trailing)
                                Text(creds.user)
                                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .textSelection(.enabled)
                            }
                            HStack(spacing: 6) {
                                Text("Pass")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 32, alignment: .trailing)
                                Text(creds.password)
                                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    }
                }

                // Erase & Start Over
                Button {
                    showResetConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                        Text("Erase All Data & Start Over")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Spacer()
                    }
                    .foregroundStyle(.red.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                if showResetConfirm {
                    VStack(spacing: 10) {
                        Text("This will remove all local data and return to setup. This action cannot be undone.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        HStack(spacing: 12) {
                            Button {
                                showResetConfirm = false
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Button {
                                performReset()
                            } label: {
                                Text("Erase")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(.red.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.2), value: showResetConfirm)

            Spacer()

            // Version info
            Text("Veritas v0.1.0")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.12))
                .padding(.bottom, 16)
        }
    }

    private func performReset() {
        // Stop polling and refresh tasks first
        viewModel.stopPolling()
        viewModel.stopRefreshing()

        // Signal services to shut down
        viewModel.veritas?.stop()

        // Give services time to release file handles, then delete data
        Task {
            // Wait for services to wind down
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Remove data directory
            if let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first {
                let dataDir = appSupport.appendingPathComponent("Veritas")
                do {
                    try FileManager.default.removeItem(at: dataDir)
                } catch {
                    print("[Veritas] Failed to remove data directory: \(error)")
                    // Retry after another short wait
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? FileManager.default.removeItem(at: dataDir)
                }
            }

            await MainActor.run {
                // Clear started flag
                UserDefaults.standard.removeObject(forKey: "veritasHasStarted")

                // Reset view model state
                viewModel.trustAnchor = ""
                viewModel.anchorHeight = 0
                viewModel.tipHeight = ""
                viewModel.serverInfo = nil
                viewModel.ready = false
                viewModel.syncPhase = nil
                viewModel.syncProgress = 0
                viewModel.syncMessage = ""
                viewModel.startError = nil
                viewModel.pendingCheckpoint = nil

                // Create a fresh Veritas instance
                viewModel.reconfigure()

                onReset()
            }
        }
    }
}

// MARK: - Shared Components

struct GlowingDot: View {
    var color: Color = .green
    var tooltip: String? = nil
    var onTap: (() -> Void)? = nil
    @State private var glowOpacity: Double = 0.3
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(glowOpacity))
                .frame(width: 12, height: 12)
                .blur(radius: 3)

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 16, height: 16)
        .scaleEffect(isHovered ? 1.4 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .padding(12)
        .contentShape(Rectangle())
        .padding(-12)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip ?? "")
        .onTapGesture {
            onTap?()
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.6)
                .repeatForever(autoreverses: true)
            ) {
                glowOpacity = 0.7
            }
        }
    }
}

// MARK: - QR Code Generation

private func generateCleanQRCode(from string: String) -> NSImage {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage else {
        return NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Error") ?? NSImage()
    }

    let scaleX: CGFloat = 12
    let scaleY: CGFloat = 12
    let transformed = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
        return NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Error") ?? NSImage()
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
}

// MARK: - Preview

#Preview {
    ContentView()
}
