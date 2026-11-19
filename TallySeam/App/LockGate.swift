import SwiftUI
import SwiftData

/// Shows the app only when unlocked, and covers it with a privacy screen whenever the app isn't active
/// (app switcher, Control Center, incoming calls), so balances never appear in the app snapshot.
struct LockGate<Content: View>: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settings: [AppSettings]
    let content: Content
    /// Prompt automatically only after returning from the background. The Face ID sheet itself makes the
    /// app inactive, so prompting on every return to active would repeat after the user cancels.
    @State private var promptOnActive = false

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    private var lockEnabled: Bool { settings.first?.requireBiometricUnlock ?? false }

    var body: some View {
        ZStack {
            if app.lock.isLocked {
                LockScreenView()
            } else {
                content
            }
            if scenePhase != .active {
                PrivacyCoverView().transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                app.lock.lockIfEnabled(lockEnabled)
                promptOnActive = app.lock.isLocked
            }
            if phase == .active, promptOnActive {
                promptOnActive = false
                Task { await app.lock.unlock() }
            }
        }
        .task { if app.lock.isLocked { await app.lock.unlock() } }
    }
}

struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Label("TallySeam", systemImage: "lock.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

struct LockScreenView: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("TallySeam is Locked").font(.title2.weight(.semibold))
            Button {
                Task { await app.lock.unlock() }
            } label: {
                Label("Unlock with \(app.lock.biometryName)", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.lock.isAuthenticating)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
