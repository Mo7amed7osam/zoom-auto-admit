import SwiftUI
import ZoomAutoAdmitCore

@MainActor
final class AccountManagementViewModel: ObservableObject {
    @Published private(set) var accounts: [ZoomAccount] = []
    @Published var editingAccount: ZoomAccount?
    @Published var isPresentingEditor = false
    @Published var statusMessage: String?
    private let manager: AccountManager
    var onAccountsChanged: (() -> Void)?

    init(manager: AccountManager) { self.manager = manager; reload() }

    func reload() {
        do { accounts = try manager.accounts() }
        catch { statusMessage = "✕ \(error.localizedDescription)" }
    }

    func addAccount() { editingAccount = nil; isPresentingEditor = true }
    func edit(_ account: ZoomAccount) { editingAccount = account; isPresentingEditor = true }

    func save(draft: ZoomAccountDraft) -> Result<Void, Error> {
        do {
            if var existing = editingAccount {
                existing.displayName = draft.displayName
                existing.email = draft.email
                existing.preferredEngine = draft.preferredEngine
                try manager.update(existing, password: draft.password.isEmpty ? nil : draft.password)
                statusMessage = "✓ Account updated successfully"
            } else {
                try manager.add(draft)
                statusMessage = "✓ Account added successfully"
            }
            reload(); onAccountsChanged?(); return .success(())
        } catch {
            statusMessage = "✕ \(error.localizedDescription)"
            return .failure(error)
        }
    }

    func remove(_ account: ZoomAccount) {
        do {
            try manager.remove(id: account.id)
            statusMessage = "✓ Account removed"
            reload(); onAccountsChanged?()
        } catch { statusMessage = "✕ \(error.localizedDescription)" }
    }
}

struct AccountListView: View {
    @ObservedObject var model: AccountManagementViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Zoom Accounts").font(.title2).bold()
                Spacer()
                Button("+ Add Account") { model.addAccount() }
            }
            if model.accounts.isEmpty {
                Text("No Zoom accounts saved.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(model.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.displayName).font(.headline)
                            Text(account.email).foregroundStyle(.secondary)
                            Text("Mode: \(account.preferredEngine.rawValue.capitalized)").font(.caption)
                        }
                        Spacer()
                        Button("Edit") { model.edit(account) }
                        Button("Remove", role: .destructive) { model.remove(account) }
                    }.padding(.vertical, 4)
                }
            }
            if let status = model.statusMessage {
                Text(status).foregroundColor(status.hasPrefix("✓") ? .green : .red)
            }
        }
        .padding(20).frame(minWidth: 560, minHeight: 330)
        .sheet(isPresented: $model.isPresentingEditor) {
            AddAccountView(account: model.editingAccount) { model.save(draft: $0) }
        }
    }
}
