import GPUWatchCore
import SwiftUI

/// The first thing a new user sees. There's no password: the app connects with this Mac's SSH
/// keys, so the ID only picks whose jobs to show, and ssh says if the key doesn't fit.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    private let id = State(initialValue: "")
    private let remembers = State(initialValue: true)

    private var normalized: String? { ComputingID.normalized(id.wrappedValue) }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("GPU Watch")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Sign in with your UVA computing ID to see your jobs on \(RemoteScripts.serverHost) and UVA HPC.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Computing ID", text: id.projectedValue, prompt: Text("Computing ID, e.g. mst3k"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .autocorrectionDisabled()
                    .onSubmit(signIn)
                if !id.wrappedValue.isEmpty && normalized == nil {
                    Text("A computing ID is letters and digits, like mst3k.")
                        .font(.caption)
                        .foregroundStyle(Theme.serious)
                }
                Toggle("Remember me on this Mac", isOn: remembers.projectedValue)
                    .toggleStyle(.checkbox)
            }

            Button(action: signIn) {
                Text("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(normalized == nil)

            Text("The app connects over SSH as this user, so this Mac needs an SSH key that both machines accept for it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        guard let normalized else { return }
        model.signIn(as: normalized, remember: remembers.wrappedValue)
    }
}
