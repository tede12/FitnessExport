import FitnessSyncKit
import Foundation
import Observation

@MainActor
@Observable
final class TrainingStore {
    private(set) var briefing: TrainingBriefing?
    private(set) var pendingMarks: [PlanMark] = []

    private let briefingURL: URL
    private let marksURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("org.fitnessexport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        briefingURL = folder.appendingPathComponent("briefing.json")
        marksURL = folder.appendingPathComponent("pending-marks.json")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    var today: [PlanItem] {
        let key = PlanItem.dayFormatter.string(from: Date())
        return merged.filter { $0.day == key }
    }

    var upcoming: [PlanItem] {
        let key = PlanItem.dayFormatter.string(from: Date())
        return merged.filter { $0.day >= key }
    }

    var merged: [PlanItem] {
        guard let plan = briefing?.plan else { return [] }
        let byID = Dictionary(
            pendingMarks.map { ("\($0.day)|\($0.slot)", $0) }, uniquingKeysWith: { _, new in new }
        )
        return plan.map { item in
            guard let mark = byID[item.id] else { return item }
            var updated = item
            updated.done = mark.done
            updated.rpe = mark.rpe ?? item.rpe
            updated.note = mark.note ?? item.note
            return updated
        }
    }

    func sessions(on day: String) -> [SessionSummary] {
        briefing?.week.filter { $0.day == day } ?? []
    }

    func apply(_ briefing: TrainingBriefing) {
        self.briefing = briefing
        try? encoder.encode(briefing).write(to: briefingURL, options: .atomic)
    }

    func mark(_ item: PlanItem, done: Bool, rpe: Int? = nil, note: String? = nil) {
        pendingMarks.removeAll { $0.day == item.day && $0.slot == item.slot }
        pendingMarks.append(
            PlanMark(
                day: item.day, slot: item.slot, done: done,
                rpe: rpe ?? item.rpe, note: note ?? item.note, markedAt: Date()
            )
        )
        persistMarks()
    }

    func clearPendingMarks() {
        pendingMarks = []
        persistMarks()
    }

    private func persistMarks() {
        try? encoder.encode(pendingMarks).write(to: marksURL, options: .atomic)
    }

    private func load() {
        if let data = try? Data(contentsOf: briefingURL) {
            briefing = try? decoder.decode(TrainingBriefing.self, from: data)
        }
        if let data = try? Data(contentsOf: marksURL) {
            pendingMarks = (try? decoder.decode([PlanMark].self, from: data)) ?? []
        }
    }
}
