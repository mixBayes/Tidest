import Foundation
import XCTest
@testable import tidest

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionWaitsForConfirmationThenOpensExactDownloadURL() async throws {
        let downloadURL = "https://example.com/Tidest-2.0.10.dmg?source=app"
        var openedURLs: [URL] = []
        let checker = UpdateChecker(currentVersion: "2.0.9", fetch: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://tidest.app/api/update")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 15)
            return try self.response(version: "2.0.10", downloadURL: downloadURL)
        }, openDownload: { url in
            openedURLs.append(url)
            return true
        })

        await checker.checkForUpdates()

        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.10"))
        XCTAssertTrue(openedURLs.isEmpty)

        checker.downloadUpdate()

        XCTAssertEqual(checker.state, .downloadOpened(version: "2.0.10"))
        XCTAssertEqual(openedURLs.map(\.absoluteString), [downloadURL])
    }

    func testNumericVersionComparisonOnlyOffersNewerVersions() async throws {
        let cases: [(installed: String, latest: String, shouldDownload: Bool)] = [
            ("2.0.1", "2.0.1", false),
            ("2.0.1", "2.0.0", false),
            ("2.0.10", "2.0.9", false),
            ("2.0.9", "2.0.10", true),
            ("2.9.9", "2.10.0", true),
            ("2.10.0", "2.9.9", false),
            ("2.99.99", "3.0.0", true),
            ("3.0.0", "2.99.99", false),
            ("2.0", "2.0.0", false),
            ("2.0.0", "2.0", false),
            ("2.0", "2.0.1", true),
            ("2.00.01", "2.0.1", false)
        ]
        for test in cases {
            var downloads = 0
            let checker = UpdateChecker(currentVersion: test.installed, fetch: { _ in
                try self.response(version: test.latest)
            }, openDownload: { _ in
                downloads += 1
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(downloads, 0, "Checking must never download")
            XCTAssertEqual(checker.state, test.shouldDownload ? .updateAvailable(version: test.latest) : .upToDate)
            checker.downloadUpdate()
            XCTAssertEqual(downloads, test.shouldDownload ? 1 : 0, "\(test.installed) → \(test.latest)")
        }
    }

    func testHTTPFailuresAndInvalidJSONDoNotOpenDownloads() async throws {
        let validData = try JSONSerialization.data(withJSONObject: ["version": "2.0.2", "download_url": "https://example.com/update.dmg"])
        let cases: [(status: Int, data: Data)] = [
            (404, validData),
            (500, validData),
            (204, Data()),
            (200, Data("<html>Not JSON</html>".utf8)),
            (200, Data(#"{"version":"2.0.2"}"#.utf8)),
            (200, Data(#"{"version":2,"download_url":"https://example.com/update.dmg"}"#.utf8))
        ]
        for test in cases {
            let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { request in
                (test.data, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: test.status, httpVersion: nil, headerFields: nil)))
            }, openDownload: { _ in
                XCTFail("A failed check must not open a download")
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(checker.state, .checkFailed)
        }
    }

    func testMalformedVersionsDoNotTriggerDownloads() async throws {
        for version in ["", "2..1", ".2.1", "2.1.", "v2.0.2", "2.0.2-beta", "-2.0.2", " 2.0.2", "999999999999999999999999.0"] {
            let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
                try self.response(version: version)
            }, openDownload: { _ in
                XCTFail("An invalid version must not open a download")
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(checker.state, .checkFailed, version)
        }
    }

    func testMissingOrInvalidInstalledVersionDoesNotRequestAnUpdate() async {
        for version: String? in [nil, "", "invalid"] {
            let checker = UpdateChecker(currentVersion: version, fetch: { _ in
                XCTFail("The installed version must be known before checking")
                throw URLError(.badURL)
            }, openDownload: { _ in
                XCTFail("An invalid installed version must not open a download")
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(checker.state, .checkFailed)
        }
    }

    func testDownloadLinkMustBeAnAbsoluteWebURL() async throws {
        for url in ["", "/Tidest.dmg", "file:///tmp/Tidest.dmg", "javascript:alert(1)", "tidest://update", "https://"] {
            let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
                try self.response(version: "2.0.2", downloadURL: url)
            }, openDownload: { _ in
                XCTFail("An invalid download URL must not be opened")
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(checker.state, .checkFailed, url)
        }
    }

    func testTimeoutAndOfflineErrorsFinishTheCheck() async {
        for code: URLError.Code in [.timedOut, .notConnectedToInternet] {
            let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
                throw URLError(code)
            }, openDownload: { _ in
                XCTFail("A failed request must not open a download")
                return true
            })

            await checker.checkForUpdates()

            XCTAssertEqual(checker.state, .checkFailed)
        }
    }

    func testFailedCheckCanBeRetried() async throws {
        var requests = 0
        var downloads = 0
        let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            return try self.response(version: "2.0.2")
        }, openDownload: { _ in
            downloads += 1
            return true
        })

        await checker.checkForUpdates()
        XCTAssertEqual(checker.state, .checkFailed)
        await checker.checkForUpdates()

        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.2"))
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(downloads, 0)
        checker.downloadUpdate()
        XCTAssertEqual(downloads, 1)
    }

    func testBrowserOpenFailureIsReportedSeparately() async throws {
        let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
            try self.response(version: "2.0.2")
        }, openDownload: { _ in false })

        await checker.checkForUpdates()

        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.2"))
        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .downloadFailed(version: "2.0.2"))
    }

    func testRepeatedClickWhileCheckingDoesNotStartAnotherRequestOrDownload() async throws {
        let requestStarted = expectation(description: "Update request started")
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var requests = 0
        var downloads = 0
        let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation {
                continuation = $0
                requestStarted.fulfill()
            }
        }, openDownload: { _ in
            downloads += 1
            return true
        })
        let firstCheck = Task { await checker.checkForUpdates() }
        await fulfillment(of: [requestStarted], timeout: 2)
        XCTAssertEqual(checker.state, .checking)

        await checker.checkForUpdates()
        checker.downloadUpdate()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(downloads, 0)
        continuation?.resume(returning: try response(version: "2.0.2"))
        await firstCheck.value

        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.2"))
        XCTAssertEqual(downloads, 0)
        checker.downloadUpdate()
        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .downloadOpened(version: "2.0.2"))
        XCTAssertEqual(downloads, 1)
    }

    func testFailedRecheckDiscardsThePreviousDownload() async throws {
        var requests = 0
        let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
            requests += 1
            if requests == 2 { throw URLError(.notConnectedToInternet) }
            return try self.response(version: "2.0.2")
        }, openDownload: { _ in
            XCTFail("A failed recheck must not retain an old download")
            return true
        })

        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .idle)
        await checker.checkForUpdates()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.2"))
        await checker.checkForUpdates()
        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .checkFailed)
    }

    func testFailedDownloadCanBeRetriedWithoutCheckingAgain() async throws {
        var requests = 0
        var openedURLs: [URL] = []
        let checker = UpdateChecker(currentVersion: "2.0.1", fetch: { _ in
            requests += 1
            return try self.response(version: "2.0.2")
        }, openDownload: { url in
            openedURLs.append(url)
            return openedURLs.count == 2
        })

        await checker.checkForUpdates()
        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .downloadFailed(version: "2.0.2"))
        checker.downloadUpdate()
        XCTAssertEqual(checker.state, .downloadOpened(version: "2.0.2"))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(openedURLs.map(\.absoluteString), Array(repeating: "https://example.com/Tidest.dmg", count: 2))
    }

    private func response(version: String, downloadURL: String = "https://example.com/Tidest.dmg") throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "download_url": downloadURL])
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://tidest.app/api/update")!, statusCode: 200,
                                                   httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}
