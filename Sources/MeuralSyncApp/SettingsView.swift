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
                    .disabled(selectedID == nil)
                    .accessibilityLabel("Delete Instance")
                    .help("Delete Selected Instance")

                    Spacer()

                    Button("Import config.json…") {
                        showingImporter = true
                    }
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

    var body: some View {
        Form {
            Section("General") {
                TextField("Instance Name", text: $instance.name)
                Toggle("Enabled", isOn: $instance.enabled)
                Toggle("Push & Switch Devices After Sync", isOn: $instance.sendToDevices)
                Picker("Frame Orientation", selection: $instance.frameOrientation) {
                    ForEach(FrameOrientation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                TextField("Gallery Name Template (:date:)", text: $instance.destinationAlbumName)
                if MeuralClient.galleryTemplateRegex(for: instance.destinationAlbumName) == nil {
                    Text("Template should include at least 3 static characters (e.g. \"Family Photos - :date:\") so old galleries can be identified safely.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Randomize Gallery Name Suffix", isOn: $instance.randomizeGalleryName)
            }

            Section("Meural Account (Keychain)") {
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                HStack {
                    Button("Save Credentials") {
                        do {
                            try appState.saveCredentials(for: instance, email: email, password: password)
                            testStatus = ("Saved to macOS Keychain.", false, true)
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
                            case .failure(let err):
                                testStatus = ("Failed: \(err.localizedDescription)", true, false)
                            }
                            isTesting = false
                        }
                    }
                    .disabled(isTesting || !appState.hasCredentials(for: instance))

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
                Stepper("Photo Count: \(instance.photoCount)", value: $instance.photoCount, in: 1...500, step: 5)
                HStack {
                    Text("Min Curation Score")
                    Slider(
                        value: Binding(
                            get: { instance.photoScoreCurationMin ?? 0.5 },
                            set: { instance.photoScoreCurationMin = $0 }
                        ),
                        in: 0...1,
                        step: 0.05
                    )
                    Text(String(format: "%.2f", instance.photoScoreCurationMin ?? 0.5))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }

                HStack {
                    TextField("Include People (comma-separated)", text: $includePeopleText)
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

                HStack {
                    TextField("Exclude People (comma-separated)", text: $excludePeopleText)
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

            Section("On This Day") {
                Stepper(
                    "On This Day Percent: \(instance.onThisDayPercent ?? 0)%",
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
                Stepper(
                    "Window: ±\(instance.onThisDayWindowDays) day(s)",
                    value: $instance.onThisDayWindowDays,
                    in: 0...14
                )
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
        testStatus = appState.hasCredentials(for: instance)
            ? ("Credentials stored in Keychain.", false, false)
            : nil
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
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("People (comma-separated)", text: $peopleText)
                TextField("Location", text: $placeText)
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
        if let (rendered, _) = try? ImageProcessor.addCaption(to: base, photo: photo) {
            previewImage = NSImage(cgImage: rendered, size: NSSize(width: width, height: height))
        }
    }
}
