import SwiftUI
import ZoomAutoAdmitCore

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var email: String
    @State private var password = ""
    @State private var preferredEngine: ZoomPreferredEngine
    @State private var resultMessage: String?
    let account: ZoomAccount?
    let onSave: (ZoomAccountDraft) -> Result<Void, Error>

    init(account: ZoomAccount?, onSave: @escaping (ZoomAccountDraft) -> Result<Void, Error>) {
        self.account = account; self.onSave = onSave
        _displayName = State(initialValue: account?.displayName ?? "")
        _email = State(initialValue: account?.email ?? "")
        _preferredEngine = State(initialValue: account?.preferredEngine ?? .auto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(account == nil ? "Add Zoom Account" : "Edit Zoom Account").font(.title2).bold()
            TextField("Display Name", text: $displayName)
            TextField("Email", text: $email).textContentType(.emailAddress)
            SecureField(account == nil ? "Password" : "New Password (optional)", text: $password)
                .textContentType(.password)
            Picker("Preferred Mode", selection: $preferredEngine) {
                Text("Desktop Zoom").tag(ZoomPreferredEngine.desktop)
                Text("Web Zoom").tag(ZoomPreferredEngine.web)
                Text("Auto").tag(ZoomPreferredEngine.auto)
            }.pickerStyle(.radioGroup)
            if let resultMessage { Text(resultMessage).foregroundColor(resultMessage.hasPrefix("✓") ? .green : .red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save Account") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || email.isEmpty)
            }
        }.padding(22).frame(width: 430)
    }

    private func save() {
        let draft = ZoomAccountDraft(
            displayName: displayName, email: email, password: password, preferredEngine: preferredEngine
        )
        switch onSave(draft) {
        case .success:
            resultMessage = account == nil ? "✓ Account added successfully" : "✓ Account updated successfully"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
        case .failure(let error): resultMessage = "✕ \(error.localizedDescription)"
        }
    }
}
