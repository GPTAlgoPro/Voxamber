import BackgroundAssets
import ExtensionFoundation
import StoreKit

@main
struct VoxamberModelDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack:AssetPack)->Bool {
        assetPack.id == "Voxamber-Qwen35-4B-INT4"
    }
}
