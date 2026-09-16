enum DewuDownloadRecoveryPolicy {
    static func shouldContinueAfterStaticImageFailure(canStillReachVideoStage: Bool) -> Bool {
        canStillReachVideoStage
    }

    static func shouldFailAfterStaticImageFailure(downloadedVideoCount: Int) -> Bool {
        downloadedVideoCount == 0
    }
}
