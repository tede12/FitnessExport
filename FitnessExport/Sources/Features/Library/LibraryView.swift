import FitnessUI
import SwiftUI

struct LibraryView: View {
    @StateObject var viewModel: LibraryViewModel
    @State private var isAnalysisPresented = false
    @State private var isSettingsPresented = false
    @State private var detailItem: WorkoutListItem?

    private let analysisComposer: AnalysisComposer
    private let repository: any WorkoutRepository

    init(
        viewModel: LibraryViewModel,
        analysisComposer: AnalysisComposer,
        repository: any WorkoutRepository
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.analysisComposer = analysisComposer
        self.repository = repository
    }

    var body: some View {
        NavigationStack {
            List {
                indexSection
                if !viewModel.snapshot.items.isEmpty {
                    periodSection
                    activitySection
                    workoutSection
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(AppLanguage.text("Allenamenti"))
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: AppLanguage.text("Cerca: corsa, 10 km, 12 mar…")
            )
            .navigationDestination(item: $detailItem) { item in
                WorkoutDetailView(item: item, repository: repository)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settings.button")
                    .accessibilityLabel(AppLanguage.text("Impostazioni"))
                    NavigationLink {
                        TrendsView(repository: repository)
                    } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    .accessibilityIdentifier("trends.button")
                    .accessibilityLabel(AppLanguage.text("Andamento"))
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    filterMenu
                    Button {
                        Task { await viewModel.refreshIndex() }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isRefreshing)
                    .accessibilityIdentifier("index.refresh.button")
                    .accessibilityLabel(AppLanguage.text("Aggiorna indice"))
                }
            }
            .refreshable {
                await viewModel.refreshIndex()
            }
            .task {
                await viewModel.bootstrapIfNeeded()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.snapshot.items.isEmpty {
                    actionBar
                }
            }
            .sheet(item: $viewModel.exportedFiles) { files in
                ShareSheet(items: files.urls)
            }
            .sheet(isPresented: $isSettingsPresented, onDismiss: { Task { await viewModel.refreshPlatformState() } }) {
                SettingsView()
            }
            .sheet(item: $viewModel.uploadJob) { job in
                UploadProgressView(job: job)
            }
            .confirmationDialog(
                viewModel.pendingReplace.map {
                    $0.workoutIDs.count == 1
                        ? AppLanguage.text("Allenamento già caricato") : AppLanguage.text("Sostituire i caricamenti?")
                } ?? "",
                isPresented: Binding(
                    get: { viewModel.pendingReplace != nil },
                    set: { if !$0 { viewModel.pendingReplace = nil } }
                ),
                titleVisibility: .visible,
                presenting: viewModel.pendingReplace
            ) { _ in
                Button(AppLanguage.text("Elimina e ricarica"), role: .destructive) {
                    Task { await viewModel.confirmReplace() }
                }
                Button(AppLanguage.text("Annulla"), role: .cancel) { viewModel.pendingReplace = nil }
            } message: { request in
                Text(replaceMessage(for: request))
            }
            .sheet(isPresented: $isAnalysisPresented, onDismiss: { Task { await viewModel.refreshPlatformState() } }) {
                AnalysisView(
                    viewModel: AnalysisViewModel(
                        repository: repository,
                        composer: analysisComposer,
                        selectedItems: viewModel.selectedWorkouts,
                        periodDescription: viewModel.analysisPeriodDescription
                    )
                )
            }
        }
        .tint(Brand.ink)
    }

    private var filterMenu: some View {
        Menu {
            Picker(AppLanguage.text("Ordina"), selection: $viewModel.sortOrder) {
                ForEach(LibraryViewModel.SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }

            Menu(AppLanguage.text("Distanza minima")) {
                Picker(AppLanguage.text("Distanza minima"), selection: $viewModel.minDistanceKm) {
                    Text(AppLanguage.text("Qualsiasi")).tag(Double?.none)
                    ForEach(LibraryViewModel.distanceOptions, id: \.self) { km in
                        Text(km.formatted(.number.precision(.fractionLength(0...1))) + " km").tag(Double?.some(km))
                    }
                }
            }

            Menu(AppLanguage.text("Durata minima")) {
                Picker(AppLanguage.text("Durata minima"), selection: $viewModel.minDurationMinutes) {
                    Text(AppLanguage.text("Qualsiasi")).tag(Int?.none)
                    ForEach(LibraryViewModel.durationOptions, id: \.self) { minutes in
                        Text(
                            minutes >= 60
                                ? "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")"
                                : "\(minutes) min"
                        ).tag(Int?.some(minutes))
                    }
                }
            }

            Toggle(AppLanguage.text("Solo con frequenza cardiaca"), isOn: $viewModel.showOnlyWithHeartRate)
            Toggle(AppLanguage.text("Solo non ancora caricati"), isOn: $viewModel.showOnlyNotUploaded)

            if viewModel.hasActiveFilters || !viewModel.searchText.isEmpty {
                Divider()
                Button(role: .destructive) {
                    viewModel.clearFilters()
                } label: {
                    Label(AppLanguage.text("Azzera filtri"), systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(
                systemName: viewModel.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("filters.button")
        .accessibilityLabel(
            viewModel.hasActiveFilters
                ? AppLanguage.format("Filtri, %@ attivi", viewModel.activeFilterCount)
                : AppLanguage.text("Filtri"))
    }

    @ViewBuilder
    private var indexSection: some View {
        Section {
            if viewModel.snapshot.items.isEmpty {
                EmptyIndexView(isRefreshing: viewModel.isRefreshing) {
                    Task { await viewModel.refreshIndex() }
                }
            } else {
                IndexStatusRow(
                    title: viewModel.indexStatusTitle,
                    subtitle: viewModel.indexStatusSubtitle,
                    isRefreshing: viewModel.isRefreshing,
                    isReady: viewModel.snapshot.updatedAt != nil
                )
            }

            if let errorMessage = viewModel.errorMessage {
                StatusBanner(
                    kind: .error, title: AppLanguage.text("Lettura da Salute non riuscita"), message: errorMessage
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if viewModel.showsPermissionHint {
                StatusBanner(
                    kind: .warning,
                    title: AppLanguage.text("Nessun allenamento trovato in Salute"),
                    message: AppLanguage.text(
                        "Se hai allenamenti registrati, controlla che FitnessExport abbia i permessi di lettura in Impostazioni ▸ Salute ▸ Accesso ai dati."
                    )
                ) {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Link(AppLanguage.text("Apri Impostazioni"), destination: settingsURL)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
        } header: {
            if !viewModel.snapshot.items.isEmpty {
                Text(AppLanguage.text("Indice"))
            }
        }
    }

    private var periodSection: some View {
        Section {
            ChipRow {
                ForEach(viewModel.snapshot.availableMonths) { month in
                    FilterChip(
                        title: WorkoutFormatting.monthLabel(month),
                        isSelected: !viewModel.isCustomPeriodEnabled && viewModel.selectedMonths.contains(month)
                    ) {
                        viewModel.toggleMonth(month)
                    }
                    .accessibilityIdentifier("period.month.\(month.id)")
                }

                FilterChip(
                    title: AppLanguage.text("Personalizzato"),
                    symbolName: "calendar",
                    isSelected: viewModel.isCustomPeriodEnabled
                ) {
                    viewModel.enableCustomPeriod()
                }
                .accessibilityIdentifier("period.custom.button")
            }
            .listRowInsets(EdgeInsets())

            if viewModel.isCustomPeriodEnabled {
                DatePicker(
                    "Da",
                    selection: Binding(
                        get: { viewModel.customStartDate },
                        set: { viewModel.updateCustomDates(start: $0) }
                    ),
                    displayedComponents: .date
                )
                .accessibilityIdentifier("period.custom.start")

                DatePicker(
                    "A",
                    selection: Binding(
                        get: { viewModel.customEndDate },
                        set: { viewModel.updateCustomDates(end: $0) }
                    ),
                    in: viewModel.customStartDate...,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("period.custom.end")
            }
        } header: {
            HStack {
                Text(AppLanguage.text("Periodo"))
                Spacer()
                if viewModel.canSelectAllMonths {
                    Button(AppLanguage.text("Tutti")) { viewModel.selectAllMonths() }
                }
                if viewModel.canReduceToLatestMonth {
                    Button(AppLanguage.text("Solo ultimo")) { viewModel.selectLatestMonthOnly() }
                }
            }
            .font(.footnote)
            .textCase(nil)
        } footer: {
            if !viewModel.isCustomPeriodEnabled, viewModel.hasMultipleMonthSelection {
                Text(viewModel.monthSelectionSummary)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if !viewModel.availableActivityTypes.isEmpty {
            Section(AppLanguage.text("Attività")) {
                ChipRow {
                    ForEach(viewModel.availableActivityTypes, id: \.self) { activity in
                        FilterChip(
                            title: activity.title,
                            symbolName: activity.symbolName,
                            count: viewModel.activityCount(for: activity),
                            isSelected: viewModel.selectedActivityTypes.contains(activity)
                        ) {
                            viewModel.toggleActivity(activity)
                        }
                        .accessibilityIdentifier("activity.\(activity.rawValue).chip")
                    }
                }
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private var workoutSection: some View {
        Section {
            if viewModel.visibleWorkouts.isEmpty {
                ContentUnavailableView {
                    Label(AppLanguage.text("Nessuna attività"), systemImage: "figure.run.circle")
                } description: {
                    Text(emptyStateDescription)
                } actions: {
                    if viewModel.hasActiveFilters || !viewModel.searchText.isEmpty {
                        Button(AppLanguage.text("Azzera filtri")) { viewModel.clearFilters() }
                            .buttonStyle(.bordered)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.visibleWorkouts) { workout in
                    WorkoutRow(
                        workout: workout,
                        isSelected: viewModel.selectedWorkoutIDs.contains(workout.id),
                        uploadedTo: viewModel.uploadedPlatforms(for: workout.id),
                        onToggle: { viewModel.toggleSelection(for: workout.id) },
                        onOpenDetail: { detailItem = workout }
                    )
                    .accessibilityIdentifier("workout.row.\(workout.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            Task { await viewModel.exportFIT(workoutIDs: [workout.id]) }
                        } label: {
                            Label(AppLanguage.text("Esporta .fit"), systemImage: "square.and.arrow.up")
                        }
                        .tint(Brand.ink)
                        Button {
                            detailItem = workout
                        } label: {
                            Label(AppLanguage.text("Dettaglio"), systemImage: "chart.xyaxis.line")
                        }
                        .tint(Color(.systemGray))
                    }
                    .contextMenu {
                        Button {
                            detailItem = workout
                        } label: {
                            Label(AppLanguage.text("Dettaglio e grafici"), systemImage: "chart.xyaxis.line")
                        }
                        Button {
                            Task { await viewModel.exportFIT(workoutIDs: [workout.id]) }
                        } label: {
                            Label(AppLanguage.text("Esporta .fit"), systemImage: "square.and.arrow.up")
                        }
                        ForEach(UploadPlatform.allCases, id: \.self) { platform in
                            if viewModel.configuredPlatforms.contains(platform) {
                                if viewModel.uploadedPlatforms(for: workout.id).contains(platform) {
                                    Button {
                                        viewModel.requestReplace(workoutIDs: [workout.id], platform: platform)
                                    } label: {
                                        Label(
                                            AppLanguage.format("Ricarica su %@…", platform.title),
                                            systemImage: "arrow.triangle.2.circlepath.icloud")
                                    }
                                } else {
                                    Button {
                                        Task { await viewModel.upload(workoutIDs: [workout.id], to: platform) }
                                    } label: {
                                        Label(
                                            AppLanguage.format("Carica su %@", platform.title),
                                            systemImage: "icloud.and.arrow.up")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(AppLanguage.format("Allenamenti (%@)", viewModel.visibleWorkouts.count))
                Spacer()
                Button(
                    viewModel.areAllVisibleSelected
                        ? AppLanguage.text("Deseleziona tutti") : AppLanguage.text("Seleziona tutti")
                ) {
                    if viewModel.areAllVisibleSelected {
                        viewModel.clearVisibleSelection()
                    } else {
                        viewModel.selectAllVisible()
                    }
                }
                .disabled(viewModel.visibleWorkouts.isEmpty)
                .accessibilityIdentifier(
                    viewModel.areAllVisibleSelected ? "selection.clearVisible.button" : "selection.selectVisible.button"
                )
            }
            .font(.footnote)
            .textCase(nil)
        }
    }

    private func replaceMessage(for request: LibraryViewModel.ReplaceRequest) -> String {
        if request.workoutIDs.count == 1 {
            let when = request.uploadedAt.map { " il \(WorkoutFormatting.shortDate($0))" } ?? ""
            return AppLanguage.format(
                "Questo allenamento risulta già su %@%@. La copia caricata verrà eliminata e sostituita con il file generato adesso.",
                request.platform.title, when)
        }
        return AppLanguage.format(
            "%@ allenamenti su %@ risultano già su %@. Le copie caricate verranno eliminate e sostituite con i file generati adesso; gli altri vengono caricati normalmente.",
            request.replacedCount, request.workoutIDs.count,
            request.platform.title)
    }

    private var emptyStateDescription: String {
        if !viewModel.searchText.isEmpty || viewModel.hasActiveFilters {
            return AppLanguage.text("Nessun risultato per la ricerca o i filtri attivi.")
        }
        return AppLanguage.text("Cambia periodo o tipo di attività.")
    }

    private var actionBar: some View {
        let count = viewModel.selectedWorkouts.count
        return HStack(spacing: Brand.Spacing.s) {
            Button {
                isAnalysisPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text(
                        count == 0 ? AppLanguage.text("Seleziona attività") : AppLanguage.count("analyze.count", count)
                    )
                    .contentTransition(.numericText())
                }
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.signal)
            .controlSize(.large)
            .disabled(count == 0)
            .accessibilityIdentifier("analyze.button")

            Button {
                Task { await viewModel.exportFIT() }
            } label: {
                if viewModel.isExporting {
                    ProgressView()
                        .frame(width: 28)
                } else {
                    Text(".fit")
                        .font(.headline)
                        .frame(width: 28)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(count == 0 || viewModel.isExporting)
            .accessibilityIdentifier("exportFit.button")
            .accessibilityLabel(AppLanguage.text("Esporta file .fit"))

            if !viewModel.configuredPlatforms.isEmpty {
                Menu {
                    ForEach(UploadPlatform.allCases, id: \.self) { platform in
                        if viewModel.configuredPlatforms.contains(platform) {
                            Button {
                                Task { await viewModel.upload(to: platform) }
                            } label: {
                                Label(platform.title, systemImage: "icloud.and.arrow.up")
                            }
                        }
                    }

                    let replaceable = UploadPlatform.allCases.filter {
                        viewModel.configuredPlatforms.contains($0) && viewModel.alreadyUploadedCount(to: $0) > 0
                    }
                    if !replaceable.isEmpty {
                        Divider()
                        ForEach(replaceable, id: \.self) { platform in
                            Button(role: .destructive) {
                                viewModel.requestReplace(platform: platform)
                            } label: {
                                Label(
                                    AppLanguage.format(
                                        "Sostituisci %@ su %@…",
                                        viewModel.alreadyUploadedCount(to: platform),
                                        platform.title),
                                    systemImage: "arrow.triangle.2.circlepath.icloud")
                            }
                        }
                    }
                } label: {
                    if viewModel.isUploading {
                        ProgressView()
                            .frame(width: 28)
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.headline)
                            .frame(width: 28)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(count == 0 || viewModel.isUploading)
                .accessibilityIdentifier("upload.menu")
                .accessibilityLabel(AppLanguage.text("Carica su una piattaforma"))
            }
        }
        .frame(maxWidth: 760 - Brand.Spacing.l * 2)
        .padding(.horizontal, Brand.Spacing.l)
        .padding(.vertical, Brand.Spacing.m)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
