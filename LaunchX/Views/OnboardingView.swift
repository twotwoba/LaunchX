import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissionService = PermissionService.shared

    // Callback to close the window
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .foregroundColor(.blue)
                    .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)

                VStack(spacing: 8) {
                    Text("Welcome to LaunchX")
                        .font(.system(size: 28, weight: .bold))

                    Text(
                        "Your new productivity companion on macOS.\nTo provide the best experience, LaunchX needs a few permissions."
                    )
                    .multilineTextAlignment(.center)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                }
            }
            .padding(.top, 40)

            // Permissions Section
            VStack(alignment: .leading, spacing: 16) {
                Text("Required Permissions")
                    .font(.headline)
                    .padding(.horizontal, 24)

                PermissionSettingsView()
                    .padding(.horizontal, 24)
            }

            Spacer()

            // Footer Action
            VStack(spacing: 16) {
                if !permissionService.isAccessibilityGranted {
                    Text("Accessibility permission is recommended for basic functionality.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Button(action: onFinish) {
                    Text(
                        permissionService.isAccessibilityGranted ? "Get Started" : "Continue Anyway"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
            }
            .padding(.bottom, 40)
        }
        .frame(width: 600, height: 550)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
