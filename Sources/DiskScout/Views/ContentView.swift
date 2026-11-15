import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(sizer: model.sizer, cleaner: model.cleaner, trash: model.trash, devices: model.devices)
                .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 300)
        } detail: {
            detailArea
                .layoutContained()
                .navigationTitle("DiskScout")
                .toolbar { ToolbarItems() }
                .inspector(isPresented: $model.showInspector) {
                    Group {
                        if model.showingPersonalData {
                            BackupInspector()
                        } else if model.selectedDeviceID != nil {
                            DeviceInspectorPane()
                        } else {
                            InspectorPane(engine: model.engine)
                        }
                    }
                    .layoutContained()
                    .inspectorColumnWidth(min: 250, ideal: 285, max: 380)
                }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: model.showingPersonalData ? DeviceTab.backup.searchPrompt : (model.selectedDevice?.tab.searchPrompt ?? "Filter this folder"))
        .sheet(item: $model.trashPlan) { plan in
            ReviewSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.deviceDeletePlan) { plan in
            DeviceDeleteSheet(plan: plan).environmentObject(model)
        }
        .sheet(isPresented: $model.showWelcome) {
            WelcomeView().environmentObject(model)
        }
        .sheet(isPresented: $model.showFullDiskAccessGuide) {
            FullDiskAccessGuide().environmentObject(model)
        }
        .onAppear { model.onAppear() }
        .onChange(of: model.engine.isScanning) { _, scanning in
            if !scanning { model.refreshDisk(); model.recheckFullDiskAccess() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
            model.refreshDisk()
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if model.showingPersonalData {
            VStack(spacing: 0) {
                PersonalDataView()
                Divider()
                StatusBar()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else if model.selectedDeviceID != nil {
            VStack(spacing: 0) {
                if let device = model.selectedDevice {
                    DeviceDetail(device: device).id(device.id)
                } else {
                    DeviceDisconnectedView()
                }
                Divider()
                StatusBar()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            detail
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HeroCard(engine: model.engine, cleaner: model.cleaner, info: model.diskInfo)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if !model.hasFullDiskAccess && !model.fdaBannerDismissed {
                FullDiskAccessBanner()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ModeBar(engine: model.engine, settings: model.settings)
            Divider()
            GeometryReader { geo in
                ZStack {
                    content
                        .id(model.mode)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
                .animation(.snappyUI, value: model.mode)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(alignment: .bottom) {
                    if let toast = model.toast {
                        ToastView(toast: toast)
                    }
                }
            }
            Divider()
            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .smartClean:
            SmartCleanView(cleaner: model.cleaner)
        case .browse:
            if model.engine.isScanning && model.engine.root == nil {
                ScanningView(engine: model.engine)
            } else if model.engine.root != nil {
                BrowseView(engine: model.engine)
            } else {
                noScan
            }
        case .treemap:
            if model.engine.isScanning && model.engine.root == nil {
                ScanningView(engine: model.engine)
            } else if model.engine.root != nil {
                TreemapView(engine: model.engine, settings: model.settings)
            } else {
                noScan
            }
        case .duplicates:
            if model.engine.root != nil { DuplicatesView(engine: model.engine) } else { noScan }
        case .finder:
            if model.engine.root != nil { FinderView(engine: model.engine) } else { noScan }
        }
    }

    @ViewBuilder
    private var noScan: some View {
        if let err = model.engine.lastError {
            EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't scan", message: err, tint: SafetyLevel.caution.color,
                       action: ("Open Privacy Settings", { model.openFullDiskAccessSettings() }))
        } else {
            EmptyState(systemImage: "folder.badge.questionmark", title: "Pick something to scan",
                       message: "Choose a location in the sidebar, or scan any folder. Smart Clean doesn't need a scan.",
                       action: ("Choose Folder…", { model.chooseFolder() }))
        }
    }
}

// MARK: - Toolbar

struct ToolbarItems: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.engine.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.macScanHidden || !model.engine.canGoBack)
                .help("Back")
            Button { model.engine.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(model.macScanHidden || !model.engine.canGoForward)
                .help("Forward")
            Button { model.engine.goUp() } label: { Image(systemName: "arrow.up.to.line") }
                .disabled(model.macScanHidden || model.engine.current?.parent == nil)
                .help("Enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFolder() } label: { Label("Scan Folder…", systemImage: "folder.badge.plus") }
                .help("Scan any folder (⌘O)")
            if model.engine.isScanning || model.cleaner.isScanning {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                    .help("Stop scanning")
            } else {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.engine.root == nil && model.mode != .smartClean && model.selectedDevice == nil)
                    .help("Rescan (⌘R)")
            }
            Button { model.quickLookSelection() } label: { Label("Quick Look", systemImage: "eye") }
                .disabled(model.selectedDeviceID != nil || model.showingPersonalData || (model.selection.isEmpty && model.cleanupInspected == nil))
                .help("Quick Look (Space)")
            Button { model.revealSelection() } label: { Label("Show in Finder", systemImage: "magnifyingglass") }
                .disabled(model.selectedDeviceID != nil || model.showingPersonalData || (model.engine.current == nil && model.cleanupInspected == nil))
                .help("Show in Finder")
            if let device = model.selectedDevice {
                DeviceTrashToolbarButton(device: device)
            } else {
                Button { model.requestTrashSelection() } label: { Label("Move to Trash", systemImage: "trash") }
                    .disabled(model.showingPersonalData || (model.selection.isEmpty && model.selectedCleanupIDs.isEmpty))
                    .help("Move selection to Trash (⌘⌫)")
            }
            Button { withAnimation(.snappyUI) { model.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Toggle inspector (⌥⌘I)")
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.showingPersonalData {
                Image(systemName: "hand.raised.fill").foregroundStyle(.tint)
                Text("Messages & Notes · read on this Mac, never uploaded")
            } else if let device = model.selectedDevice {
                DeviceStatusText(device: device)
            } else if model.engine.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning · \(model.engine.scannedItems.formatted()) items · \(model.engine.scannedBytes.bytesString)")
                    .monospacedDigit()
            } else if model.mode == .smartClean {
                Image(systemName: "sparkles").foregroundStyle(QuickLocations.smartClean.color)
                if model.cleaner.isScanning {
                    Text("Checking \(model.cleaner.currentCategory?.rawValue ?? "for junk")…")
                } else if model.cleaner.hasScanned {
                    Text("\(model.cleaner.items.count) items · \(model.cleaner.totalAll.bytesString) reclaimable · \(model.cleaner.totalSafe.bytesString) safe")
                } else {
                    Text("Ready")
                }
            } else if let root = model.engine.root {
                Image(systemName: "internaldrive").foregroundStyle(.tint)
                Text("\(root.itemCount.formatted()) items").monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(root.size.bytesString).fontWeight(.semibold)
                if model.engine.elapsed > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("scanned in \(String(format: "%.1f", model.engine.elapsed))s")
                }
                if model.engine.unreadableCount > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Button {
                        model.openFullDiskAccessSettings()
                    } label: {
                        Label("\(model.engine.unreadableCount) folders unreadable", systemImage: "lock.fill")
                            .foregroundStyle(SafetyLevel.caution.color)
                    }
                    .buttonStyle(.plain)
                    .help("macOS blocked these folders. Grant Full Disk Access to include them.")
                }
            } else {
                Text("Ready")
            }
            Spacer()
            if !model.selection.isEmpty && model.selectedDeviceID == nil && !model.showingPersonalData {
                let nodes = model.nodes(for: model.selection)
                Text("\(nodes.count) selected · \(nodes.reduce(0) { $0 + $1.size }.bytesString)")
                    .monospacedDigit()
                    .transition(.opacity)
            }
            Button { model.showHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("Cleanup history and Put Back")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.subtleFill.opacity(0.6))
        .animation(.snappyUI, value: model.selection.isEmpty)
    }
}

// MARK: - Full Disk Access banner

struct FullDiskAccessBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.fill").font(.system(size: 16)).foregroundStyle(SafetyLevel.caution.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS is hiding some folders from DiskScout").font(.system(size: 12.5, weight: .semibold))
                Text("Grant Full Disk Access so Mail, Messages, Safari and app containers are included. Sizes will be too small until then.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color))
            Button { withAnimation(.snappyUI) { model.fdaBannerDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SafetyLevel.caution.color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SafetyLevel.caution.color.opacity(0.3)))
    }
}
