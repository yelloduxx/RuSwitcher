import XCTest
@testable import RuSwitcherCore

final class PersonalizationAdapterTests: XCTestCase {
    func testPositiveAndNegativeFeedbackMoveScoreInOppositeDirections() {
        let delta: [Float] = [1, 0, -1, 0]
        var positive = PersonalizationAdapter(modelVersion: "test", embeddingSize: 4)
        var negative = positive
        positive.update(featureDelta: delta, positive: true, learningRate: 0.2, l2: 0)
        negative.update(featureDelta: delta, positive: false, learningRate: 0.2, l2: 0)
        XCTAssertGreaterThan(positive.score(delta), 0)
        XCTAssertLessThan(negative.score(delta), 0)
        XCTAssertEqual(positive.positiveCount, 1)
        XCTAssertEqual(negative.negativeCount, 1)
    }

    func testMigrationDropsIncompatibleWeights() {
        var adapter = PersonalizationAdapter(modelVersion: "old", embeddingSize: 4)
        adapter.update(featureDelta: [1, 1, 1, 1], positive: true, learningRate: 0.1, l2: 0)
        adapter.migrate(modelVersion: "new", embeddingSize: 3)
        XCTAssertEqual(adapter.modelVersion, "new")
        XCTAssertEqual(adapter.weights, [0, 0, 0])
        XCTAssertEqual(adapter.positiveCount, 0)
    }
}
