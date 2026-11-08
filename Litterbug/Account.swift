import SwiftUI
import Observation

struct UserProfile: Identifiable, Equatable {
    let id: String
    var name: String
    var username: String
    var school: String
    var joinedAt: Date?
}

/// Accounts live in the Firestore `users` collection (doc id = user id). There's no sign-in yet:
/// the device's account comes from the `accountID` default and is Nick unless set.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    let currentID = UserDefaults.standard.string(forKey: "accountID") ?? "nick"
    var users: [UserProfile] = []

    var current: UserProfile? { users.first { $0.id == currentID } }

    func refresh() async {
        guard let documents = try? await FirestoreClient.shared.list("users", fields: ["name", "username", "school", "joinedAt"]) else { return }
        let latest = documents.map { document in
            UserProfile(
                id: document.id,
                name: document["name"]?.stringValue ?? document.id.capitalized,
                username: document["username"]?.stringValue ?? document.id,
                school: document["school"]?.stringValue ?? "",
                joinedAt: document["joinedAt"]?.date
            )
        }
        if latest != users {
            users = latest
        }
    }

    func updateCurrent(name: String, username: String) async throws {
        try await FirestoreClient.shared.update("users", id: currentID, fields: [
            "name": .string(name),
            "username": .string(username),
        ])
        await refresh()
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.custom("CheeseMilky", size: size * 0.5))
            .foregroundStyle(Color.appBackground)
            .frame(width: size, height: size)
            .background(WobblyCircle().fill(.white))
    }
}
