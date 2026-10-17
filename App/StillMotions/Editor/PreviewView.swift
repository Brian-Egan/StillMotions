import SwiftUI
import StillMotionsPipeline

/// Plays the editor's plan, looping forever.
///
/// A `TimelineView` ticks once per plan step (1/fps), and each tick shows the step for the time
/// elapsed since playback (re)started, so playback is driven by the clock and never drifts. The
/// view is rebuilt when the frame rate changes (its tick interval changes) and its start time
/// resets when the plan changes, so a mode or rate switch is picked up on the next tick.
struct PreviewView: View {
    let model: EditorModel

    var body: some View {
        let plan = model.plan
        TimelineView(.periodic(from: model.playbackStart, by: max(plan.stepDuration, 0.01))) { timeline in
            let elapsed = timeline.date.timeIntervalSince(model.playbackStart)
            ZStack {
                Color.black
                if let step = plan.step(atElapsed: elapsed), let image = model.image(for: step) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onAppear { model.firstFrameShown() }
                }
            }
        }
        .id(plan.frameRate) // a new tick interval needs a new timeline
        .accessibilityIdentifier("previewImage")
        .accessibilityLabel("Stabilized preview")
    }
}
