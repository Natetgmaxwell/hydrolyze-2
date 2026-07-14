import SwiftUI

/// SwimmerSheetView — add/edit swimmer presented as .sheet().
/// Pre-fills on edit from swimmerId param via .task.
struct SwimmerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager
    @StateObject private var viewModel = SwimmerSheetViewModel()

    let swimmerId: String?
    let onSave: (() -> Void)?

    init(swimmerId: String?, onSave: (() -> Void)? = nil) {
        self.swimmerId = swimmerId
        self.onSave = onSave
    }

    private var coachId: String? { authManager.coachId }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgBase.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        firstNameField
                        lastNameField
                        birthdateField
                        genderField
                        mainStrokeField
                        formStrokeField
                        if !viewModel.availableGroups.isEmpty { groupsSection }
                        notesField
                    }
                    .padding(24)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(viewModel.isEdit ? "Edit Swimmer" : "Add Swimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if viewModel.isDirty {
                            showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(Color.accentCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            if await viewModel.save(coachId: coachId) {
                                dismiss()
                            }
                        }
                    }
                    .foregroundColor(viewModel.canSave ? Color.accentCyan : Color.textFaint)
                    .disabled(!viewModel.canSave)
                }
            }
            .alert("Discard Changes?", isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .task {
                viewModel.onSave = onSave
                await viewModel.load(swimmerId: swimmerId, coachId: coachId)
            }
        }
    }

    private var firstNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIRST NAME *")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            TextField("", text: $viewModel.firstName)
                .font(.system(size: 17))
                .foregroundColor(Color.textPrimary)
                .padding(12)
                .background(Color.bgInset)
                .cornerRadius(8)
                .onChange(of: viewModel.firstName) { _, _ in viewModel.isDirty = true }
        }
    }

    private var lastNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST NAME")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            TextField("", text: $viewModel.lastName)
                .font(.system(size: 17))
                .foregroundColor(Color.textPrimary)
                .padding(12)
                .background(Color.bgInset)
                .cornerRadius(8)
                .onChange(of: viewModel.lastName) { _, _ in viewModel.isDirty = true }
        }
    }

    private var birthdateField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BIRTHDATE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            Button {
                showDatePicker = true
            } label: {
                HStack {
                    Text(viewModel.hasBirthdate ? formatDate(viewModel.birthdate) : "Tap to set")
                        .font(.system(size: 17))
                        .foregroundColor(viewModel.hasBirthdate ? Color.textPrimary : Color.textFaint)
                    Spacer()
                    Image(systemName: "calendar")
                        .foregroundColor(Color.textFaint)
                }
                .padding(12)
                .background(Color.bgInset)
                .cornerRadius(8)
            }
            .sheet(isPresented: $showDatePicker) {
                DatePickerSheet(selectedDate: $viewModel.birthdate, hasDate: $viewModel.hasBirthdate)
            }
            .onChange(of: viewModel.birthdate) { _, _ in viewModel.isDirty = true }
        }
    }

    private var genderField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GENDER")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            HStack(spacing: 8) {
                ForEach(["M", "F", "X"], id: \.self) { g in
                    Button {
                        viewModel.gender = g
                        viewModel.isDirty = true
                    } label: {
                        Text(g == "X" ? "—" : g)
                            .font(.bodyEmphasis)
                            .foregroundColor(viewModel.gender == g ? Color.bgBase : Color.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(viewModel.gender == g ? Color.accentCyan : Color.bgInset)
                            .cornerRadius(8)
                    }
                }
            }
        }
    }

    private var mainStrokeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MAIN STROKE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            Button {
                showMainStrokePicker = true
            } label: {
                HStack {
                    Text(viewModel.mainStroke)
                        .font(.system(size: 17))
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }
                .padding(12)
                .background(Color.bgInset)
                .cornerRadius(8)
            }
            .sheet(isPresented: $showMainStrokePicker) {
                StrokePickerSheet(
                    title: "Main Stroke",
                    strokes: Swimmer.mainStrokeOptions,
                    selectedStroke: $viewModel.mainStroke
                )
            }
            .onChange(of: viewModel.mainStroke) { _, _ in viewModel.isDirty = true }
        }
    }

    private var formStrokeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FORM STROKE")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            Button {
                showFormStrokePicker = true
            } label: {
                HStack {
                    Text(viewModel.formStroke)
                        .font(.system(size: 17))
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textFaint)
                }
                .padding(12)
                .background(Color.bgInset)
                .cornerRadius(8)
            }
            .sheet(isPresented: $showFormStrokePicker) {
                StrokePickerSheet(
                    title: "Form Stroke",
                    strokes: Swimmer.formStrokeOptions,
                    selectedStroke: $viewModel.formStroke
                )
            }
            .onChange(of: viewModel.formStroke) { _, _ in viewModel.isDirty = true }
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GROUPS")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            SwimLayout(spacing: 8) {
                ForEach(viewModel.availableGroups) { group in
                    Button {
                        viewModel.toggleGroup(group.id)
                    } label: {
                        Text(group.name)
                            .font(.captionStrong)
                            .foregroundColor(viewModel.selectedGroupIds.contains(group.id) ? Color.bgBase : Color.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedGroupIds.contains(group.id) ? Color.accentCyan : Color.bgInset)
                            .cornerRadius(16)
                    }
                }
            }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTES")
                .font(.eyebrow)
                .foregroundColor(Color.textFaint)
            TextEditor(text: $viewModel.notes)
                .font(.system(size: 17))
                .foregroundColor(Color.textPrimary)
                .frame(minHeight: 80)
                .padding(8)
                .background(Color.bgInset)
                .cornerRadius(8)
                .onChange(of: viewModel.notes) { _, _ in viewModel.isDirty = true }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    @State private var showDatePicker = false
    @State private var showMainStrokePicker = false
    @State private var showFormStrokePicker = false
    @State private var showDiscardAlert = false
}

/// DatePickerSheet — modal sheet for selecting birthdate.
struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @Binding var hasDate: Bool
    @State private var useDate: Bool = false

    var body: some View {
        NavigationStack {
            VStack {
                Toggle("Has Birthdate", isOn: $useDate)
                    .padding()
                    .onChange(of: useDate) { _, newVal in
                        hasDate = newVal
                        if !newVal { selectedDate = Date() }
                    }
                if useDate {
                    DatePicker("Birthdate", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(Color.accentCyan)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .background(Color.bgBase)
            .navigationTitle("Birthdate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.accentCyan)
                }
            }
        }
        .onAppear { useDate = hasDate }
    }
}

/// SwimLayout — wrap layout for group chips and distance pills (iOS 16+ Layout protocol).
struct SwimLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
