import Foundation
import XCTest
@testable import HermesNetworking

final class DewuPlaybackLogTests: XCTestCase {
    func testExtractsLivePhotoVideosFromPlaybackLog() throws {
        let log = """
        [MC][INFO] content id: 503313972, urls_size:2, urls: http://video-cdn-auth-multi.dewu.com/livephoto/mf/wz265_1080p_common_202411/6418b80a-532f-4f6e-9b1f-1e4837fe4dde/e_dur2956dur_b4c4f6a0a98452cd53f4f03eb1869737_iOS_w1080h1920.mp4?auth_key=1782805716-0e2042b90ddc4ac0ace102693391ade3-36479748-72c39d3ed4830de9db24a778f968efb2 http://video-cdn-auth-hw.dewu.com/livephoto/mf/wz265_1080p_common_202411/6418b80a-532f-4f6e-9b1f-1e4837fe4dde/e_dur2956dur_b4c4f6a0a98452cd53f4f03eb1869737_iOS_w1080h1920.mp4?auth_key=1782805716-020deb580ba04517abce07d3f8ca3523-36479748-d518ec35391a5db0a9c4d6b8178ebaa7
        """

        let urls = DewuPlaybackLogVideoExtractor.videoURLs(in: log)

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.host, "video-cdn-auth-multi.dewu.com")
        XCTAssertTrue(try XCTUnwrap(urls.first?.path).contains("/livephoto/"))
    }

    func testSearchesPlaybackLogsWhenDetailAPIHasNoLivePhotoVideo() {
        XCTAssertTrue(DewuPlaybackLogVideoExtractor.shouldSearchPlaybackLogs(
            didFetchAPIDetail: true,
            hasAPIMediaPairs: false,
            hasVideoURLs: false,
            isVideoPost: false,
            hasImageSources: true,
            hasShareVideoURLs: false
        ))
    }

    func testContinuesToVideoStageAfterStaticImageFailureWhenVideoIsPossible() {
        XCTAssertTrue(DewuDownloadRecoveryPolicy.shouldContinueAfterStaticImageFailure(canStillReachVideoStage: true))
        XCTAssertFalse(DewuDownloadRecoveryPolicy.shouldFailAfterStaticImageFailure(downloadedVideoCount: 1))
        XCTAssertTrue(DewuDownloadRecoveryPolicy.shouldFailAfterStaticImageFailure(downloadedVideoCount: 0))
    }
}
