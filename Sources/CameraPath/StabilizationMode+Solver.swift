import PipelineCore

extension StabilizationMode {
    /// The solver that produces this mode's camera path.
    public var solver: any CameraPathSolver {
        switch self {
        case .off: return OriginalPathSolver()
        case .smooth: return SmoothedPathSolver()
        case .locked: return WarpToReferenceSolver()
        }
    }
}
