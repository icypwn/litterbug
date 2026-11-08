import SwiftUI
import Observation

struct UserProfile: Identifiable, Equatable {
    let id: String
    var name: String
    var username: String
    var school: String
    var joinedAt: Date?
    /// User ids, stored in Firestore as a comma-separated string.
    var friends: [String] = []
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
        guard let documents = try? await FirestoreClient.shared.list("users", fields: ["name", "username", "school", "joinedAt", "friends"]) else { return }
        let latest = documents.map { document in
            UserProfile(
                id: document.id,
                name: document["name"]?.stringValue ?? document.id.capitalized,
                username: document["username"]?.stringValue ?? document.id,
                school: document["school"]?.stringValue ?? "",
                joinedAt: document["joinedAt"]?.date,
                friends: (document["friends"]?.stringValue ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
        if latest != users {
            users = latest
        }
    }

    enum FriendError: LocalizedError {
        case notFound, yourself, already
        var errorDescription: String? {
            switch self {
            case .notFound: "No one with that username"
            case .yourself: "That's you"
            case .already: "Already friends"
            }
        }
    }

    /// Adds a friend by username (one-way, like following). Returns their name.
    func addFriend(username raw: String) async throws -> String {
        await refresh()
        let username = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard let me = current else { throw FriendError.notFound }
        guard let friend = users.first(where: { $0.username.lowercased() == username }) else { throw FriendError.notFound }
        guard friend.id != me.id else { throw FriendError.yourself }
        guard !me.friends.contains(friend.id) else { throw FriendError.already }
        try await FirestoreClient.shared.update("users", id: me.id, fields: [
            "friends": .string((me.friends + [friend.id]).joined(separator: ",")),
        ])
        await refresh()
        return friend.name
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
    /// Green circle with a white letter, for use on white cards.
    var inverted = false

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.custom("CheeseMilky", size: size * 0.5))
            .foregroundStyle(inverted ? .white : Color.appBackground)
            .frame(width: size, height: size)
            .background(WobblyCircle().fill(inverted ? Color.appBackground : .white))
    }
}
