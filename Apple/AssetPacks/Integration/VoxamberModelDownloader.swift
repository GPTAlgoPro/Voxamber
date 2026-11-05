import BackgroundAssets
import ExtensionFoundation
import StoreKit

// Reference source for an iOS 26+ ExtensionKit downloader target. This file is
// outside the main app's source tree and never enters the model asset payload.
@main
struct VoxamberModelDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        assetPack.id == "Voxamber-Qwen35-4B-INT4"
    }
}
