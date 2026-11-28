import AppKit
import MeuralSyncCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            InstancesSettingsTab(appState: appState)
                .tabItem { Label("Instances", systemImage: "photo.stack") }

            ScheduleAndPermissionsTab(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }

            CaptionPreviewTab()
                .tabItem { Label("Caption Preview", systemImage: "text.below.photo") }
        }
        .frame(minWidth: 720, minHeight: 540)
        .padding()
    }
}

private struct InstancesSettingsTab: View {
    @Bindable var appState: AppState
    @State private var selectedID: UUID?
    @State private var showingImporter = false
    @State private var pendingImportURL: URL?
    @State private var showingImportConfirmation = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(appState.config.instances) { inst in
                        HStack {
                            Circle()
                                .fill(inst.enabled ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                                .accessibilityLabel(inst.enabled ? "Enabled" : "Disabled")
                            Text(inst.name.isEmpty ? "Untitled" : inst.name)
                                .lineLimit(1)
                        }
                        .tag(inst.id)
                    }
                }

                Divider()

                HStack(spacing: 6) {
                    Button {
                        let newInstance = InstanceConfig(name: "Meural \(appState.config.instances.count + 1)")
                        appState.config.instances.append(newInstance)
                        selectedID = newInstance.id
                        appState.saveConfig()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Instance")
                    .help("Add Instance")

                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedID == nil || appState.isSyncing || appState.isMutatingGalleries || appState.isRetryingDevicePush)
                    .accessibilityLabel("Delete Instance")
                    .help("Delete Selected Instance")

                    Spacer()

                    Button("Import config.json…") {
                        showingImporter = true
                    }
                    .disabled(appState.isSyncing || appState.isMutatingGalleries || appState.isRetryingDevicePush)
                    .controlSize(.small)
                }
                .padding(8)
            }
            .frame(minWidth: 190, maxWidth: 220)

            if let idx = selectedIndex {
                InstanceEditorView(
                    instance: $appState.config.instances[idx],
                    appState: appState
                )
            } else {
                ContentUnavailableView("No Instance Selected", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = appState.config.instances.first?.id
            }
        }
        .confirmationDialog(
            "Delete this instance?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let idx = selectedIndex {
                    let removed = appState.config.instances.remove(at: idx)
                    appState.deleteCredentials(for: removed)
                    selectedID = appState.config.instances.isEmpty
                        ? nil
                        : appState.config.instances[min(idx, appState.config.instances.count - 1)].id
                    appState.saveConfig()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the instance configuration and its saved Meural credentials from Keychain.")
        }
        .confirmationDialog(
            "Replace existing instances with imported config?",
            isPresented: $showingImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let url = pendingImportURL {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    appState.importConfigJSON(from: url)
                    selectedID = appState.config.instances.first?.id
                    pendingImportURL = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                pendingImportURL = url
                showingImportConfirmation = true
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return appState.config.instances.firstIndex(where: { $0.id == selectedID })
    }
}

private struct InstanceEditorView: View {
    @Binding var instance: InstanceConfig
    @Bindable var appState: AppState

    @State private var email = ""
    @State private var password = ""
    @State private var includePeopleText = ""
    @State private var excludePeopleText = ""
    @State private var testStatus: (message: String, isError: Bool, isSuccess: Bool)?
    @State private var isTesting = false
    @State private var availableDevices: [MeuralDevice] = []
    @State private var isLoadingDevices = false
    @State private var devicesLoadError: String?
    @State private var availableGalleries: [MeuralGallery] = []
    @State private var isLoadingGalleries = false
    @State private var galleriesLoadError: String?

    private var hasSavedCredentials: Bool {
        appState.hasCredentials(for: instance)
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Instance Name", text: $instance.name)
                    .multilineTextAlignment(.trailing)
                Toggle("Enabled", isOn: $instance.enabled)
                Toggle("Push & Switch Devices After Sync", isOn: $instance.sendToDevices)
                    .onChange(of: instance.sendToDevices) { _, enabled in
                        if enabled && availableDevices.isEmpty && hasSavedCredentials {
                            loadDevices()
                        }
                    }
                if instance.sendToDevices {
                    LabeledContent("Target Meural Frame") {
                        HStack(spacing: 6) {
                            Picker("Target Meural Frame", selection: $instance.deviceId) {
                                Text("None (Select a Frame)").tag(Int?.none)
                                ForEach(availableDevices) { device in
                                    Text(deviceDisplayLabel(device)).tag(Optional(device.id))
                                }
                                if let savedID = instance.deviceId,
                                   !availableDevices.contains(where: { $0.id == savedID })
                                {
                                    Text("Frame #\(savedID)").tag(Optional(savedID))
                                }
                            }
                            .labelsHidden()
                            if isLoadingDevices {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    loadDevices()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!hasSavedCredentials)
                                .help("Load Meural frames from this account")
                            }
                        }
                    }
                    if let devicesLoadError {
                        Text(devicesLoadError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if instance.deviceId == nil && !isLoadingDevices {
                        Text(
                            availableDevices.isEmpty
                                ? "Click refresh to load your Meural frames and choose a target frame."
                                : "Select a Meural frame to enable pushing and Send to Frame."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                Picker("Frame Orientation", selection: $instance.frameOrientation) {
                    ForEach(FrameOrientation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Caption Date Format", selection: $instance.captionDateFormat) {
                    ForEach(CaptionDateFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                Picker("Gallery Mode", selection: $instance.gallerySyncMode) {
                    ForEach(GallerySyncMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: instance.gallerySyncMode) { _, mode in
                    if mode == .updateExisting && availableGalleries.isEmpty && hasSavedCredentials {
                        loadGalleries()
                    }
                }

                if instance.gallerySyncMode == .createAndDelete {
                    TextField("Gallery Name Template (:date:)", text: $instance.destinationAlbumName)
                        .multilineTextAlignment(.trailing)
                    if MeuralClient.galleryTemplateRegex(for: instance.destinationAlbumName) == nil {
                        Text("Template should include at least 3 static characters (e.g. \"Family Photos - :date:\") so old galleries can be identified safely.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Toggle("Randomize Gallery Name Suffix", isOn: $instance.randomizeGalleryName)
                } else {
                    LabeledContent("Target Meural Gallery") {
                        HStack(spacing: 6) {
                            Picker("Target Meural Gallery", selection: $instance.targetGalleryId) {
                                Text("None (Select a Gallery)").tag(Int?.none)
                                ForEach(availableGalleries) { gallery in
                                    Text("\(gallery.name) (#\(gallery.id))").tag(Optional(gallery.id))
                                }
                                if let savedID = instance.targetGalleryId,
                                   !availableGalleries.contains(where: { $0.id == savedID })
                                {
                                    Text("Gallery #\(savedID)").tag(Optional(savedID))
                                }
                            }
                            .labelsHidden()
                            if isLoadingGalleries {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    loadGalleries()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!hasSavedCredentials)
                                .help("Load Meural galleries from this account")
                            }
                        }
                    }
                    if let galleriesLoadError {
                        Text(galleriesLoadError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if instance.targetGalleryId == nil && !isLoadingGalleries {
                        Text(
                            availableGalleries.isEmpty
                                ? "Click refresh to load your Meural galleries and choose which gallery to update."
                                : "Select an existing Meural gallery to replace its photos on each sync."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Meural Account (Keychain)") {
                TextField("Email", text: $email)
                    .multilineTextAlignment(.trailing)
                LabeledContent("Password") {
                    HStack(spacing: 8) {
                        SecureField(
                            "",
                            text: $password,
                            prompt: Text(hasSavedCredentials ? "Enter new password to replace" : "Enter password")
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)

                        if hasSavedCredentials && password.isEmpty {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: Capsule())
                                .fixedSize()
                                .help("Password is stored securely in macOS Keychain")
                        }
                    }
                }
                HStack {
                    Button("Save Credentials") {
                        do {
                            try appState.saveCredentials(for: instance, email: email, password: password)
                            password = ""
                            testStatus = ("Saved to macOS Keychain.", false, true)
                            if instance.sendToDevices {
                                loadDevices()
                            }
                            if instance.gallerySyncMode == .updateExisting {
                                loadGalleries()
                            }
                        } catch {
                            testStatus = (error.localizedDescription, true, false)
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty)

                    Button("Test Connection") {
                        isTesting = true
                        testStatus = nil
                        Task {
                            let res = await appState.testConnection(for: instance)
                            switch res {
                            case .success(let count):
                                testStatus = ("Connected! Found \(count) device(s).", false, true)
                                if instance.sendToDevices {
                                    loadDevices()
                                }
                                if instance.gallerySyncMode == .updateExisting {
                                    loadGalleries()
                                }
                            case .failure(let err):
                                testStatus = ("Failed: \(err.localizedDescription)", true, false)
                            }
                            isTesting = false
                        }
                    }
                    .disabled(isTesting || !hasSavedCredentials)

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status = testStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.red : (status.isSuccess ? Color.green : Color.secondary))
                }
            }

            Section("Photo Selection") {
                Picker("Selection Mode", selection: $instance.photoSelectionMode) {
                    ForEach(PhotoSelectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                LabeledContent("Photo Count") {
                    HStack(spacing: 6) {
                        Text("\(instance.photoCount)")
                            .monospacedDigit()
                        Stepper("", value: $instance.photoCount, in: 1...500, step: 5)
                            .labelsHidden()
                    }
                }

                LabeledContent("Min Curation Score") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { instance.photoScoreCurationMin ?? 0.5 },
                                set: { instance.photoScoreCurationMin = $0 }
                            ),
                            in: 0...1,
                            step: 0.05
                        )
                        .frame(maxWidth: 180)
                        Text(String(format: "%.2f", instance.photoScoreCurationMin ?? 0.5))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                if instance.photoSelectionMode == .people {
                    LabeledContent("Include People") {
                        HStack(spacing: 6) {
                            TextField("", text: $includePeopleText, prompt: Text("Comma-separated"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            if !appState.availablePeople.isEmpty {
                                Menu("Add") {
                                    ForEach(appState.availablePeople, id: \.self) { person in
                                        Button(person) {
                                            appendPerson(person, to: &includePeopleText)
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }

                    LabeledContent("Exclude People") {
                        HStack(spacing: 6) {
                            TextField("", text: $excludePeopleText, prompt: Text("Comma-separated"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            if !appState.availablePeople.isEmpty {
                                Menu("Add") {
                                    ForEach(appState.availablePeople, id: \.self) { person in
                                        Button(person) {
                                            appendPerson(person, to: &excludePeopleText)
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                } else {
                    LabeledContent("Photos Album") {
                        HStack(spacing: 6) {
                            Picker(
                                "Photos Album",
                                selection: Binding<String?>(
                                    get: { instance.sourceAlbumIdentifier },
                                    set: { newID in
                                        instance.sourceAlbumIdentifier = newID
                                        if let newID,
                                           let album = appState.availableAlbums.first(where: { $0.id == newID })
                                        {
                                            instance.sourceAlbumName = album.title
                                        } else if newID == nil {
                                            instance.sourceAlbumName = nil
                                        }
                                    }
                                )
                            ) {
                                Text("None (Select an Album)").tag(String?.none)
                                ForEach(appState.availableAlbums) { album in
                                    Text("\(album.title) (\(album.estimatedCount))").tag(Optional(album.id))
                                }
                                if let savedID = instance.sourceAlbumIdentifier,
                                   !appState.availableAlbums.contains(where: { $0.id == savedID })
                                {
                                    Text(instance.sourceAlbumName ?? savedID).tag(Optional(savedID))
                                }
                            }
                            .labelsHidden()

                            Button {
                                appState.refreshPermissions()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Reload albums from Apple Photos")
                        }
                    }
                    if instance.sourceAlbumIdentifier == nil && (instance.sourceAlbumName?.isEmpty ?? true) {
                        Text(
                            appState.availableAlbums.isEmpty
                                ? "Grant Photos access or click refresh to load your Apple Photos albums."
                                : "Select an Apple Photos album to sync photos from."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("On This Day") {
                LabeledContent("On This Day Percent") {
                    HStack(spacing: 6) {
                        Text("\(instance.onThisDayPercent ?? 0)%")
                            .monospacedDigit()
                        Stepper(
                            "",
                            value: Binding(
                                get: { instance.onThisDayPercent ?? 0 },
                                set: {
                                    instance.onThisDayPercent = $0
                                    instance.onThisDayCount = nil
                                }
                            ),
                            in: 0...100,
                            step: 5
                        )
                        .labelsHidden()
                    }
                }

                LabeledContent("Window") {
                    HStack(spacing: 6) {
                        Text("±\(instance.onThisDayWindowDays) day(s)")
                            .monospacedDigit()
                        Stepper("", value: $instance.onThisDayWindowDays, in: 0...14)
                            .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: syncLocalFields)
        .onChange(of: instance.id) { _, _ in syncLocalFields() }
        .onChange(of: includePeopleText) { _, newValue in
            instance.people.include = splitCSV(newValue)
            appState.saveConfig()
        }
        .onChange(of: excludePeopleText) { _, newValue in
            instance.people.exclude = splitCSV(newValue)
            appState.saveConfig()
        }
        .onChange(of: instance) { _, _ in
            appState.saveConfig()
        }
    }

    private func syncLocalFields() {
        email = appState.loadEmail(for: instance)
        password = ""
        includePeopleText = instance.people.include.joined(separator: ", ")
        excludePeopleText = instance.people.exclude.joined(separator: ", ")
        testStatus = hasSavedCredentials
            ? ("Credentials stored in Keychain.", false, false)
            : nil
        availableDevices = []
        devicesLoadError = nil
        availableGalleries = []
        galleriesLoadError = nil
        if instance.sendToDevices && hasSavedCredentials {
            loadDevices()
        }
        if instance.gallerySyncMode == .updateExisting && hasSavedCredentials {
            loadGalleries()
        }
    }

    private func loadDevices() {
        guard hasSavedCredentials, !isLoadingDevices else { return }
        let targetInstance = instance
        isLoadingDevices = true
        devicesLoadError = nil
        Task {
            do {
                let fetched = try await appState.fetchDevices(for: targetInstance)
                if instance.id == targetInstance.id {
                    availableDevices = fetched
                    if instance.deviceId == nil, fetched.count == 1 {
                        instance.deviceId = fetched[0].id
                    }
                }
            } catch {
                if instance.id == targetInstance.id {
                    devicesLoadError = "Could not load frames: \(error.localizedDescription)"
                }
            }
            if instance.id == targetInstance.id {
                isLoadingDevices = false
            }
        }
    }

    private func loadGalleries() {
        guard hasSavedCredentials, !isLoadingGalleries else { return }
        let targetInstance = instance
        isLoadingGalleries = true
        galleriesLoadError = nil
        Task {
            do {
                let fetched = try await appState.fetchGalleries(for: targetInstance)
                if instance.id == targetInstance.id {
                    availableGalleries = fetched.sorted { $0.id > $1.id }
                }
            } catch {
                if instance.id == targetInstance.id {
                    galleriesLoadError = "Could not load galleries: \(error.localizedDescription)"
                }
            }
            if instance.id == targetInstance.id {
                isLoadingGalleries = false
            }
        }
    }

    private func deviceDisplayLabel(_ device: MeuralDevice) -> String {
        let name = device.alias?.isEmpty == false ? device.alias! : "Frame #\(device.id)"
        if let orientation = device.parsedOrientation {
            return "\(name) (\(orientation.displayName) · #\(device.id))"
        }
        return "\(name) (#\(device.id))"
    }

    private func appendPerson(_ person: String, to field: inout String) {
        var existing = splitCSV(field)
        if !existing.contains(person) {
            existing.append(person)
            field = existing.joined(separator: ", ")
        }
    }

    private func splitCSV(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ScheduleAndPermissionsTab: View {
    @Bindable var appState: AppState

    /// Binds a time-only DatePicker to an hour/minute pair on the schedule config.
    private func scheduleTimeBinding(
        hour hourPath: WritableKeyPath<ScheduleConfig, Int>,
        minute minutePath: WritableKeyPath<ScheduleConfig, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let schedule = appState.config.schedule ?? ScheduleConfig()
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = schedule[keyPath: hourPath]
                comps.minute = schedule[keyPath: minutePath]
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                var s = appState.config.schedule ?? ScheduleConfig()
                s[keyPath: hourPath] = Calendar.current.component(.hour, from: date)
                s[keyPath: minutePath] = Calendar.current.component(.minute, from: date)
                appState.config.schedule = s
                appState.seedScheduleAfterEdit()
                appState.saveConfig()
            }
        )
    }

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Photos Library (PhotoKit)") {
                    HStack {
                        Image(systemName: photoStatusIcon)
                            .foregroundStyle(photoStatusColor)
                        Text(photoStatusText)
                        if appState.photoAuthStatus == .notDetermined {
                            Button("Request Access") {
                                appState.requestPhotoAccess()
                            }
                        } else {
                            Button("Open Settings") {
                                appState.openPhotosPrivacySettings()
                            }
                        }
                    }
                }

                LabeledContent("Full Disk Access (Optional — People)") {
                    HStack {
                        Image(systemName: appState.hasFullDiskAccess ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(appState.hasFullDiskAccess ? .green : .secondary)
                        Text(appState.hasFullDiskAccess ? "Granted" : "Not Granted (only needed for People filters/captions)")
                            .font(.caption)
                            .foregroundStyle(appState.hasFullDiskAccess ? .primary : .secondary)
                        Button("Open Settings") {
                            appState.openFullDiskAccessSettings()
                        }
                    }
                }

                Button("Refresh Permission Status") {
                    appState.refreshPermissions()
                }
            }

            Section("Startup & Sync Schedule") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )

                Toggle(
                    "Enable Scheduled Sync",
                    isOn: Binding(
                        get: { appState.config.schedule?.enabled ?? false },
                        set: { enabled in
                            var s = appState.config.schedule ?? ScheduleConfig()
                            s.enabled = enabled
                            appState.config.schedule = s
                            if enabled {
                                appState.seedScheduleAfterEdit()
                            }
                            appState.saveConfig()
                        }
                    )
                )

                if appState.config.schedule?.enabled == true {
                    let schedule = appState.config.schedule ?? ScheduleConfig()

                    Picker(
                        "Frequency",
                        selection: Binding(
                            get: { schedule.frequency },
                            set: { newFreq in
                                var s = appState.config.schedule ?? ScheduleConfig()
                                s.frequency = newFreq
                                appState.config.schedule = s
                                appState.seedScheduleAfterEdit()
                                appState.saveConfig()
                            }
                        )
                    ) {
                        ForEach(SyncFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }

                    if schedule.frequency == .hourly {
                        Stepper(
                            "Every \(schedule.intervalHours) \(schedule.intervalHours == 1 ? "hour" : "hours")",
                            value: Binding(
                                get: { schedule.intervalHours },
                                set: { newVal in
                                    var s = appState.config.schedule ?? ScheduleConfig()
                                    s.intervalHours = newVal
                                    appState.config.schedule = s
                                    appState.seedScheduleAfterEdit()
                                    appState.saveConfig()
                                }
                            ),
                            in: 1...24
                        )
                    } else if schedule.frequency == .oncePerDay {
                        DatePicker(
                            "Allowed From",
                            selection: scheduleTimeBinding(
                                hour: \.windowStartHour,
                                minute: \.windowStartMinute
                            ),
                            displayedComponents: .hourAndMinute
                        )

                        DatePicker(
                            "Allowed Until",
                            selection: scheduleTimeBinding(
                                hour: \.windowEndHour,
                                minute: \.windowEndMinute
                            ),
                            displayedComponents: .hourAndMinute
                        )

                        Text(
                            schedule.isAllDayWindow
                                ? "Syncs at the first chance each day (launch, wake, or midnight) and retries every hour until one succeeds. Set different times to limit when syncing is allowed."
                                : "Syncs at the first chance inside this window each day and retries every hour until one succeeds. A manual sync inside the window also counts."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        DatePicker(
                            "Sync Time",
                            selection: Binding(
                                get: {
                                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                                    comps.hour = schedule.hour
                                    comps.minute = schedule.minute
                                    return Calendar.current.date(from: comps) ?? Date()
                                },
                                set: { date in
                                    var s = appState.config.schedule ?? ScheduleConfig()
                                    s.hour = Calendar.current.component(.hour, from: date)
                                    s.minute = Calendar.current.component(.minute, from: date)
                                    appState.config.schedule = s
                                    appState.seedScheduleAfterEdit()
                                    appState.saveConfig()
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )

                        if schedule.frequency == .weekly {
                            LabeledContent("Days") {
                                WeekdayPicker(
                                    selectedWeekdays: Binding(
                                        get: { Set(schedule.weekdays) },
                                        set: { newSet in
                                            var s = appState.config.schedule ?? ScheduleConfig()
                                            let sorted = Array(newSet).sorted()
                                            s.weekdays = sorted.isEmpty ? [Calendar.current.component(.weekday, from: Date())] : sorted
                                            appState.config.schedule = s
                                            appState.seedScheduleAfterEdit()
                                            appState.saveConfig()
                                        }
                                    )
                                )
                            }
                        }
                    }

                    if let next = appState.nextScheduledSyncDate {
                        LabeledContent("Next Scheduled Sync") {
                            Text(next.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Version") {
                    Text(appState.updater.appVersionString)
                        .foregroundStyle(.secondary)
                }

                if appState.updater.isConfigured {
                    Toggle(
                        "Automatically Check for Updates",
                        isOn: Binding(
                            get: { appState.updater.automaticallyChecksForUpdates },
                            set: { appState.updater.automaticallyChecksForUpdates = $0 }
                        )
                    )

                    Button("Check for Updates…") {
                        appState.updater.checkForUpdates()
                    }
                    .disabled(!appState.updater.canCheckForUpdates)
                } else {
                    Text("Automatic updates are enabled in signed GitHub Release builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshPermissions()
            appState.refreshLaunchAtLogin()
        }
    }

    private var photoStatusIcon: String {
        switch appState.photoAuthStatus {
        case .authorized: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var photoStatusColor: Color {
        switch appState.photoAuthStatus {
        case .authorized: return .green
        case .limited: return .yellow
        default: return .orange
        }
    }

    private var photoStatusText: String {
        switch appState.photoAuthStatus {
        case .authorized: return "Authorized"
        case .limited: return "Limited Access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var selectedWeekdays: Set<Int>

    private let days: [(id: Int, label: String, fullName: String)] = [
        (1, "S", "Sunday"),
        (2, "M", "Monday"),
        (3, "T", "Tuesday"),
        (4, "W", "Wednesday"),
        (5, "T", "Thursday"),
        (6, "F", "Friday"),
        (7, "S", "Saturday"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.id) { day in
                let isSelected = selectedWeekdays.contains(day.id)
                Button {
                    var updated = selectedWeekdays
                    if isSelected {
                        if updated.count > 1 {
                            updated.remove(day.id)
                        }
                    } else {
                        updated.insert(day.id)
                    }
                    selectedWeekdays = updated
                } label: {
                    Text(day.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                            in: Circle()
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.fullName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct CaptionPreviewTab: View {
    @State private var peopleText = "Alice Smith, Bob Jones, Jane Doe"
    @State private var placeText = "Space Mountain, Magic Kingdom Park"
    @State private var dateFormat: CaptionDateFormat = .medium
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("People (comma-separated)", text: $peopleText)
                TextField("Location", text: $placeText)
                Picker("Date", selection: $dateFormat) {
                    ForEach(CaptionDateFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            .textFieldStyle(.roundedBorder)

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            } else {
                Spacer()
            }
        }
        .padding()
        .onAppear(perform: renderPreview)
        .onChange(of: peopleText) { _, _ in renderPreview() }
        .onChange(of: placeText) { _, _ in renderPreview() }
        .onChange(of: dateFormat) { _, _ in renderPreview() }
    }

    private func renderPreview() {
        let width = 1080
        let height = 540
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return }

        // Soft gradient backdrop so the translucent caption panel is easy to inspect
        let colors = [
            CGColor(srgbRed: 0.16, green: 0.32, blue: 0.56, alpha: 1),
            CGColor(srgbRed: 0.34, green: 0.54, blue: 0.72, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        guard let base = ctx.makeImage() else { return }

        let persons = peopleText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let photo = PhotoMetadata(
            uuid: "preview",
            date: Date(),
            width: width,
            height: height,
            persons: persons,
            placeName: placeText
        )
        if let (rendered, _) = try? ImageProcessor.addCaption(to: base, photo: photo, dateFormat: dateFormat) {
            previewImage = NSImage(cgImage: rendered, size: NSSize(width: width, height: height))
        }
    }
}
