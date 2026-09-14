import SwiftUI

/// The name on the traveller's tickets, in three parts so a middle name is not
/// guessed at. Filled from the Google account after sign-in, editable from Settings.
struct PassengerNameSheet: View {
    let title: String
    let intro: String
    let onSave: (String) -> Void
    let onSkip: () -> Void

    @State private var given: String
    @State private var middle: String
    @State private var family: String

    init(title: String, intro: String, given: String, middle: String, family: String,
         onSave: @escaping (String) -> Void, onSkip: @escaping () -> Void) {
        self.title = title; self.intro = intro; self.onSave = onSave; self.onSkip = onSkip
        _given = State(initialValue: given); _middle = State(initialValue: middle); _family = State(initialValue: family)
    }

    /// "Given Middle Family" — what the server matches ticket names against.
    static func parts(of full: String) -> (given: String, middle: String, family: String) {
        let words = full.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (full, "", "") }
        return (words[0], words.dropFirst().dropLast().joined(separator: " "), words[words.count - 1])
    }

    private var joined: String { [given, middle, family].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $given).textContentType(.givenName)
                    TextField("Middle name (optional)", text: $middle).textContentType(.middleName)
                    TextField("Last name", text: $family).textContentType(.familyName)
                } footer: {
                    Text(intro)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip", action: onSkip) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(joined) }.disabled(given.trimmingCharacters(in: .whitespaces).isEmpty || family.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
