import SwiftUI

struct PermissionSettingsView: View {
    @ObservedObject var permissionService = PermissionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统权限")
                    .fontWeight(.semibold)
                Spacer()

                // Overall status
                if permissionService.allPermissionsGranted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("全部已授权")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            // 三个权限一行显示
            HStack(spacing: 12) {
                PermissionBadge(
                    icon: "hand.raised.fill",
                    title: "辅助功能",
                    isGranted: permissionService.isAccessibilityGranted,
                    action: {
                        if permissionService.isAccessibilityGranted {
                            permissionService.openAccessibilitySettings()
                        } else {
                            permissionService.requestAccessibility()
                        }
                    }
                )

                PermissionBadge(
                    icon: "doc.fill",
                    title: "磁盘访问",
                    isGranted: permissionService.isFullDiskAccessGranted,
                    action: { permissionService.requestFullDiskAccess() }
                )

                PermissionBadge(
                    icon: "rectangle.on.rectangle",
                    title: "屏幕录制",
                    isGranted: permissionService.isScreenRecordingGranted,
                    action: {
                        if permissionService.isScreenRecordingGranted {
                            permissionService.openScreenRecordingSettings()
                        } else {
                            permissionService.requestScreenRecording()
                        }
                    }
                )
            }

            Text("这些权限仅用于应用功能，不会收集或传输任何个人数据。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            permissionService.checkAllPermissions()
        }
    }
}

struct PermissionBadge: View {
    let icon: String
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isGranted ? .green : .orange)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                Image(
                    systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundColor(isGranted ? .green : .orange)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(isGranted ? "已授权 - 点击打开系统设置" : "点击授权")
    }
}
