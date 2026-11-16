import FitnessUI
import Foundation

@MainActor
final class UploadJob: ObservableObject, Identifiable {
    enum ItemState: Equatable {
        case queued

        case checking
        case exporting

        case replacing
        case uploading
        case uploaded(activityID: String?)

        case replaced(activityID: String?)
        case duplicate
        case skipped
        case failed(String)

        var isFinal: Bool {
            switch self {
            case .queued, .checking, .exporting, .replacing, .uploading: return false
            default: return true
            }
        }

        var isSuccess: Bool {
            switch self {
            case .uploaded, .replaced, .duplicate, .skipped: return true
            default: return false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        let subtitle: String
        let startDate: Date
        var state: ItemState = .queued
    }

    let id = UUID()
    let platform: UploadPlatform
    @Published private(set) var items: [Item]
    @Published private(set) var isRunning = true
    @Published private(set) var fatalError: String?
    @Published private(set) var isCancelled = false

    init(platform: UploadPlatform, workouts: [WorkoutListItem]) {
        self.platform = platform
        items = workouts.map { workout in
            Item(
                id: workout.id,
                title: "\(workout.activityType.title) · \(WorkoutFormatting.shortDate(workout.startDate))",
                subtitle: [
                    WorkoutFormatting.duration(workout.duration), WorkoutFormatting.distance(workout.distanceInMeters),
                ]
                .compactMap { $0 }.joined(separator: " · "),
                startDate: workout.startDate
            )
        }
    }

    var completedCount: Int { items.filter { $0.state.isFinal }.count }
    var uploadedCount: Int {
        items.filter {
            switch $0.state {
            case .uploaded, .replaced: return true
            default: return false
            }
        }.count
    }
    var replacedCount: Int { items.filter { if case .replaced = $0.state { return true } else { return false } }.count }
    var duplicateCount: Int { items.filter { $0.state == .duplicate }.count }
    var skippedCount: Int { items.filter { $0.state == .skipped }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var progress: Double { items.isEmpty ? 1 : Double(completedCount) / Double(items.count) }

    func startDate(of id: UUID) -> Date? {
        items.first { $0.id == id }?.startDate
    }

    func update(_ id: UUID, to state: ItemState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    func finish(fatalError: String? = nil) {
        self.fatalError = fatalError
        isRunning = false

        for index in items.indices where !items[index].state.isFinal {
            items[index].state = .failed(fatalError ?? AppLanguage.text("Non eseguito"))
        }
    }

    func cancel() {
        isCancelled = true
    }
}
