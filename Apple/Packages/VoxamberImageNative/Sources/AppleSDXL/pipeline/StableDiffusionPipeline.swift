// Voxamber modification: retain only shared pipeline types/progress/helpers; remove SD1 pipeline.
// For licensing see accompanying LICENSE.md file.
// Copyright (C) 2022 Apple Inc. All Rights Reserved.

import Accelerate
import CoreGraphics
import CoreML
import Foundation
import NaturalLanguage

/// Schedulers compatible with StableDiffusionPipeline
public enum StableDiffusionScheduler {
    /// Scheduler that uses a pseudo-linear multi-step (PLMS) method
    case pndmScheduler
    /// Scheduler that uses a second order DPM-Solver++ algorithm
    case dpmSolverMultistepScheduler
    /// Scheduler for rectified flow based multimodal diffusion transformer models
    case discreteFlowScheduler
}

/// RNG compatible with StableDiffusionPipeline
public enum StableDiffusionRNG {
    /// RNG that matches numpy implementation
    case numpyRNG
    /// RNG that matches PyTorch CPU implementation.
    case torchRNG
    /// RNG that matches PyTorch CUDA implementation.
    case nvidiaRNG
}

public enum PipelineError: String, Swift.Error {
    case missingUnetInputs
    case startingImageProvidedWithoutEncoder
    case startingText2ImgWithoutTextEncoder
    case unsupportedOSVersion
    case errorCreatingPreview
}

@available(iOS 16.2, macOS 13.1, *)
public protocol StableDiffusionPipelineProtocol: ResourceManaging {
    var canSafetyCheck: Bool { get }

    func generateImages(
        configuration config: PipelineConfiguration,
        progressHandler: (PipelineProgress) -> Bool
    ) throws -> [CGImage?]

    func decodeToImages(
        _ latents: [MLShapedArray<Float32>],
        configuration config: PipelineConfiguration
    ) throws -> [CGImage?]
}

@available(iOS 16.2, macOS 13.1, *)
public extension StableDiffusionPipelineProtocol {
    var canSafetyCheck: Bool { false }
}

/// Sampling progress details
@available(iOS 16.2, macOS 13.1, *)
public struct PipelineProgress {
    public let pipeline: StableDiffusionPipelineProtocol
    public let prompt: String
    public let step: Int
    public let stepCount: Int
    public let currentLatentSamples: [MLShapedArray<Float32>]
    public let configuration: PipelineConfiguration
    public var isSafetyEnabled: Bool {
        pipeline.canSafetyCheck && !configuration.disableSafety
    }
    public var currentImages: [CGImage?] {
        try! pipeline.decodeToImages(currentLatentSamples, configuration: configuration)
    }
}

// Helper functions

@available(iOS 16.2, macOS 13.1, *)
extension StableDiffusionPipelineProtocol {
    internal func randomSource(from rng: StableDiffusionRNG, seed: UInt32) -> RandomSource {
        switch rng {
        case .numpyRNG:
            return NumPyRandomSource(seed: seed)
        case .torchRNG:
            return TorchRandomSource(seed: seed)
        case .nvidiaRNG:
            return NvRandomSource(seed: seed)
        }
    }

    func toHiddenStates(_ embedding: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        // Unoptimized manual transpose [0, 2, None, 1]
        // e.g. From [2, 77, 768] to [2, 768, 1, 77]
        let fromShape = embedding.shape
        let stateShape = [fromShape[0],fromShape[2], 1, fromShape[1]]
        var states = MLShapedArray<Float32>(repeating: 0.0, shape: stateShape)
        for i0 in 0..<fromShape[0] {
            for i1 in 0..<fromShape[1] {
                for i2 in 0..<fromShape[2] {
                    states[scalarAt:i0,i2,0,i1] = embedding[scalarAt:i0, i1, i2]
                }
            }
        }
        return states
    }

    func performGuidance(_ noise: [MLShapedArray<Float32>], _ guidanceScale: Float) -> [MLShapedArray<Float32>] {
        noise.map { performGuidance($0, guidanceScale) }
    }

    func performGuidance(_ noise: MLShapedArray<Float32>, _ guidanceScale: Float) -> MLShapedArray<Float32> {
        var shape = noise.shape
        shape[0] = 1
        return MLShapedArray<Float>(unsafeUninitializedShape: shape) { result, _ in
            noise.withUnsafeShapedBufferPointer { scalars, _, strides in
                for i in 0 ..< result.count {
                    // unconditioned + guidance*(text - unconditioned)
                    result.initializeElement(
                        at: i,
                        to: scalars[i] + guidanceScale * (scalars[strides[0] + i] - scalars[i])
                    )
                }
            }
        }
    }
}
