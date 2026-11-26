import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()
    private let uiTimeout: TimeInterval = 15

    private enum Language: String, CaseIterable {
        case en, hans = "zh-Hans", hant = "zh-Hant"

        var locale: String {
            switch self {
            case .en: return "en_US"
            case .hans: return "zh_CN"
            case .hant: return "zh_TW"
            }
        }

        var demoMom: String { self == .en ? "Mom" : (self == .hans ? "妈妈" : "媽媽") }
        var birth: String { self == .en ? "Birthday song" : "生日歌" }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testStoreScreenshots() {
        for language in Language.allCases {
            launch(language, seed: true, args: ["-store-shot"])
            let prefix = "store-" + language.rawValue + "-"
            let mom = button(starting: "home.person.", label: language.demoMom)
            XCTAssertTrue(mom.waitForExistence(timeout: uiTimeout), "\(prefix)home: expected seeded person")
            screenshot(prefix + "01-home")
            tapVisible(mom)
            XCTAssertTrue(button("person.back").waitForExistence(timeout: uiTimeout),
                          "\(prefix)playback: expected person.back")
            tapVisible(button(starting: "message.play.", label: language.birth), in: personList)
            XCTAssertTrue(button("playback.toggle").waitForExistence(timeout: uiTimeout),
                          "\(prefix)playback: expected playback.toggle")
            screenshot(prefix + "02-playback")
            tapVisible(button("person.back"), direction: .down, in: personList)
            tapVisible(button("home.backup"))
            XCTAssertTrue(button("backup.export").waitForExistence(timeout: uiTimeout),
                          "\(prefix)backup: expected backup.export")
            screenshot(prefix + "04-backup")
            app.terminate()
            launch(language, reset: false, args: ["-store-shot", "-store-import"], ready: "import.save")
            screenshot(prefix + "03-import")
            app.terminate()
            launch(language, reset: false, args: ["-store-shot", "-store-family"], ready: "family.preview")
            screenshot(prefix + "05-family")
            app.terminate()
        }
    }

    func testDefaultAndChangedPersonImport() {
        launch(.en, seed: true, args: ["-fixture-picker"])
        openAudioFromHome()
        let save = button("import.save")
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save to Mom")
        tapVisible(save)
        waitForHomeStatus()
        openAudioFromHome()
        let saveToDad = button(starting: "import.saveTo.", label: "Save to Dad")
        tapVisible(saveToDad)
        waitForHomeStatus()
        openAudioFromHome()
        XCTAssertEqual(save.label, "Save to Dad")
        tapVisible(button("import.cancel"), direction: .down)
        let dad = button(starting: "home.person.", label: "Dad")
        tapVisible(dad, direction: .down)
        XCTAssertTrue(button(starting: "message.play.", label: "Sample.m4a").waitForExistence(timeout: uiTimeout))
    }

    func testFirstLaunchAndNewPersonShortcut() {
        launch(.en, args: ["-fixture-picker"])
        XCTAssertTrue(button("home.import").isHittable)
        XCTAssertFalse(button("guide.library").exists)
        tapVisible(button("home.guide"))
        tapVisible(button("guide.skip"))
        openAudioFromHome()
        saveNewPerson("Nora")
        tapVisible(button("home.importNew"))
        saveNewPerson("Alex")
        let alex = button(starting: "home.person.", label: "Alex")
        scrollTo(alex, direction: .down)
        XCTAssertTrue(alex.isHittable)
    }

    private func saveNewPerson(_ person: String) {
        let name = app.textFields["import.name"]
        focus(name)
        name.typeText(person)
        tapVisible(button("import.save"))
        waitForHomeStatus()
    }

    func testMilestonesAndNoReviewAfterTenImportsOnOneDay() {
        launch(.en)
        openSimulatedAudio()
        saveNewPerson("Nora")
        tapVisible(button("home.milestone"), direction: .down)
        tapVisible(button("card.share"))
        let cardReceipt = app.staticTexts["share.requested"]
        scrollTo(cardReceipt, in: app.scrollViews.firstMatch)
        XCTAssertTrue(cardReceipt.waitForExistence(timeout: uiTimeout))
        tapVisible(button("library.back"), direction: .down)
        for _ in 2...10 {
            openSimulatedAudio()
            tapVisible(button("import.save"))
            waitForHomeStatus()
        }
        scrollTo(button("home.milestone"), direction: .down)
        XCTAssertTrue(button("home.milestone").label.contains("10"))
        XCTAssertFalse(app.staticTexts["test.reviewRequested"].waitForExistence(timeout: uiTimeout))
    }

    func testPlaybackSearchAndShareExports() {
        launch(.en, seed: true, args: ["-share-export-test"])
        tapVisible(button(starting: "home.person.", label: "Mom"))
        XCTAssertTrue(button("person.back").waitForExistence(timeout: uiTimeout))
        let list = personList
        let original = button(starting: "message.play.", label: "Birthday song")
        tapVisible(original, in: list)
        let messageID = String(original.identifier.dropFirst("message.play.".count))
        XCTAssertTrue(button("playback.toggle").waitForExistence(timeout: uiTimeout))
        tapVisible(button("playback.loop"), direction: .down, in: list)
        tapVisible(button("playback.star"), direction: .down, in: list)
        tapVisible(button("playback.star"), direction: .down, in: list)
        let search = app.textFields["person.search"]
        focus(search, direction: .down, in: list)
        search.typeText("Birthday")
        XCTAssertEqual(search.value as? String, "Birthday")
        scrollSurface(list).swipeUp()
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                       object: app.keyboards.firstMatch)
        wait(for: [keyboardHidden], timeout: uiTimeout)
        scrollTo(original, in: list)
        XCTAssertTrue(original.waitForExistence(timeout: uiTimeout))

        let actions = button("message.more." + messageID)
        for (itemID, title, fileExtension) in [
            ("message.original", "Export original", "m4a"),
            ("message.family", "Send to family", "vkeep")
        ] {
            tapVisible(actions, in: list)
            let fallback = button("test.\(itemID).\(messageID)")
            tapExportMenuItem(itemID, title: title, fallback: fallback, in: list)
            waitForShareReceipt(fileExtension, in: list)
        }
        tapVisible(button("person.export"), direction: .down, in: list)
        waitForShareReceipt("zip", in: list)
    }

    func testIdleReviewOnThirdDistinctImportDayWithMilestoneStillVisible() {
        launch(.en, seed: true, environment: ["VK_UI_REVIEW_DAYS": "2000-1-1\n2000-1-2"])
        XCTAssertTrue(button("home.milestone").exists)
        openSimulatedAudio()
        tapVisible(button("import.cancel"), direction: .down)
        XCTAssertFalse(app.staticTexts["test.reviewRequested"].waitForExistence(timeout: uiTimeout))
        openSimulatedAudio()
        tapVisible(button("import.save"))
        waitForHomeStatus()
        XCTAssertTrue(app.staticTexts["test.reviewRequested"].waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(button("home.milestone").exists)
        app.terminate()
        launch(.en, reset: false)
        openSimulatedAudio()
        tapVisible(button("import.save"))
        waitForHomeStatus()
        XCTAssertFalse(app.staticTexts["test.reviewRequested"].waitForExistence(timeout: uiTimeout))
    }

    func testEditMessageNoteAndConfirmDeletion() {
        launch(.en, seed: true)
        tapVisible(button(starting: "home.person.", label: "Mom"))
        let original = button(starting: "message.play.", label: "Birthday song")
        let more = button(starting: "message.more.", label: nil)
        tapVisible(more, in: personList)
        tapMenuItem("message.edit", labelPrefix: "Edit note, date or person")
        let field = app.descendants(matching: .any).matching(identifier: "message.note").firstMatch
        focus(field, offset: CGVector(dx: 0.97, dy: 0.5))
        let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Birthday song".count + 2)
        field.typeText(clear + "A treasured recording")
        tapVisible(button("edit.save"))
        XCTAssertFalse(original.exists)
        let edited = button(starting: "message.play.", label: "A treasured recording")
        scrollTo(edited, in: personList)
        waitForHittable(edited)
        edited.swipeLeft()
        let delete = button("message.delete")
        let deleteAction = delete.exists && delete.isHittable ? delete : app.buttons["Delete"].firstMatch
        tapVisible(deleteAction, direction: nil)
        let confirm = app.alerts.firstMatch.buttons["Delete"]
        tapVisible(confirm, direction: nil)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: edited)
        wait(for: [gone], timeout: uiTimeout)
    }

    func testFamilyPreviewAndBackupReceiptAndRestore() {
        launch(.hant, seed: true, args: ["-fixture-picker"])
        tapVisible(button("test.family"))
        tapVisible(button("family.preview"))
        tapVisible(button("import.save"))
        waitForHomeStatus()

        tapVisible(button("home.backup"))
        tapVisible(button("backup.export"))
        let backupReceipt = app.staticTexts["share.requested"]
        scrollTo(backupReceipt, in: app.scrollViews.firstMatch)
        XCTAssertTrue(backupReceipt.waitForExistence(timeout: uiTimeout))
        let stamp = app.staticTexts["backup.stamp"]
        scrollTo(stamp, direction: .down)
        XCTAssertTrue(stamp.exists)
        let before = stamp.label
        tapVisible(button("test.backupCancel"))
        scrollTo(app.staticTexts["backup.status"], direction: .down)
        XCTAssertTrue(app.staticTexts["backup.status"].exists)
        scrollTo(stamp, direction: .down)
        XCTAssertEqual(stamp.label, before)
        tapVisible(button("test.backupConfirm"))
        scrollTo(stamp, direction: .down)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != %@", before), object: stamp)
        wait(for: [updated], timeout: uiTimeout)
        tapVisible(button("library.back"), direction: .down)
        tapVisible(button("home.restore"))
        tapVisible(button("restore.confirm"))
        waitForHomeStatus()
        XCTAssertTrue(app.staticTexts["home.status"].label.contains("1"))
    }

    func testLargeTextKeepsCoreActionsReachable() {
        launch(.hans, seed: true, args: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        for id in ["home.import", "home.restore"] {
            let action = button(id)
            scrollTo(action)
            XCTAssertTrue(action.isHittable)
            XCTAssertFalse(action.label.isEmpty)
        }
        let person = button(starting: "home.person.", label: Language.hans.demoMom)
        tapVisible(person, direction: .down)
        let message = button(starting: "message.play.", label: Language.hans.birth)
        tapVisible(message, in: personList)
        XCTAssertTrue(button("playback.toggle").waitForExistence(timeout: uiTimeout))
    }

    func testPaidDownloadHasNoPaywallOrExpirationRoute() {
        for flag in ["-paywall", "-expired"] {
            launch(.en, args: [flag])
            XCTAssertTrue(button("home.import").exists)
            XCTAssertFalse(button("paywall.purchase").exists)
            app.terminate()
        }
    }

    private func launch(_ language: Language, seed: Bool = false, reset: Bool = true, args: [String] = [],
                        ready: String = "home.import", environment: [String: String] = [:]) {
        app.launchEnvironment = environment
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))", "-AppleLocale", language.locale]
            + (reset ? ["-reset"] : []) + (seed ? ["-seed"] : []) + args
        app.launch()
        let diagnostic = "\(language.rawValue) \(args.joined(separator: " ")): expected \(ready)"
        if ready == "import.save" || ready == "family.preview" {
            waitForImportSheet(ready: ready, diagnostic: diagnostic)
        } else {
            XCTAssertTrue(button(ready).waitForExistence(timeout: uiTimeout), diagnostic)
        }
    }

    private func waitForImportSheet(ready: String, diagnostic: String) {
        let cancel = button("import.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: uiTimeout), "\(diagnostic), waiting for import.cancel")
        let form = app.scrollViews.containing(.button, identifier: "import.cancel").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: uiTimeout), "\(diagnostic), waiting for import form")
        let target = form.buttons[ready]
        if !target.exists {
            scrollTo(target, in: form)
        }
        XCTAssertTrue(target.waitForExistence(timeout: uiTimeout), diagnostic)
    }

    private func openSimulatedAudio() {
        tapVisible(button("test.import"))
        XCTAssertTrue(button("import.save").waitForExistence(timeout: uiTimeout))
    }

    private func openAudioFromHome() {
        tapVisible(button("home.import"))
        XCTAssertTrue(button("import.save").waitForExistence(timeout: uiTimeout))
    }

    private func waitForHomeStatus() {
        XCTAssertTrue(app.staticTexts["home.status"].waitForExistence(timeout: uiTimeout))
    }

    private var personList: XCUIElement {
        let collection = app.collectionViews.firstMatch
        return collection.exists ? collection : app.tables.firstMatch
    }

    private func button(_ id: String) -> XCUIElement { app.buttons[id] }

    private func button(starting prefix: String, label: String?) -> XCUIElement {
        let rule = label.map {
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, $0)
        } ?? NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return app.buttons.matching(rule).firstMatch
    }

    private func tapMenuItem(_ id: String, labelPrefix: String? = nil) {
        let identifier = NSPredicate(format: "identifier == %@", id)
        let predicate = labelPrefix.map { label -> NSPredicate in
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                identifier, NSPredicate(format: "label BEGINSWITH %@", label)
            ])
        } ?? identifier
        let items = app.buttons.matching(predicate)
        let appFrame = app.frame
        func visibleItem() -> XCUIElement? {
            let visible = items.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return $0.isEnabled && !frame.isEmpty && appFrame.contains(frame)
            }
            return visible.first(where: \.isHittable) ?? visible.first
        }
        let displayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            visibleItem() != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [displayed], timeout: uiTimeout) == .completed,
              let item = visibleItem() else {
            XCTFail("No visible menu item for \(id)")
            return
        }
        let frame = item.frame
        let center = CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
    }

    private func tapExportMenuItem(_ id: String, title: String, fallback: XCUIElement, in list: XCUIElement) {
        let byID = app.buttons[id].firstMatch
        let byTitle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        let menuItem = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", id, title)
        ).firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: uiTimeout), "Missing export menu item \(id)")

        func hittableItem() -> XCUIElement? {
            [byID, byTitle].first { $0.exists && $0.isEnabled && $0.isHittable }
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            hittableItem() != nil
        }, object: nil)
        let item = XCTWaiter.wait(for: [ready], timeout: uiTimeout) == .completed ? hittableItem() : nil
        if let item {
            item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        }

        var menuTapWorked = item != nil
        for attempt in 0..<4 {
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menuItem)
            if XCTWaiter.wait(for: [closed], timeout: attempt == 0 ? 5 : 3) == .completed { break }
            menuTapWorked = false
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        }
        XCTAssertFalse(menuItem.exists, "Export menu should be dismissed after attempting \(id)")
        if !menuTapWorked {
            tapVisible(fallback, in: list)
        }
    }

    private func waitForShareReceipt(_ fileExtension: String, in list: XCUIElement) {
        let receipt = app.descendants(matching: .any).matching(identifier: "share.requested").firstMatch
        scrollTo(receipt, direction: .down, in: list)
        XCTAssertTrue(receipt.waitForExistence(timeout: uiTimeout), "Missing share receipt for .\(fileExtension)")
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            receipt.exists && (receipt.value as? String) == fileExtension
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: uiTimeout), .completed,
                       "Expected share receipt for .\(fileExtension), got \(receipt.exists ? String(describing: receipt.value) : "no receipt")")
    }

    private enum Direction { case up, down }

    private func focus(_ field: XCUIElement, direction: Direction = .up, in container: XCUIElement? = nil,
                       offset: CGVector? = nil) {
        tapVisible(field, direction: direction, in: container, offset: offset)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiTimeout),
                      "Expected keyboard after tapping \(field)")
    }

    private func tapVisible(_ element: XCUIElement, direction: Direction? = .up, in container: XCUIElement? = nil,
                            offset: CGVector? = nil) {
        if let direction { scrollTo(element, direction: direction, in: container) }
        waitForHittable(element)
        if let offset {
            element.coordinate(withNormalizedOffset: offset).tap()
        } else {
            element.tap()
        }
    }

    private func waitForHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable && element.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: uiTimeout), .completed,
                       "Expected visible, enabled element: \(element)")
    }

    private func scrollSurface(_ container: XCUIElement?) -> XCUIElement {
        container.flatMap { $0.exists ? $0 : nil } ?? app
    }

    private func scrollTo(_ element: XCUIElement, direction: Direction = .up, in container: XCUIElement? = nil) {
        let surface = scrollSurface(container)
        for _ in 0..<6 {
            var swipe = direction
            if element.exists {
                if element.isHittable { return }
                let frame = element.frame
                let viewport = surface.frame
                if !frame.isEmpty && frame.midY < viewport.minY {
                    swipe = .down
                } else if !frame.isEmpty && frame.midY > viewport.maxY {
                    swipe = .up
                }
            }
            if swipe == .up { surface.swipeUp() } else { surface.swipeDown() }
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
