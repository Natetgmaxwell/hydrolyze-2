import SwiftUI

/// SwimmerRow — single row in the swimmers list.
/// 44pt initials circle + name + chevron. Long-press → delete, swipe-left → archive.
struct SwimmerRow: View {
    let swimmer: Swimmer
    let onDelete: () -> Void
    let onArchive: () -> Void

    private var initials: String {
        let first = swimmer.firstName.prefix(1)
        let last = (swimmer.lastName ?? "").prefix(1)
        if last.isEmpty { return String(swimmer.firstName.prefix(2)).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            // 44pt initials circle — elevated surface with cyan text
            Text(initials)
                .font(.bodyEmphasis)
                .foregroundColor(Color.accentCyan)
                .frame(width: 44, height: 44)
                .background(Color.bgInset)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.divider, lineWidth: 1))

            Text(swimmer.fullName)
                .font(.bodyEmphasis)
                .foregroundColor(Color.textPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.bgRaised)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.divider, lineWidth: 1)
        )
        // Long-press = delete (SwiftUI .contextMenu is idiomatic, but spec calls for alert)
        .contentShape(Rectangle())
    }
}

#Preview {
    SwimmerRow(
        swimmer: Swimmer(id: "1", coachId: "c1", firstName: "Alex", lastName: "Brown", birthdate: nil, gender: nil, notes: nil, preferredGear: nil, formStroke: nil, archivedAt: nil, createdAt: nil),
        onDelete: {},
        onArchive: {}
    )
    .background(Color.bgBase)
}