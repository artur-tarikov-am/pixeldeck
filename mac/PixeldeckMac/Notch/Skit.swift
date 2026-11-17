import Foundation

/// A short scene the character plays on the left wing as it leaves for the notch or comes back out.
struct Skit {
    /// Where the character is. Across: 0 at its place on the wing, 1 out of sight behind the notch.
    /// Up: 1 out of sight above the top of the screen, -1 out of sight below the wing.
    struct Spot {
        var across: Double
        var up = 0.0

        static let place = Spot(across: 0)
        static let behindNotch = Spot(across: 1)
        /// Out from behind the notch as far as one eye.
        static let peeking = Spot(across: 0.7)
        /// Close to the outer end of the wing.
        static let wingEnd = Spot(across: -0.25)
    }

    enum Pace {
        case even
        case speedingUp
        case slowingDown

        /// How far along the way the character is once `share` of the act has passed.
        func distance(_ share: Double) -> Double {
            switch self {
            case .even: share
            case .speedingUp: share * share
            case .slowingDown: 1 - (1 - share) * (1 - share)
            }
        }
    }

    struct Act {
        /// Nil while the character waits out of sight.
        var sprite: String?
        var seconds: TimeInterval
        /// Where the act leaves the character; nil keeps it where the act found it.
        var to: Spot?
        var pace = Pace.even
        /// Cells the character jumps up on the way.
        var hop = 0
        var isFlipped = false

        /// The wings unfold meanwhile.
        static let outOfSight = Act(sprite: nil, seconds: 0.4)
    }

    /// The left wing, in cells of the closed notch.
    struct Wing {
        /// The top left corner of the character at its place.
        var x: Int
        var y: Int
        /// The notch begins here; the character is behind it once its left edge gets here.
        var notchX: Int
        var height: Int
        var characterSide: Int

        func cell(of spot: Spot) -> (x: Int, y: Int) {
            let reach = spot.up > 0 ? y + characterSide : height - y
            return (
                x + Int((Double(notchX - x) * spot.across).rounded()),
                y - Int((Double(reach) * spot.up).rounded())
            )
        }
    }

    private struct Step: Timed {
        let act: Act
        let from: Spot

        var seconds: TimeInterval { act.seconds }

        func spot(after elapsed: TimeInterval) -> Spot {
            let to = act.to ?? from
            let distance = act.pace.distance(elapsed / seconds)
            return Spot(
                across: from.across + (to.across - from.across) * distance,
                up: from.up + (to.up - from.up) * distance
            )
        }
    }

    private let steps: [Step]
    private let end: Spot
    let duration: TimeInterval

    /// Each act starts where the one before left the character.
    init(from start: Spot, _ acts: [Act]) {
        var steps: [Step] = []
        var spot = start
        for act in acts {
            steps.append(Step(act: act, from: spot))
            spot = act.to ?? spot
        }
        self.steps = steps
        end = spot
        duration = steps.duration
    }

    func spot(at elapsed: TimeInterval) -> Spot {
        guard let (step, elapsed) = steps.act(at: elapsed) else { return end }
        return step.spot(after: elapsed)
    }

    func draw(at elapsed: TimeInterval, on wing: Wing, into buffer: inout Framebuffer) {
        guard
            let (step, elapsed) = steps.act(at: elapsed),
            let sprite = step.act.sprite.flatMap(SpriteLibrary.named)
        else { return }
        let cell = wing.cell(of: step.spot(after: elapsed))
        let hop = Int((Double(step.act.hop) * sin(elapsed / step.seconds * .pi)).rounded())
        sprite.draw(at: elapsed, x: cell.x, y: cell.y - hop, flipped: step.act.isFlipped, into: &buffer)
    }
}

extension Skit {
    static let departures: [Skit] = [
        // Looks around to check nobody is watching and moonwalks into the notch.
        Skit(from: .place, [
            Act(sprite: "look", seconds: 0.8),
            Act(sprite: "moonwalk", seconds: 2.2, to: .behindNotch),
        ]),
        // Spins its antenna up and flies off over the top of the screen.
        Skit(from: .place, [
            Act(sprite: "rotor", seconds: 0.7),
            Act(sprite: "rotor", seconds: 1.3, to: Spot(across: 0.35, up: 1), pace: .speedingUp),
        ]),
        // Waves goodbye and vanishes in a puff of smoke.
        Skit(from: .place, [
            Act(sprite: "bye", seconds: 1),
            Act(sprite: "poof", seconds: 0.6),
        ]),
        // Dozes off, curls up and rolls into the notch.
        Skit(from: .place, [
            Act(sprite: "bored", seconds: 1),
            Act(sprite: "sleep", seconds: 1.2),
            Act(sprite: "ball", seconds: 1.4, to: .behindNotch, pace: .speedingUp),
        ]),
        // Walks into the notch, then peeks out once more to see whether anyone noticed.
        Skit(from: .place, [
            Act(sprite: "walk", seconds: 1.4, to: .behindNotch),
            Act(sprite: nil, seconds: 0.7),
            Act(sprite: "peek", seconds: 0.2, to: .peeking),
            Act(sprite: "peek", seconds: 1),
            Act(sprite: "peek", seconds: 0.15, to: .behindNotch),
        ]),
        // Steps off the edge, pedals in the air for a moment and drops out of sight.
        Skit(from: .place, [
            Act(sprite: "walk", seconds: 0.6, to: Spot(across: 0.25)),
            Act(sprite: "hang", seconds: 0.8),
            Act(sprite: "hang", seconds: 0.35, to: Spot(across: 0.25, up: -1), pace: .speedingUp),
        ]),
        // Backs up for a run-up, paws the ground and dives into the notch.
        Skit(from: .place, [
            Act(sprite: "walk", seconds: 0.5, to: .wingEnd),
            Act(sprite: "windup", seconds: 0.6),
            Act(sprite: "dash", seconds: 0.3, to: .behindNotch, pace: .speedingUp, hop: 3),
        ]),
    ]

    static let arrivals: [Skit] = [
        // Peeks out of the notch, spots that something is up and hops out.
        Skit(from: .behindNotch, [
            .outOfSight,
            Act(sprite: "peek", seconds: 0.25, to: .peeking),
            Act(sprite: "peek", seconds: 0.9),
            Act(sprite: "alert", seconds: 0.35),
            Act(sprite: "leap", seconds: 0.35, to: .place, hop: 4),
        ]),
        // Drops from above the screen, goes flat and sees stars.
        Skit(from: Spot(across: 0, up: 1), [
            .outOfSight,
            Act(sprite: "fall", seconds: 0.45, to: .place, pace: .speedingUp),
            Act(sprite: "splat", seconds: 0.35),
            Act(sprite: "dizzy", seconds: 1),
        ]),
        // Lands from above on its spinning antenna.
        Skit(from: Spot(across: 0.35, up: 1), [
            .outOfSight,
            Act(sprite: "rotor", seconds: 1.3, to: .place, pace: .slowingDown),
            Act(sprite: "rotor", seconds: 0.4),
        ]),
        // Rolls out curled up and unrolls with a cheer.
        Skit(from: .behindNotch, [
            .outOfSight,
            Act(sprite: "ball", seconds: 0.8, to: .place, pace: .slowingDown, isFlipped: true),
            Act(sprite: "done", seconds: 0.8),
        ]),
        // Shoots out of the notch too fast, overshoots, reels and walks back.
        Skit(from: .behindNotch, [
            .outOfSight,
            Act(sprite: "dash", seconds: 0.2, to: .wingEnd, isFlipped: true),
            Act(sprite: "dizzy", seconds: 0.9),
            Act(sprite: "walk", seconds: 0.35, to: .place),
        ]),
        // Runs in late and catches its breath.
        Skit(from: .behindNotch, [
            .outOfSight,
            Act(sprite: "run", seconds: 0.45, to: .place),
            Act(sprite: "pant", seconds: 1.2),
        ]),
    ]

    /// Something happened while the character was on its way out: it rushes back.
    static func startled(from spot: Spot) -> Skit {
        Skit(from: spot, [Act(sprite: "alert", seconds: 0.4, to: .place)])
    }
}
