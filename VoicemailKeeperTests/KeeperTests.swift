import CoreImage
import SwiftUI
import XCTest

final class KeeperTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try VaultFiles.temporary() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPaidDownloadKeepsAllFeaturesAvailableWithNoTrialClock() throws {
        XCTAssertFalse(Launch.freePeriod)
        let vault = try makeVault()
        XCTAssertTrue(try vault.state().messages.isEmpty)
        XCTAssertNotNil(try vault.exportFull().stamp)
    }

    func testSupportedFormatsAndOriginalChecksums() async throws {
        let fixtures: [(String, AudioFormat)] = [
            ("Sample.m4a", .m4a), ("Narrow.amr", .amr), ("Wide.amr", .amr),
            ("Tone.wav", .wav), ("Tone.mp3", .mp3), ("Tone.caf", .caf)
        ]
        for (name, format) in fixtures {
            let source = try fixture(name)
            let draft = try await AudioImport.prepare(source)
            XCTAssertEqual(draft.format, format, name)
            XCTAssertGreaterThan(draft.duration, 0, name)
            XCTAssertEqual(draft.hash, try VaultFiles.hash(source), name)
            XCTAssertEqual(try Data(contentsOf: draft.url), try Data(contentsOf: source), name)
        }
    }

    func testAMRNarrowbandAndWidebandDecodeToPCMAndRejectBadFrames() throws {
        for (name, rate) in [("Narrow.amr", 8_000), ("Wide.amr", 16_000)] {
            let pcm = directory.appendingPathComponent(name + ".caf")
            let source = try fixture(name)
            let duration = try AMR.decode(source, to: pcm)
            XCTAssertEqual(duration, 0.24, accuracy: 0.001)
            XCTAssertEqual(try AudioImport.verify(pcm, format: .caf), duration, accuracy: 0.001)
            XCTAssertGreaterThan(try Data(contentsOf: pcm).count, rate / 3)
            let damaged = directory.appendingPathComponent(name)
            try Data(contentsOf: source).dropLast().write(to: damaged)
            XCTAssertThrowsError(try AMR.decode(damaged, to: nil))
        }
    }

    func testBadExtensionAndCorruptAudioAreRejectedAfterCopy() async throws {
        let badExtension = directory.appendingPathComponent("fake.wav")
        try FileManager.default.copyItem(at: fixture("Sample.m4a"), to: badExtension)
        let empty = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        let invalid = directory.appendingPathComponent("broken.caf")
        try Data("caffbroken".utf8).write(to: invalid)
        for file in [badExtension, empty, invalid] {
            do {
                _ = try await AudioImport.prepare(file)
                XCTFail("Expected validation failure: \(file.lastPathComponent)")
            } catch {
                XCTAssertEqual(error as? KeeperError, .corrupt)
            }
        }
        XCTAssertNil(AudioFormat.identify(Data([0, 1, 2, 3])))
        XCTAssertThrowsError(try VaultFiles.requireSpace(at: directory, bytes: Int.max)) {
            XCTAssertEqual($0 as? KeeperError, .disk)
        }
    }

    func testUnknownDateDoesNotBecomeASourceDate() async throws {
        let vault = try makeVault()
        let draft = try await AudioImport.prepare(fixture("Tone.wav"))
        XCTAssertNil(draft.sourceDate)
        let stored = Date(timeIntervalSince1970: 10_000)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
        XCTAssertEqual(try vault.save(draft, choice: .new("A"), note: "", date: nil, zone: nil,
                                      now: stored, zoneAtSave: zone), .saved)
        let message = try XCTUnwrap(vault.state().messages.first)
        XCTAssertNil(message.sourceDate)
        XCTAssertEqual(message.date, stored)
        XCTAssertEqual(message.zone, zone.identifier)
        XCTAssertEqual(AudioImport.sourceTimeZone("2026-11-25T09:00:00+0900"), zone.identifier)
    }

    func testConcurrentDeduplicationAndExplicitCrossPersonSave() async throws {
        let vault = try makeVault()
        let sample = try await AudioImport.prepare(fixture("Sample.m4a"))
        let otherRecording = try await AudioImport.prepare(fixture("Tone.wav"))
        _ = try vault.save(otherRecording, choice: .new("Alex"), note: "", date: nil, zone: nil)
        let person = try XCTUnwrap(vault.state().lastPerson)

        let results = try await withThrowingTaskGroup(of: SaveOutcome.self, returning: [SaveOutcome].self) { group in
            for _ in 0..<5 {
                group.addTask { try vault.save(sample, choice: .existing(person), note: "", date: nil, zone: nil) }
            }
            var values = [SaveOutcome]()
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 == .saved }.count, 1)
        XCTAssertEqual(results.filter { $0 == .duplicate }.count, 4)
        XCTAssertEqual(try vault.save(sample, choice: .new("Alex"), note: "", date: nil, zone: nil), .otherPerson("Alex"))
        XCTAssertEqual(try vault.state().people.count, 1)
        XCTAssertEqual(try vault.save(sample, choice: .new("Alex"), note: "", date: nil, zone: nil, allowOtherPerson: true), .saved)
        let state = try vault.state()
        XCTAssertEqual(state.people.count, 2)
        XCTAssertNil(state.familyMatch(Person(name: " alex ")))
        XCTAssertEqual(state.messages.filter { $0.hash == sample.hash }.count, 2)
        let sameOriginal = state.messages.filter { $0.hash == sample.hash }
        XCTAssertThrowsError(try vault.move(sameOriginal[0].id, to: sameOriginal[1].personID)) {
            XCTAssertEqual($0 as? KeeperError, .duplicate)
        }
        try vault.remove(sameOriginal[0].id)
        XCTAssertEqual(try VaultFiles.hash(vault.originalURL(sameOriginal[1])), sample.hash)
    }

    func testBackupRoundTripPreservesDataAndLocalEdits() async throws {
        let source = try makeVault()
        let target = try makeVault()
        let draft = try await AudioImport.prepare(fixture("Tone.caf"))
        let date = Date(timeIntervalSince1970: 1_000_000)
        _ = try source.save(draft, choice: .new("Alex"), note: "A short note", date: date, zone: "GMT")
        let message = try XCTUnwrap(source.state().messages.first)
        try source.setStar(message.id)
        let file = try source.exportFull()
        XCTAssertNil(try source.stamp(), "Building a package is not a confirmed export.")
        let preview = try target.previewRestore(file.url)
        XCTAssertEqual(preview.plan, RestorePlan(added: 1, duplicates: 0, conflicts: 0))
        XCTAssertTrue(try target.state().messages.isEmpty)
        XCTAssertEqual(try target.restore(preview), preview.plan)
        let restored = try XCTUnwrap(target.state().messages.first)
        XCTAssertTrue(restored.starred)
        XCTAssertEqual(restored.note, "A short note")
        XCTAssertEqual(restored.sourceDate, date)
        XCTAssertEqual(try VaultFiles.hash(target.originalURL(restored)), draft.hash)
        XCTAssertNil(try target.state().milestone)
        XCTAssertNil(try target.state().reviewDay)
        try target.edit(restored.id, person: restored.personID, note: "Local edit", date: nil, zone: nil)
        try target.setStar(restored.id)
        let second = try target.previewRestore(file.url)
        XCTAssertEqual(second.plan.duplicates, 1)
        XCTAssertEqual(second.plan.added, 0)
        _ = try target.restore(second)
        XCTAssertEqual(try target.state().messages.first?.note, "Local edit")
        XCTAssertEqual(try target.state().messages.first?.starred, false)
    }

    func testRestoreConflictsKeepBothPeopleAndRejectStalePreview() async throws {
        let source = try makeVault()
        let target = try makeVault()
        let draft = try await AudioImport.prepare(fixture("Tone.mp3"))
        _ = try source.save(draft, choice: .new(" ＡLEX "), note: "", date: nil, zone: nil)
        let file = try source.exportFull()
        let old = try target.previewRestore(file.url)
        _ = try target.save(draft, choice: .new("Alex"), note: "", date: nil, zone: nil)
        XCTAssertThrowsError(try target.restore(old)) { XCTAssertEqual($0 as? KeeperError, .changed) }
        let fresh = try target.previewRestore(file.url)
        XCTAssertEqual(fresh.plan, RestorePlan(added: 1, duplicates: 0, conflicts: 1))
        _ = try target.restore(fresh)
        XCTAssertEqual(try target.state().people.count, 2)
    }

    func testFamilyPackagesPreserveAudioAndLearnPersonAliases() async throws {
        let source = try makeVault()
        let target = try makeVault()
        let first = try await AudioImport.prepare(fixture("Tone.wav"))
        let second = try await AudioImport.prepare(fixture("Tone.caf"))
        _ = try source.save(first, choice: .new("Mamá"), note: "First", date: nil, zone: nil)
        _ = try target.save(second, choice: .new("mama"), note: "", date: nil, zone: nil)
        let localPerson = try XCTUnwrap(target.state().people.first)
        let message = try XCTUnwrap(source.state().messages.first)
        let sent = try source.exportMessage(message.id, family: true)
        let draft = try await Packages.openFamily(sent.url)
        let remote = try XCTUnwrap(draft.family)
        XCTAssertEqual(draft.hash, first.hash)
        XCTAssertEqual(draft.familyMessage?.note, "First")
        XCTAssertEqual(try target.state().familyMatch(remote), localPerson)
        XCTAssertEqual(try target.save(draft, choice: .existing(localPerson.id), note: "First", date: nil, zone: nil), .saved)
        XCTAssertEqual(try target.state().familyMatch(Person(id: remote.id, name: "Renamed")), localPerson)
        XCTAssertThrowsError(try target.previewRestore(sent.url))
    }

    func testBadZIPAndUnknownVersionLeaveLibraryUntouched() throws {
        let vault = try makeVault()
        let url = directory.appendingPathComponent("Bad.zip")
        XCTAssertThrowsError(try ZipArchive.write([.init(name: "../escape", payload: .bytes(Data([1])))], to: url))
        try ZipArchive.write([
            .init(name: "index.json", payload: .bytes(Data("{\"version\":2}".utf8))),
            .init(name: "清单.txt", payload: .bytes(Data("readable".utf8)))
        ], to: url)
        XCTAssertThrowsError(try vault.previewRestore(url)) { XCTAssertEqual($0 as? KeeperError, .version) }
        var bytes = try Data(contentsOf: url)
        bytes[40] ^= 1
        try bytes.write(to: url)
        XCTAssertThrowsError(try vault.previewRestore(url)) { XCTAssertEqual($0 as? KeeperError, .badPackage) }
        XCTAssertTrue(try vault.state().messages.isEmpty)
    }

    func testDefaultImportUsesLastPersonThenUniqueSuggestionThenFirstPerson() {
        let first = Person(name: "Dad")
        let second = Person(name: "Móm")
        let sameName = Person(name: "Mom")
        XCTAssertEqual(Library(people: [first, second], lastPerson: first.id).defaultImportPerson(suggestedName: "Mom"), first)
        XCTAssertEqual(Library(people: [first, second], lastPerson: UUID()).defaultImportPerson(suggestedName: "Mom"), second)
        XCTAssertEqual(Library(people: [first, second, sameName]).defaultImportPerson(suggestedName: "Mom"), first)
        XCTAssertNil(Library().defaultImportPerson(suggestedName: "Mom"))
    }

    func testMilestonesCountOnlyUniqueSavesAndLegacyProgressDecodes() throws {
        var state = ImportProgress()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(secondsFromGMT: 0)!
        state.saved(key: "first", at: now, zone: zone)
        XCTAssertEqual(state.milestone, 1)
        state.saved(key: "first", at: now.addingTimeInterval(86_400), zone: zone)
        XCTAssertEqual(state.total, 1)
        XCTAssertEqual(state.days.count, 1)
        for number in 2...10 { state.saved(key: "\(number)", at: now, zone: zone) }
        XCTAssertEqual(state.milestone, 10)
        XCTAssertNil(state.reviewDay(version: "1"))

        let legacy = Data(#"{"total":3,"days":["2023-11-14","2023-11-15"],"milestone":1,"known":[]}"#.utf8)
        var decoded = try JSONDecoder().decode(ImportProgress.self, from: legacy)
        XCTAssertNil(decoded.reviewDay(version: "1"))
        let third = now.addingTimeInterval(2 * 86_400)
        decoded.saved(key: "after-upgrade", at: third, zone: zone)
        XCTAssertEqual(decoded.reviewDay(version: "1"), ImportProgress.dayKey(third, zone: zone))
    }

    func testVaultClaimsReviewOnlyOnThirdSuccessfulImportDay() async throws {
        let vault = try makeVault()
        let first = try await AudioImport.prepare(fixture("Tone.mp3"))
        let second = try await AudioImport.prepare(fixture("Tone.wav"))
        let third = try await AudioImport.prepare(fixture("Tone.caf"))
        let sameDay = try await AudioImport.prepare(fixture("Sample.m4a"))
        let zone = TimeZone(secondsFromGMT: 0)!
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let day3 = day2.addingTimeInterval(86_400)
        let day4 = day3.addingTimeInterval(86_400)
        XCTAssertEqual(try vault.save(first, choice: .new("Mom"), note: "", date: nil, zone: nil,
                                      now: day1, zoneAtSave: zone), .saved)
        let mom = try XCTUnwrap(vault.state().lastPerson)
        let target = PersonChoice.existing(mom)
        XCTAssertEqual(try vault.save(sameDay, choice: target, note: "", date: nil, zone: nil,
                                      now: day1, zoneAtSave: zone), .saved)
        XCTAssertEqual(try vault.save(second, choice: target, note: "", date: nil, zone: nil,
                                      now: day2, zoneAtSave: zone), .saved)
        XCTAssertFalse(try vault.claimReview(version: "1", now: day2, zone: zone))
        XCTAssertEqual(try vault.save(first, choice: target, note: "", date: nil, zone: nil,
                                      now: day3, zoneAtSave: zone), .duplicate)
        XCTAssertEqual(try vault.save(first, choice: .new("Dad"), note: "", date: nil, zone: nil,
                                      now: day3, zoneAtSave: zone), .otherPerson("Mom"))
        XCTAssertFalse(try vault.claimReview(version: "1", now: day3, zone: zone))
        XCTAssertEqual(try vault.save(third, choice: target, note: "", date: nil, zone: nil,
                                      now: day3, zoneAtSave: zone), .saved)
        XCTAssertEqual(try vault.state().milestone, 1)
        XCTAssertFalse(try vault.claimReview(version: "1", now: day4, zone: zone))
        XCTAssertTrue(try vault.claimReview(version: "1", now: day3, zone: zone))
        try vault.releaseReview(version: "1")
        XCTAssertTrue(try vault.claimReview(version: "1", now: day3, zone: zone))
        XCTAssertFalse(try vault.claimReview(version: "1", now: day3, zone: zone))
    }

    @MainActor
    func testShareCardSizeAndQRCodeReadback() throws {
        let design = CardDesign(caption: "I kept 23 voice messages.", years: "2022–2026")
        let render = ImageRenderer(content: CardArt(design: design).frame(width: 360, height: 450))
        render.scale = 3
        let png = try XCTUnwrap(render.uiImage?.cgImage)
        XCTAssertEqual(png.width, 1080)
        XCTAssertEqual(png.height, 1350)
        let code = try XCTUnwrap(ShareCard.code(ShareCard.placeholderURL))
        let context = CIContext()
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: CIImage(cgImage: code)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(codes, [ShareCard.placeholderURL])
    }

    private func makeVault() throws -> Vault {
        try Vault(root: directory.appendingPathComponent(UUID().uuidString))
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }
}
