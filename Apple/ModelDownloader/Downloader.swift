import BackgroundAssets
import ExtensionFoundation
import StoreKit

@main
struct VoxamberModelDownloader: StoreDownloaderExtension {
    private static let allowedPackIDs: Set<String> = [
        "Voxamber-Qwen35-4B-INT4",
        "Voxamber-Qwen35-08B-INT4",
        "Voxamber-SDXL-CoreML",
        "Voxamber-Hunyuan21-Shape-Q4-30B93"
    ]
    func shouldDownload(_ assetPack:AssetPack)->Bool {
        Self.allowedPackIDs.contains(assetPack.id)
    }
}
