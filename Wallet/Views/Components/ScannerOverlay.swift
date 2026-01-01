import SwiftUI
@preconcurrency import Vision

struct CardOverlay: View {
    let observation: VNRectangleObservation
    let size: CGSize
    let progress: CGFloat

    var body: some View {
        ZStack {
            // Corner brackets
            CardCorners(observation: observation, size: size)
                .stroke(
                    progress > 0.5 ? Color.green : Color.white,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

            // Progress ring in center
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .position(
                        x: size.width * (observation.boundingBox.midX),
                        y: size.height * (1 - observation.boundingBox.midY)
                    )
            }
        }
    }
}

struct CardCorners: Shape {
    let observation: VNRectangleObservation
    let size: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let cornerLength: CGFloat = 30

        let topLeft = CGPoint(
            x: observation.topLeft.x * size.width,
            y: (1 - observation.topLeft.y) * size.height
        )
        let topRight = CGPoint(
            x: observation.topRight.x * size.width,
            y: (1 - observation.topRight.y) * size.height
        )
        let bottomRight = CGPoint(
            x: observation.bottomRight.x * size.width,
            y: (1 - observation.bottomRight.y) * size.height
        )
        let bottomLeft = CGPoint(
            x: observation.bottomLeft.x * size.width,
            y: (1 - observation.bottomLeft.y) * size.height
        )

        // Top-left corner
        path.move(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerLength))
        path.addLine(to: topLeft)
        path.addLine(to: CGPoint(x: topLeft.x + cornerLength, y: topLeft.y))

        // Top-right corner
        path.move(to: CGPoint(x: topRight.x - cornerLength, y: topRight.y))
        path.addLine(to: topRight)
        path.addLine(to: CGPoint(x: topRight.x, y: topRight.y + cornerLength))

        // Bottom-right corner
        path.move(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerLength))
        path.addLine(to: bottomRight)
        path.addLine(to: CGPoint(x: bottomRight.x - cornerLength, y: bottomRight.y))

        // Bottom-left corner
        path.move(to: CGPoint(x: bottomLeft.x + cornerLength, y: bottomLeft.y))
        path.addLine(to: bottomLeft)
        path.addLine(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerLength))

        return path
    }
}
