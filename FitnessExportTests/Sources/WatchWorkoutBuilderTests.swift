import FitnessSyncKit
import FitnessUI
import Foundation
import WorkoutKit
import XCTest

@testable import FitnessExport

final class WatchWorkoutBuilderTests: XCTestCase {

    private func item(
        slot: String = "long", title: String = "LUNGO 12 km",
        target: String? = "135–148 bpm · 6:15–6:45/km", day: Date = Date()
    ) -> PlanItem {
        PlanItem(
            day: PlanItem.dayFormatter.string(from: day), slot: slot, title: title,
            detail: nil, target: target, done: false, rpe: nil, note: nil
        )
    }

    func testPlanIdentifiersDoNotChangeWithDisplayLanguage() {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        for language in ["en", "it"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            XCTAssertTrue(WatchWorkoutBuilder.canSend(item(slot: "tempo")))
            XCTAssertFalse(WatchWorkoutBuilder.canSend(item(slot: "time")))
        }
    }

    func testOnlyRunningSessionsCanBeSent() {
        XCTAssertTrue(WatchWorkoutBuilder.canSend(item(slot: "long")))
        XCTAssertTrue(WatchWorkoutBuilder.canSend(item(slot: "easy")))
        XCTAssertFalse(WatchWorkoutBuilder.canSend(item(slot: "strength")))
        XCTAssertFalse(WatchWorkoutBuilder.canSend(item(slot: "coach")))
        XCTAssertFalse(WatchWorkoutBuilder.canSend(item(slot: "rest")))
    }

    func testKilometresAreReadFromTheTitle() {
        XCTAssertEqual(WatchWorkoutBuilder.kilometres(from: "LUNGO 12 km"), 12)
        XCTAssertEqual(WatchWorkoutBuilder.kilometres(from: "lungo 16km"), 16)
        XCTAssertEqual(WatchWorkoutBuilder.kilometres(from: "Corsa 8,5 km facile"), 8.5)
        XCTAssertNil(WatchWorkoutBuilder.kilometres(from: "Forza A — rientro"))
    }

    func testMinutesAreReadWhenThereIsNoDistance() {
        XCTAssertEqual(WatchWorkoutBuilder.minutes(from: "Riposo oppure 30 min facili"), 30)
        XCTAssertEqual(WatchWorkoutBuilder.minutes(from: "40′ facili"), 40)
        XCTAssertNil(WatchWorkoutBuilder.minutes(from: "nessun numero utile"))
    }

    func testEveryGoalIsClosed() {

        for title in ["LUNGO 14 km", "Corsa facile", "30 min di recupero"] {
            let goal = WatchWorkoutBuilder.mainGoal(for: item(title: title))
            switch goal {
            case .open:
                XCTFail("obiettivo aperto per “\(title)”")
            default:
                break
            }
        }
    }

    func testHeartRateRangeIsReadFromTheTarget() {
        XCTAssertNotNil(WatchWorkoutBuilder.heartRateAlert(from: "135–148 bpm · 6:15–6:45/km"))
        XCTAssertNotNil(WatchWorkoutBuilder.heartRateAlert(from: "tieni 140-155"))

        XCTAssertNil(WatchWorkoutBuilder.heartRateAlert(from: "6:15–6:45/km"))
        XCTAssertNil(WatchWorkoutBuilder.heartRateAlert(from: "RPE 6"))
        XCTAssertNil(WatchWorkoutBuilder.heartRateAlert(from: nil))
    }

    func testAPastHourIsMovedForward() {
        let calendar = Calendar.current

        let now =
            calendar.date(
                bySettingHour: 23, minute: 0, second: 0, of: Date()
            ) ?? Date()

        let scheduled = WatchWorkoutBuilder.scheduleDate(for: item(), now: now)

        XCTAssertGreaterThan(
            scheduled, now,
            "un allenamento programmato nel passato non compare mai sul Watch"
        )
    }

    func testAFutureDayKeepsItsUsualHour() {
        let tomorrow = Date().addingTimeInterval(86_400)
        let scheduled = WatchWorkoutBuilder.scheduleDate(
            for: item(slot: "long", day: tomorrow), now: Date()
        )
        let hour = Calendar.current.component(.hour, from: scheduled)
        XCTAssertEqual(hour, 9, "il lungo si fa la mattina")

        let easy = WatchWorkoutBuilder.scheduleDate(
            for: item(slot: "easy", day: tomorrow), now: Date()
        )
        XCTAssertEqual(Calendar.current.component(.hour, from: easy), 18)
    }

    func testLongNamesAreTruncatedWhereWeChoose() {
        let long = item(title: String(repeating: "Ripetute lunghe ", count: 6))
        let name = WatchWorkoutBuilder.displayName(for: long)
        XCTAssertLessThanOrEqual(name.count, 40)
        XCTAssertTrue(name.hasSuffix("…"))
    }

    func testTheWorkoutHasWarmupWorkAndCooldown() {
        let workout = WatchWorkoutBuilder.makeWorkout(for: item())

        XCTAssertNotNil(workout.warmup)
        XCTAssertNotNil(workout.cooldown)
        XCTAssertEqual(workout.blocks.count, 1)
        XCTAssertEqual(workout.blocks.first?.steps.count, 1)
        XCTAssertEqual(workout.displayName, "LUNGO 12 km")
        XCTAssertNotNil(
            workout.blocks.first?.steps.first?.step.alert,
            "senza alert il Watch non guida il passo, che è tutto il punto"
        )
    }

    func testASessionWithoutHeartRateStillProducesAValidWorkout() {
        let workout = WatchWorkoutBuilder.makeWorkout(
            for: item(slot: "easy", title: "Corsa facile 30 min", target: "RPE 5")
        )
        XCTAssertEqual(workout.blocks.count, 1)
        XCTAssertNil(workout.blocks.first?.steps.first?.step.alert)
    }
}
