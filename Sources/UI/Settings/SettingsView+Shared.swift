import SwiftUI

extension SettingsView {
    func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.bottom, 2)
    }
}
