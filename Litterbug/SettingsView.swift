import SwiftUI
import AVFoundation
import CoreLocation

struct SettingsView: View {
    @State private var account = AccountStore.shared
    @State private var name = ""
    @State private var username = ""
    @State private var isSaving = false
    @State private var status: String?

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
    }

    private var hasChanges: Bool {
        guard let current = account.current else { return false }
        return cleanName != current.name || cleanUsername != current.username
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 26) {
            PageTitle("Settings")

            if let current = account.current {
                HStack(spacing: 16) {
                    AvatarView(name: current.name, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.name)
                            .font(.custom("CheeseMilky", size: 28))
                        Text("@\(current.username)")
                            .font(.custom("MoreSugarRegular", size: 16))
                            .opacity(0.7)
                        if let joined = current.joinedAt {
                            Text("Joined \(joined.formatted(.dateTime.month(.wide).year()))")
                                .font(.custom("MoreSugarRegular", size: 14))
                                .opacity(0.5)
                        }
                    }
                }
                .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Account")
                        .font(.custom("MoreSugarRegular", size: 14))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))

                    SettingsField(label: "Name", text: $name)
                    SettingsField(label: "Username", text: $username, prefix: "@")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    // Only once something's been edited (or while it saves), tucked right under the fields.
                    if hasChanges || isSaving {
                        Button {
                            Task { await save() }
                        } label: {
                            Text(isSaving ? "Saving…" : "Save changes")
                                .font(.custom("MoreSugarRegular", size: 20))
                                .foregroundStyle(Color.appBackground)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(cleanName.isEmpty || cleanUsername.isEmpty || isSaving)
                        .opacity(cleanName.isEmpty || cleanUsername.isEmpty ? 0.4 : 1)
                        .padding(.top, 4)
                        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    }

                    if let status {
                        Text(status)
                            .font(.custom("MoreSugarRegular", size: 15))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.75), value: hasChanges)
                .animation(.easeInOut(duration: 0.2), value: status)
            } else {
                Text("Loading account…")
                    .font(.custom("MoreSugarRegular", size: 17))
                    .foregroundStyle(.white.opacity(0.7))
            }

            FriendsSection()

            PermissionsSection()

            ResetSection()
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.appBackground)
        .task {
            await account.refresh()
            loadFields()
        }
        .onChange(of: account.current) { _, _ in
            if !hasChanges { loadFields() }
        }
    }

    private func loadFields() {
        guard let current = account.current else { return }
        name = current.name
        username = current.username
    }

    private func save() async {
        isSaving = true
        status = nil
        do {
            try await account.updateCurrent(name: cleanName, username: cleanUsername)
            loadFields()
            status = "Saved"
        } catch {
            status = "Couldn't save, try again"
        }
        isSaving = false
    }
}

/// Your friends (they show in the Friends feed and Friends ranks) and adding one by username.
struct FriendsSection: View {
    @State private var account = AccountStore.shared
    @State private var username = ""
    @State private var isAdding = false
    @State private var status: String?

    private var friends: [UserProfile] {
        let ids = account.current?.friends ?? []
        return ids.compactMap { id in account.users.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Friends")
                .font(.custom("MoreSugarRegular", size: 14))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))

            ForEach(friends) { friend in
                HStack(spacing: 12) {
                    AvatarView(name: friend.name, size: 34)
                    Text(friend.name)
                        .font(.custom("MoreSugarRegular", size: 18))
                    Text("@\(friend.username)")
                        .font(.custom("MoreSugarRegular", size: 14))
                        .opacity(0.6)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
            }

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("@").opacity(0.6)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                }
                .font(.custom("MoreSugarRegular", size: 18))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 50)
                .overlay(Capsule().stroke(.white, lineWidth: 2))

                // Only once there's a username to add; the field has the full width until then.
                if !username.trimmingCharacters(in: .whitespaces).isEmpty || isAdding {
                    Button {
                        Task { await add() }
                    } label: {
                        Text(isAdding ? "…" : "Add")
                            .font(.custom("MoreSugarRegular", size: 18))
                            .foregroundStyle(Color.appBackground)
                            .padding(.horizontal, 22)
                            .frame(height: 50)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdding)
                    .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.75),
                       value: username.trimmingCharacters(in: .whitespaces).isEmpty)

            if let status {
                Text(status)
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 4)
            }
        }
    }

    private func add() async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isAdding = true
        status = nil
        do {
            let name = try await account.addFriend(username: username)
            status = "Added \(name)"
            username = ""
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Couldn't add, try again"
        }
        isAdding = false
    }
}

/// Location and camera access: shows the current state; taps ask (first time) or open iOS Settings.
struct PermissionsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = CLLocationManager().authorizationStatus
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions")
                .font(.custom("MoreSugarRegular", size: 14))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))

            PermissionRow(
                icon: "direction-color",
                title: "Location",
                detail: "Finds litter near you",
                state: locationState
            ) {
                if location == .notDetermined {
                    LocationTracker.shared.start()
                } else {
                    openSettings()
                }
            }

            PermissionRow(
                icon: "camera-color",
                title: "Camera",
                detail: "Photos of what you pick up",
                state: cameraState
            ) {
                if camera == .notDetermined {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        refresh()
                    }
                } else {
                    openSettings()
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        // Location's prompt answers asynchronously; pick up the result.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
            }
        }
    }

    private var locationState: PermissionRow.State {
        switch location {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private var cameraState: PermissionRow.State {
        switch camera {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private func refresh() {
        location = CLLocationManager().authorizationStatus
        camera = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// For demos: puts every placed litter piece that's been picked up back on the map.
struct ResetSection: View {
    @State private var confirming = false
    @State private var isResetting = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 10) {
            Button {
                confirming = true
            } label: {
                Text(isResetting ? "Resetting…" : "Reset stored progress")
                    .font(.custom("MoreSugarRegular", size: 19))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .overlay(Capsule().stroke(.white, lineWidth: 2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isResetting)
            .confirmationDialog("Put every picked-up litter piece back on the map?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Reset stored progress", role: .destructive) {
                    Task { await reset() }
                }
            }

            if let status {
                Text(status)
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.top, 6)
    }

    private func reset() async {
        isResetting = true
        status = nil
        do {
            let restored = try await LitterStore.shared.resetDemoPieces()
            status = restored == 0 ? "Nothing to reset" : "Restored \(restored) \(restored == 1 ? "piece" : "pieces")"
        } catch {
            status = "Couldn't reset, try again"
        }
        isResetting = false
    }
}

struct PermissionRow: View {
    enum State { case allowed, denied, notAsked }

    let icon: String
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Hand-drawn full-color asset icons.
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.appBackground)
                    .frame(width: 36, height: 36)
                    .background(WobblyCircle().fill(.white))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.custom("MoreSugarRegular", size: 19))
                    Text(detail)
                        .font(.custom("MoreSugarRegular", size: 13))
                        .opacity(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Text(stateLabel)
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(state == .allowed ? Color.appBackground : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(state == .allowed ? Color.white : .clear, in: Capsule())
                    .overlay(Capsule().stroke(.white, lineWidth: state == .allowed ? 0 : 1.5))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stateLabel: String {
        switch state {
        case .allowed: "On"
        case .denied: "Off"
        case .notAsked: "Allow"
        }
    }
}

struct SettingsField: View {
    let label: String
    @Binding var text: String
    var prefix: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.custom("MoreSugarRegular", size: 17))
                .opacity(0.7)
                .frame(width: 90, alignment: .leading)
            HStack(spacing: 0) {
                if !prefix.isEmpty {
                    Text(prefix).opacity(0.6)
                }
                TextField(label, text: $text)
            }
            .font(.custom("MoreSugarRegular", size: 19))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 56)
        .overlay(Capsule().stroke(.white, lineWidth: 2))
    }
}

#Preview {
    SettingsView()
}
