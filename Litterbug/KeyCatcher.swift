import SwiftUI
import UIKit

struct KeyCatcher: UIViewRepresentable {
    let actions: [String: () -> Void]

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.actions = actions
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        view.actions = actions
    }

    final class KeyView: UIView {
        var actions: [String: () -> Void] = [:]

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { self.becomeFirstResponder() }
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            actions.keys.map { input in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handle(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func handle(_ command: UIKeyCommand) {
            guard let input = command.input else { return }
            actions[input]?()
        }
    }
}
