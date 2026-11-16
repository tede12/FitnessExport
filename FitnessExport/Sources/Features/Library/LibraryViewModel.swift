import FitnessUI
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    enum SortOrder: String, CaseIterable, Identifiable {
        case newest
        case longest
        case farthest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newest: return AppLanguage.text("Più recenti")
            case .longest: return AppLanguage.text("Più lunghi (durata)")
            case .farthest: return AppLanguage.text("Più lunghi (distanza)")
            }
        }
    }

    @Published private(set) var snapshot: WorkoutIndexSnapshot = .empty {
        didSet {
            rebuildSearchIndex()
            recomputeVisible()
        }
    }
    @Published private(set) var selectedMonths: Set<WorkoutMonthKey> = [] { didSet { recomputeVisible() } }
    @Published var isCustomPeriodEnabled = false { didSet { recomputeVisible() } }
    @Published var customStartDate: Date { didSet { recomputeVisible() } }
    @Published var customEndDate: Date { didSet { recomputeVisible() } }
    @Published private(set) var selectedActivityTypes: Set<WorkoutActivityType> = [.running] {
        didSet { recomputeVisible() }
    }
    @Published private(set) var selectedWorkoutIDs: Set<UUID> = []
    @Published private(set) var isLoadingCache = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCompletedRefresh = false

    @Published var searchText = "" { didSet { recomputeVisible() } }
    @Published var minDistanceKm: Double? { didSet { recomputeVisible() } }
    @Published var minDurationMinutes: Int? { didSet { recomputeVisible() } }
    @Published var showOnlyWithHeartRate = false { didSet { recomputeVisible() } }
    @Published var showOnlyNotUploaded = false { didSet { recomputeVisible() } }
    @Published var sortOrder: SortOrder = .newest { didSet { recomputeVisible() } }

    @Published private(set) var visibleWorkouts: [WorkoutListItem] = []

    @Published private(set) var activityCounts: [WorkoutActivityType: Int] = [:]

    @Published private(set) var isExporting = false
    @Published var exportedFiles: ExportedFiles?
    @Published var uploadJob: UploadJob?
    @Published private(set) var configuredPlatforms: Set<UploadPlatform> = []
    @Published private(set) var uploadedPlatforms: [UUID: Set<UploadPlatform>] = [:] {
        didSet { if showOnlyNotUploaded { recomputeVisible() } }
    }
    @Published private(set) var uploadRecords: UploadLedger.Entries = [:]

    @Published var pendingReplace: ReplaceRequest?

    struct ReplaceRequest: Identifiable, Equatable {

        let workoutIDs: [UUID]
        let replacedCount: Int
        let platform: UploadPlatform

        let uploadedAt: Date?

        var id: String { workoutIDs.map(\.uuidString).joined() + platform.rawValue }
    }

    static let distanceOptions: [Double] = [3, 5, 10, 21.1, 42.2]
    static let durationOptions: [Int] = [20, 30, 45, 60, 90, 120]

    private let repository: any WorkoutRepository
    private let exportService: FITExportService
    private let uploadService: ActivityUploadService
    private let ledger: UploadLedger
    private var hasBootstrapped = false

    private var searchIndex: [UUID: String] = [:]
    private var searchIndexTask: Task<Void, Never>?

    init(repository: any WorkoutRepository, ledger: UploadLedger = UploadLedger()) {
        self.repository = repository
        self.ledger = ledger
        exportService = FITExportService(repository: repository)
        uploadService = ActivityUploadService(exportService: exportService, ledger: ledger)
        let now = Date()
        let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        customStartDate = previousMonth
        customEndDate = now
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        isLoadingCache = true
        await refreshPlatformState()
        snapshot = await repository.loadIndex()
        hydrateDefaultPeriod()
        sanitizeSelection()
        isLoadingCache = false
    }

    func refreshIndex() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil

        do {
            snapshot = try await repository.refreshIndex()
            hydrateDefaultPeriod()
            sanitizeSelection()
            hasCompletedRefresh = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isRefreshing = false
    }

    func refreshPlatformState() async {
        var platforms: Set<UploadPlatform> = []
        if IntervalsCredentialsStore().load().isConfigured { platforms.insert(.intervals) }
        if GarminSessionStore().load() != nil { platforms.insert(.garmin) }
        configuredPlatforms = platforms
        uploadRecords = await ledger.all()
        uploadedPlatforms = uploadRecords.mapValues { Set($0.keys) }
    }

    func toggleMonth(_ month: WorkoutMonthKey) {
        isCustomPeriodEnabled = false
        var updated = selectedMonths
        if updated.contains(month), updated.count > 1 {
            updated.remove(month)
        } else {
            updated.insert(month)
        }
        selectedMonths = updated
        sanitizeSelection()
    }

    func selectAllMonths() {
        selectedMonths = Set(snapshot.availableMonths)
        isCustomPeriodEnabled = false
        sanitizeSelection()
    }

    func selectLatestMonthOnly() {
        if let latest = snapshot.availableMonths.first {
            selectedMonths = [latest]
        }
        isCustomPeriodEnabled = false
        sanitizeSelection()
    }

    func enableCustomPeriod() {
        isCustomPeriodEnabled = true
        sanitizeSelection()
    }

    func updateCustomDates(start: Date? = nil, end: Date? = nil) {
        if let start {
            customStartDate = start
        }
        if let end {
            customEndDate = end
        }
        if customEndDate < customStartDate {
            customEndDate = customStartDate
        }
        sanitizeSelection()
    }

    func toggleActivity(_ activity: WorkoutActivityType) {
        var updated = selectedActivityTypes
        if selectedActivityTypes.contains(activity), selectedActivityTypes.count > 1 {
            updated.remove(activity)
        } else {
            updated.insert(activity)
        }
        selectedActivityTypes = updated
        sanitizeSelection()
    }

    func toggleSelection(for workoutID: UUID) {
        var updated = selectedWorkoutIDs
        if updated.contains(workoutID) {
            updated.remove(workoutID)
        } else {
            updated.insert(workoutID)
        }
        selectedWorkoutIDs = updated
    }

    func selectAllVisible() {
        var updated = selectedWorkoutIDs
        for item in visibleWorkouts { updated.insert(item.id) }
        selectedWorkoutIDs = updated
    }

    func clearVisibleSelection() {
        var updated = selectedWorkoutIDs
        for item in visibleWorkouts { updated.remove(item.id) }
        selectedWorkoutIDs = updated
    }

    var hasActiveFilters: Bool {
        minDistanceKm != nil || minDurationMinutes != nil || showOnlyWithHeartRate || showOnlyNotUploaded
            || sortOrder != .newest
    }

    var activeFilterCount: Int {
        [
            minDistanceKm != nil, minDurationMinutes != nil, showOnlyWithHeartRate, showOnlyNotUploaded,
            sortOrder != .newest,
        ]
        .filter { $0 }.count
    }

    func clearFilters() {
        minDistanceKm = nil
        minDurationMinutes = nil
        showOnlyWithHeartRate = false
        showOnlyNotUploaded = false
        sortOrder = .newest
        searchText = ""
    }

    private func rebuildSearchIndex() {
        let items = snapshot.items
        searchIndexTask?.cancel()
        searchIndexTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: items.map { ($0.id, Self.searchHaystack(for: $0)) })
            }.value
            guard !Task.isCancelled, let self else { return }
            searchIndex = index
        }
    }

    private func recomputeVisible() {
        let scoped = WorkoutFilter.filter(
            items: snapshot.items, period: currentPeriod, activityTypes: Set(WorkoutActivityType.allCases))
        activityCounts = scoped.reduce(into: [:]) { counts, item in counts[item.activityType, default: 0] += 1 }

        var items = scoped.filter { selectedActivityTypes.contains($0.activityType) }

        let terms = Self.searchTerms(searchText)
        if !terms.isEmpty {
            items = items.filter { item in
                Self.matches(haystack: searchIndex[item.id] ?? Self.searchHaystack(for: item), terms: terms)
            }
        }
        if let minDistanceKm {
            items = items.filter { ($0.distanceInMeters ?? 0) >= minDistanceKm * 1_000 }
        }
        if let minDurationMinutes {
            items = items.filter { $0.duration >= Double(minDurationMinutes) * 60 }
        }
        if showOnlyWithHeartRate {
            items = items.filter(\.hasHeartRateData)
        }
        if showOnlyNotUploaded {
            items = items.filter { (uploadedPlatforms[$0.id] ?? []).isEmpty }
        }

        switch sortOrder {
        case .newest:
            visibleWorkouts = items
        case .longest:
            visibleWorkouts = items.sorted { $0.duration > $1.duration }
        case .farthest:
            visibleWorkouts = items.sorted { ($0.distanceInMeters ?? 0) > ($1.distanceInMeters ?? 0) }
        }
    }

    nonisolated static func matches(_ item: WorkoutListItem, query: String) -> Bool {
        matches(haystack: searchHaystack(for: item), terms: searchTerms(query))
    }

    nonisolated static func searchHaystack(for item: WorkoutListItem) -> String {
        let dates = ["en", "it"].flatMap { language in
            let locale = Locale(identifier: language)
            return [
                item.startDate.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)),
                item.startDate.formatted(.dateTime.month(.wide).year().locale(locale)),
            ]
        }
        return
            ([
                item.activityType.searchNames,
                WorkoutFormatting.distance(item.distanceInMeters) ?? "",
                WorkoutFormatting.duration(item.duration),
            ] + dates)
            .joined(separator: " ")
            .replacingOccurrences(of: ",", with: ".")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated static func searchTerms(_ query: String) -> [String] {
        query
            .replacingOccurrences(of: ",", with: ".")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(separator: " ")
            .map(String.init)
    }

    nonisolated static func matches(haystack: String, terms: [String]) -> Bool {
        terms.allSatisfy { haystack.contains($0) }
    }

    func exportFIT(workoutIDs: [UUID]? = nil) async {
        let ids = workoutIDs ?? selectedWorkouts.map(\.id)
        guard !ids.isEmpty, !isExporting else { return }
        isExporting = true
        errorMessage = nil
        do {
            let urls = try await exportService.export(workoutIDs: ids)
            exportedFiles = ExportedFiles(urls: urls)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isExporting = false
    }

    var isUploading: Bool {
        uploadJob?.isRunning == true
    }

    func upload(
        workoutIDs: [UUID]? = nil, to platform: UploadPlatform, mode: ActivityUploadService.Mode = .skipUploaded
    ) async {
        let workouts = workoutIDs.map { ids in snapshot.items.filter { ids.contains($0.id) } } ?? selectedWorkouts
        guard !workouts.isEmpty, !isUploading else { return }
        let job = UploadJob(platform: platform, workouts: workouts)
        uploadJob = job
        await uploadService.run(job, workoutIDs: workouts.map(\.id), mode: mode)
        await refreshPlatformState()
    }

    func uploadedPlatforms(for workoutID: UUID) -> [UploadPlatform] {
        UploadPlatform.allCases.filter { uploadedPlatforms[workoutID]?.contains($0) == true }
    }

    func alreadyUploadedCount(to platform: UploadPlatform) -> Int {
        selectedWorkouts.filter { uploadedPlatforms[$0.id]?.contains(platform) == true }.count
    }

    func requestReplace(workoutIDs: [UUID]? = nil, platform: UploadPlatform) {
        let ids = workoutIDs ?? selectedWorkouts.map(\.id)
        let replaced = ids.filter { uploadedPlatforms[$0]?.contains(platform) == true }
        guard !ids.isEmpty else { return }
        pendingReplace = ReplaceRequest(
            workoutIDs: ids,
            replacedCount: replaced.count,
            platform: platform,
            uploadedAt: ids.count == 1 ? uploadRecords[ids[0]]?[platform]?.date : nil
        )
    }

    func confirmReplace() async {
        guard let request = pendingReplace else { return }
        pendingReplace = nil
        await upload(workoutIDs: request.workoutIDs, to: request.platform, mode: .replaceUploaded)
    }

    var currentPeriod: WorkoutPeriod {
        if isCustomPeriodEnabled {
            return .custom(start: customStartDate.startOfDay, end: customEndDate.endOfDay)
        }
        return .months(selectedMonths)
    }

    var hasMultipleMonthSelection: Bool {
        selectedMonths.count > 1
    }

    var monthSelectionSummary: String {
        WorkoutFormatting.monthSelectionLabel(selectedMonths)
    }

    var areAllMonthsSelected: Bool {
        !snapshot.availableMonths.isEmpty && selectedMonths == Set(snapshot.availableMonths)
    }

    var canSelectAllMonths: Bool {
        snapshot.availableMonths.count > 1 && !areAllMonthsSelected
    }

    var canReduceToLatestMonth: Bool {
        snapshot.availableMonths.count > 1 && selectedMonths != latestMonthSelection
    }

    private var latestMonthSelection: Set<WorkoutMonthKey> {
        guard let latest = snapshot.availableMonths.first else { return [] }
        return [latest]
    }

    var selectedWorkouts: [WorkoutListItem] {
        visibleWorkouts.filter { selectedWorkoutIDs.contains($0.id) }
    }

    var areAllVisibleSelected: Bool {
        !visibleWorkouts.isEmpty && visibleWorkouts.allSatisfy { selectedWorkoutIDs.contains($0.id) }
    }

    var showsPermissionHint: Bool {
        hasCompletedRefresh && !isRefreshing && errorMessage == nil && snapshot.items.isEmpty
    }

    var analysisPeriodDescription: String {
        if isCustomPeriodEnabled {
            return WorkoutFormatting.dateRange(start: customStartDate, end: customEndDate)
        }
        return WorkoutFormatting.monthSelectionLabel(selectedMonths)
    }

    func activityCount(for activity: WorkoutActivityType) -> Int {
        activityCounts[activity] ?? 0
    }

    var availableActivityTypes: [WorkoutActivityType] {
        let present = Set(snapshot.items.map(\.activityType))
        return WorkoutActivityType.allCases.filter { present.contains($0) }
    }

    var indexStatusTitle: String {
        if isRefreshing {
            return AppLanguage.text("Indicizzazione in corso")
        }
        if snapshot.updatedAt != nil {
            return AppLanguage.text("Indice aggiornato")
        }
        return AppLanguage.text("Indice non ancora creato")
    }

    var indexStatusSubtitle: String {
        if isRefreshing {
            return AppLanguage.text("Lettura degli allenamenti da Salute…")
        }
        if let updatedAt = snapshot.updatedAt {
            return AppLanguage.format(
                "%@ attività · aggiornato %@", snapshot.items.count,
                WorkoutFormatting.workoutDate(updatedAt))
        }
        return AppLanguage.text("Leggi gli allenamenti da Salute per iniziare.")
    }

    private func hydrateDefaultPeriod() {
        selectedMonths = selectedMonths.intersection(Set(snapshot.availableMonths))
        if selectedMonths.isEmpty, let first = snapshot.availableMonths.first {
            selectedMonths = [first]
        }
        if selectedMonths.isEmpty {
            selectedMonths = latestMonthSelection
        }
        if let newestDate = snapshot.items.first?.startDate {
            customEndDate = newestDate
            customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: newestDate) ?? newestDate
        }
    }

    private func sanitizeSelection() {
        selectedWorkoutIDs = Set(selectedWorkoutIDs.intersection(Set(visibleWorkouts.map(\.id))))
    }
}

extension Date {
    fileprivate var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    fileprivate var endOfDay: Date {
        Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) ?? self
    }
}
