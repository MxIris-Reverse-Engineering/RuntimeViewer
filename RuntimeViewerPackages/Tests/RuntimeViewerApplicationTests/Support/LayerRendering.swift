import AppKit
import Metal
import QuartzCore
import Testing

/// Renders `layer` with Core Animation's own renderer over a flat grey of `backdropWhite` (0 to
/// 255) and returns the sRGB red, green and blue at `point`, 0 to 255.
///
/// `CARenderer` carries out compositing filters, and keeps a layer's sublayers blending among
/// themselves unless the layer lets them through to what is behind it, as the window server does;
/// drawing a layer into a bitmap context (`render(in:)`) does neither. For the call, the layer goes
/// into a root layer `side` points square, centred in it whatever its anchor point (a view's layer
/// has its anchor at the corner); `point` is in the root's coordinates, with y pointing up. The layer
/// must not be in a layer tree already.
@MainActor
func renderedPixel(of layer: CALayer, overWhite backdropWhite: Int, side: Int = 40, at point: CGPoint, sourceLocation: SourceLocation = #_sourceLocation) throws -> [Double] {
    try #require(layer.superlayer == nil, "the layer is in a layer tree already", sourceLocation: sourceLocation)
    let device = try #require(MTLCreateSystemDefaultDevice(), sourceLocation: sourceLocation)
    let commandQueue = try #require(device.makeCommandQueue(), sourceLocation: sourceLocation)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .managed
    let texture = try #require(device.makeTexture(descriptor: descriptor), sourceLocation: sourceLocation)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB), sourceLocation: sourceLocation)
    // The renderer draws on this queue, so the copy back below runs after it.
    let renderer = CARenderer(mtlTexture: texture, options: [
        kCARendererColorSpace as String: colorSpace,
        kCARendererMetalCommandQueue as String: commandQueue,
    ])

    let previousFrame = layer.frame
    let backdropComponent = CGFloat(backdropWhite) / 255
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: side, height: side)
    root.backgroundColor = CGColor(srgbRed: backdropComponent, green: backdropComponent, blue: backdropComponent, alpha: 1)
    root.addSublayer(layer)
    let layerSize = layer.bounds.size
    layer.frame = CGRect(
        x: (CGFloat(side) - layerSize.width) / 2,
        y: (CGFloat(side) - layerSize.height) / 2,
        width: layerSize.width,
        height: layerSize.height
    )
    // Given to the renderer before the commit, or the commit does not reach it and nothing is drawn.
    renderer.layer = root
    renderer.bounds = root.bounds
    CATransaction.commit()
    CATransaction.flush()
    defer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        layer.frame = previousFrame
        CATransaction.commit()
    }

    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(root.bounds)
    renderer.render()
    renderer.endFrame()

    let commandBuffer = try #require(commandQueue.makeCommandBuffer(), sourceLocation: sourceLocation)
    let blitEncoder = try #require(commandBuffer.makeBlitCommandEncoder(), sourceLocation: sourceLocation)
    blitEncoder.synchronize(resource: texture)
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var pixel = [UInt8](repeating: 0, count: 4)
    // The texture's rows run from the top.
    let row = side - 1 - Int(point.y)
    texture.getBytes(&pixel, bytesPerRow: side * 4, from: MTLRegionMake2D(Int(point.x), row, 1, 1), mipmapLevel: 0)
    // Blue, green, red, alpha.
    return [Double(pixel[2]), Double(pixel[1]), Double(pixel[0])]
}
