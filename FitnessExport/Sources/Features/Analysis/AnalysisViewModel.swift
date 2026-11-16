import FitnessUI
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AnalysisViewModel: ObservableObject {
    struct SummaryMetric: Identifiable, Equatable {
        let title: String
        let value: String
        let symbolName: String

        var id: String { title }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var details: [WorkoutDetailSnapshot] = [] {
        didSet { summaryMetrics = makeSummaryMetrics() }
    }
    @Published private(set) var analysisSeries: [UUID: WorkoutAnalysisSeries] = [:]

    @Published private(set) var summaryMetrics: [SummaryMetric] = []
    @Published private(set) var draftText = ""
    @Published private(set) var didCopy = false
    @Published private(set) var isExporting = false
    @Published var exportedFiles: ExportedFiles?
    @Published var reportFiles: ExportedFiles?
    @Published var uploadJob: UploadJob?
    @Published private(set) var configuredPlatforms: Set<UploadPlatform> = []
    @Published private(set) var uploadedPlatforms: [UUID: Set<UploadPlatform>] = [:]

    @Published var pendingReplace: UploadPlatform?

    let selectedItems: [WorkoutListItem]
    let periodDescription: String

    private let repository: any WorkoutRepository
    private let composer: AnalysisComposer
    private let exportService: FITExportService
    private let uploadService: ActivityUploadService
    private let ledger: UploadLedger
    private var hasLoaded = false
    private var hasUserEdited = false

    init(
        repository: any WorkoutRepository,
        composer: AnalysisComposer,
        selectedItems: [WorkoutListItem],
        periodDescription: String
    ) {
        self.repository = repository
        self.composer = composer
        self.exportService = FITExportService(repository: repository)
        self.ledger = UploadLedger()
        self.uploadService = ActivityUploadService(exportService: exportService, ledger: ledger)
        self.selectedItems = selectedItems
        self.periodDescription = periodDescription
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await refreshPlatformState()
        await load(forceRefresh: false)
    }

    func reloadFromHealth() async {
        hasUserEdited = false
        await load(forceRefresh: true)
    }

    private func load(forceRefresh: Bool) async {
        guard !selectedItems.isEmpty else {
            draftText = AppLanguage.text("Nessuna attività selezionata.")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            details = try await repository.loadDetails(for: selectedItems.map(\.id), forceRefresh: forceRefresh)
            do {
                let series = try await repository.loadAnalysisSeries(for: selectedItems.map(\.id))
                analysisSeries = Dictionary(uniqueKeysWithValues: series.map { ($0.workoutID, $0) })
            } catch {
                analysisSeries = [:]
            }
            if !hasUserEdited {
                draftText = composeText()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoading = false
    }

    func updateDraft(_ text: String) {
        draftText = text
        hasUserEdited = true
        didCopy = false
    }

    func regenerate() {
        draftText = composeText()
        hasUserEdited = false
        didCopy = false
    }

    func copy() {
        UIPasteboard.general.string = draftText
        didCopy = true
    }

    func exportFIT() async {
        guard !selectedItems.isEmpty, !isExporting else { return }
        isExporting = true
        errorMessage = nil
        do {
            let urls = try await exportService.export(workoutIDs: selectedItems.map(\.id))
            exportedFiles = ExportedFiles(urls: urls)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isExporting = false
    }

    func exportReportImages() {
        guard !isLoading, !details.isEmpty else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "FitnessExportReports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            for detail in details {
                for page in [AnalysisReportPage.overview, .details] {
                    if page == .details && !detail.hasIntervals && detail.splits.isEmpty { continue }
                    let content = AnalysisReportPageView(detail: detail, series: analysisSeries[detail.id], page: page)
                        .environment(\.horizontalSizeClass, .regular)
                        .frame(width: 700)
                        .fixedSize(horizontal: false, vertical: true)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1.2
                    guard let image = renderer.uiImage, let data = image.pngData() else { continue }
                    let suffix = page == .overview ? "riepilogo" : "split-intervalli"
                    let identifier = String(detail.id.uuidString.prefix(8))
                    let url = folder.appendingPathComponent(
                        "\(detail.startDate.formatted(.iso8601.year().month().day()))-\(identifier)-\(suffix).png")
                    try data.write(to: url, options: .atomic)
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            reportFiles = ExportedFiles(urls: urls)
            errorMessage = nil
        } catch {
            errorMessage = AppLanguage.format(
                "Impossibile creare le immagini: %@", error.localizedDescription)
        }
    }

    func refreshPlatformState() async {
        var platforms: Set<UploadPlatform> = []
        if IntervalsCredentialsStore().load().isConfigured { platforms.insert(.intervals) }
        if GarminSessionStore().load() != nil { platforms.insert(.garmin) }
        configuredPlatforms = platforms
        uploadedPlatforms = await ledger.all().mapValues { Set($0.keys) }
    }

    func alreadyUploadedCount(to platform: UploadPlatform) -> Int {
        selectedItems.filter { uploadedPlatforms[$0.id]?.contains(platform) == true }.count
    }

    var isUploading: Bool {
        uploadJob?.isRunning == true
    }

    func upload(to platform: UploadPlatform, mode: ActivityUploadService.Mode = .skipUploaded) async {
        guard !selectedItems.isEmpty, !isUploading else { return }
        let job = UploadJob(platform: platform, workouts: selectedItems)
        uploadJob = job
        await uploadService.run(job, workoutIDs: selectedItems.map(\.id), mode: mode)
        await refreshPlatformState()
    }

    func confirmReplace() async {
        guard let platform = pendingReplace else { return }
        pendingReplace = nil
        await upload(to: platform, mode: .replaceUploaded)
    }

    private func makeSummaryMetrics() -> [SummaryMetric] {
        guard !details.isEmpty else { return [] }

        let totalDistance = details.compactMap(\.distanceInMeters).reduce(0, +)
        let totalDuration = details.reduce(0) { $0 + $1.duration }

        var metrics: [SummaryMetric] = [
            SummaryMetric(title: AppLanguage.text("Attività"), value: "\(details.count)", symbolName: "figure.run"),
            SummaryMetric(
                title: AppLanguage.text("Durata"), value: WorkoutFormatting.duration(totalDuration), symbolName: "clock"
            ),
        ]

        if totalDistance > 0 {
            metrics.append(
                SummaryMetric(
                    title: AppLanguage.text("Distanza"), value: WorkoutFormatting.distance(totalDistance) ?? "-",
                    symbolName: "point.topleft.down.to.point.bottomright.curvepath"))
            if let pace = WorkoutFormatting.pace(distanceInMeters: totalDistance, duration: totalDuration) {
                metrics.append(
                    SummaryMetric(title: AppLanguage.text("Passo medio"), value: pace, symbolName: "speedometer"))
            }
        }

        if let heartRate = durationWeightedAverage(of: \.averageHeartRate) {
            metrics.append(
                SummaryMetric(
                    title: AppLanguage.text("FC media"), value: WorkoutFormatting.heartRate(heartRate) ?? "-",
                    symbolName: "heart.fill"))
        }

        if let cadence = durationWeightedAverage(of: \.averageCadence) {
            metrics.append(
                SummaryMetric(
                    title: AppLanguage.text("Cadenza"), value: WorkoutFormatting.cadence(cadence) ?? "-",
                    symbolName: "metronome"))
        }

        return metrics
    }

    private func composeText() -> String {
        composer.compose(
            details: details, selectedItems: selectedItems, periodDescription: periodDescription,
            seriesByWorkout: analysisSeries)
    }

    var leadMetrics: [SummaryMetric] {
        let preferred = summaryMetrics.filter {
            $0.title == AppLanguage.text("Distanza") || $0.title == AppLanguage.text("Passo medio")
        }
        return preferred.count == 2 ? preferred : Array(summaryMetrics.prefix(2))
    }

    var workoutsWithoutHeartRate: Int {
        details.filter { !$0.hasHeartRateData }.count
    }

    var missingWorkouts: Int {
        max(0, selectedItems.count - details.count)
    }

    private func durationWeightedAverage(of keyPath: KeyPath<WorkoutDetailSnapshot, Double?>) -> Double? {
        let pairs = details.compactMap { detail -> (Double, Double)? in
            guard let value = detail[keyPath: keyPath] else { return nil }
            return (value, max(detail.duration, 1))
        }
        guard !pairs.isEmpty else { return nil }
        let totalWeight = pairs.reduce(0) { $0 + $1.1 }
        return pairs.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
    }
}
