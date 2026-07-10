import XCTest
@testable import RuSwitcherCore

final class EnglishSourceClassifierTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    func testFrequentAndExtendedDictionaryWordsAreDistinct() {
        XCTAssertEqual(EnglishSourceClassifier.classify("use", model: model), .frequent)
        XCTAssertEqual(EnglishSourceClassifier.classify("cyst", model: model), .dictionary)
        XCTAssertEqual(EnglishSourceClassifier.classify("juju", model: model), .dictionary)
    }

    func testPlausibleUnknownEnglishUsesCharacterModel() {
        let word = "contextualizable"
        XCTAssertFalse(model.contains(word, language: "en"))
        XCTAssertFalse(model.isExtendedEnglishWord(word))
        XCTAssertEqual(EnglishSourceClassifier.classify(word, model: model), .plausibleOOV)
    }

    func testWrongLayoutRussianTokensAreEnglishUnlikely() {
        for token in ["ghjnthtnm", "pflybwf", "gblh"] {
            XCTAssertEqual(EnglishSourceClassifier.classify(token, model: model), .unlikely, token)
        }
    }
}
