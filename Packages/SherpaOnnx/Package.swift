// swift-tools-version: 5.9

import PackageDescription

let version = "1.13.2"
let checksumSherpa = "0017147fda683ce99f9390b43825c529966ad29b40ac67e37a43f2ba61d5264d"
let checksumOrt = "8c9db6bff51a7282a7b3ad08b9e87a88b41f03e02bf8e7dbbd53c6a66df75512"

let package = Package(
    name: "SherpaOnnx",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SherpaOnnx",
            targets: ["SherpaOnnx"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/\(version)/sherpa-onnx.xcframework.zip",
            checksum: checksumSherpa
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/\(version)/onnxruntime.xcframework.zip",
            checksum: checksumOrt
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            path: "Sources/SherpaOnnx",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
