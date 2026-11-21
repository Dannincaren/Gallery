# Energy optimization in 1.1.0

This work keeps the established cursor resource types, animation timings and
immediate button/role-change paths. It does not add an energy-saving frame-rate
cap or change permissions.

## Implemented scope

1. **Active frame cache.** Prefer one affordable active animation over unrelated
   prewarming. The prepared-frame budget adapts from 32 MiB to a hard 48 MiB;
   the entry limit accommodates up to 240 distinct source frames plus spare
   entries. Oversized clips keep streaming within the hard byte bound. Cache
   lookup uses source image identity, final integer geometry/hotspot, backing
   resolution, smoothing and resource frame duration. Identical resources can
   be shared between roles; ownership and release-recovery indices remain
   independent. The byte bound covers this raster cache, not total process or
   WindowServer memory. Budget reductions are enforced on subsequent inserts.
2. **Confirmation scheduling.** Use one separate confirmation timer and at most
   one in-flight capture. Repeated misses for the same submission/seed retry at
   2/4/8/16 ms; new seeds, submissions and accepted button edges bypass that
   backoff. Successful confirmation cancels its timer. It does not pull scene
   polling, full rendering or watchdog work into that retry cadence. Mouse-up
   reconciliation remains active during pending confirmation. Mission Control
   and editor-corner paths, which do not perform recognition, do not poll for
   impossible acknowledgments; their existing animation timers remain active.
3. **Movement and raster reuse.** Keep every input sample for activity, role
   recognition and shake detection. Shake image updates use the existing frame
   timer rather than rendering for each movement event. Accepted button edges
   and identified role changes still render immediately. Scale values that
   produce identical displayed geometry reuse resources, with the previous
   scale quantization and pixel alignment preserved. Raster representations
   follow the connected screens' required backing scale.

## Game Mode deadlines (local 1.0.3.14)

The user confirmed that disabling macOS Game Mode while keeping Arknights
fullscreen restored cursor animation. A bounded, read-only timing comparison
then observed a roughly 97–100 ms extra delay on Foundation timers, versus
0.09 ms median on strict Dispatch timers (the game remained frontmost for all
77 foreground checks). A process-wide `latencyCritical` activity trial did
not remove the extra delay and is not part of the product.

Animation deadlines and image confirmations now use strict, **one-shot**
Dispatch sources. Relaxed watchdog deadlines retain utility priority and
up to 20 ms requested leeway. Signals enter the main run loop in common modes,
so AppKit import/export modal loops still receive them; rendering and role
state remain on the main actor. An earlier pending deadline is retained or
promoted to strict delivery, rather than postponed. Cancellation invalidates
already queued callbacks before they can change a restored cursor.

No extra repeating timer, spin loop, source-frame-rate increase, game setting
edit, process-priority setting or permission is introduced. The source frames,
frame cache, interaction ownership and existing confirmation backoff remain
unchanged. Strict timing applies to actual animation/confirmation deadlines;
idle static and paused checks remain coalescible.

In the user's fullscreen/Game Mode PRTS recording, strict animation timer
lateness was 0.16 ms median / 0.35 ms p95. Visible idle-update gaps returned
from 189 ms median to 95 ms (the source interval), and the user confirmed
normal playback. Relaxed checks still showed the system's roughly 100 ms
deferral, which is acceptable for those non-frame deadlines.

A separate timer-only microbenchmark used self-process CPU accounting after
warm-up: at 95 ms intervals, strict one-shot delivery used about 0.006% of one
CPU core; at 60 callbacks/s it used about 0.03%. Interrupt wakeups matched the
number of callbacks, with no free-running polling. These numbers exclude
Gallery's cursor rendering, WindowServer/GPU work and battery power. Accurate
timing also reduces opportunities to combine wakes; package-idle wake counts
varied in the isolated test. Restoring the intended animation rate naturally
does more rendering than the previous dropped-frame condition. No claim of
zero battery impact or a measured whole-system energy reduction is made.

See Apple's [strict timer flags](https://developer.apple.com/documentation/dispatch/dispatchsource/timerflags).

## System scene activity (local 1.0.3.18)

Space completion counts as movement: the current idle animation ends, the
normal role is presented, and idle starts again only after a fresh delay.
This event does not depend on whether a trackpad, keyboard shortcut or
third-party tool initiated the switch. Mission Control uses its system
entry/exit events and existing shell metadata fallback; idle stays suppressed
while it is open. Foreground application activation remains ordinary activity.
Held clicks keep their independent press/release ownership.

The native read-only observer registers only Mission Control entry/exit and
Space **completion** (1327/1328/1401). Workspace completion is the existing
public fallback. Duplicate completion reports restart the delay safely; queued
callbacks are invalidated on stop. The 1400 will-change event, inferred starts
from stale idle images, and the associated suppression/acknowledgement state
have been removed. A cancelled swipe with no completed Space change has no
promised early transition to normal; ordinary pointer/focus activity still
applies. The compositor may pause idle during the slide until completion.

After a bounded investigation, the user chose this behavior over the 1.0.3.17
trackpad-specific early detector. That detector, private framework loading,
contact callbacks/state and their unused tests/license were removed from the
product. The implementation remains archived in the local work snapshots, not
in the app. No keyboard monitoring, injected input, new permission, repeating
timer or higher polling frequency is added. Prior failed pause/resume, scale
refresh, independent publisher and overlay experiments remain excluded.

Read-only CLI notification comparisons received native Mission Control events
but no Space-change control event; they do not establish universal absence of
a Space-start API. Earlier bundled-app traces recorded many completed Space
changes without a begin event. No reliable general start path was established.
The diagnostic 20 Hz query was bounded and is **not** part of the product;
its managed-display animation flag never changed. Whole-system energy has not
been measured for this revision. Removing raw contact observation eliminates
that added processing rather than adding another wake source.

Unselected-resource tests cover short/long idle clips, completion without any
input events, ignored Space-start guesses, duplicate completion, a fresh idle
delay, Mission Control held open, click ownership and stop. A separate native
harness covers registration/restart, completion-only filtering and cancellation
of queued callbacks without driving the system UI or changing cursors. Physical
keyboard/third-party switching still needs visual verification in the local app.

## Broader native loop playback: experimental preview

### Local 1.0.3.13: held poses and rolling idle preparation

Long Normal clips with at most 24 visible changes per cycle, and changes at no
more than half their source ticks, use the source-clock paired-frame path.
For example, Angelina's 73-tick arrow contains only four distinct pictures;
its text cursor has five. A foreground cursor reselection can restart a
partial native strip without reporting that phase. Held-frame playback makes
such reselection harmless: the next different pose still follows the complete
source timeline. Duplicate source ticks retain their full original duration.
This rule applies to the clip's content, not to a theme name. Other existing
native-loop eligibility, Wait playback and press/release semantics stay intact.

Paired long-loop playback prepares up to three future **visible changes** on
the existing serial frame worker. This helps the cold first cycle and clips
too large to fit in the 48 MiB raster cache. Prepared frames use that same
cache, with no added timer, frame dropping or increased cache limit. Role,
motion, geometry and configuration changes cancel queued work; stop and
pass-through discard late results. The current cold frame remains synchronous
so worker scheduling cannot delay entry into an animation.

An unselected-resource check of local PRTS artwork (61 pt, 240 ticks / 228
different images, 280 playback observations) reduced main-thread raster builds
from 228 to one; cached raster bytes stayed 33,935,520. A separate 128 pt
fixture that cannot fit a whole cycle retained one cold main build across a
wrap while remaining below 48 MiB. Ten Angelina role categories retained
source order under irregular observation intervals without segmented native
submissions. These are preparation and timeline checks, not measurements of
physical display latency, fullscreen-game smoothness or whole-system energy.
The separate Game Mode deadline change above was subsequently confirmed in the fullscreen game.

The previously reserved broader-playback proposal entered local testing on
2026-11-17 and is included with the subsequent desktop fixes in 1.1.0.

Normal, idle and hold loops with 2–24 frames can play as one native resource.
Longer eligible normal and hold loops, up to the existing 240-frame source limit, use
consecutive 24-frame strips and hand over every 22 source frames. The two-frame overlap
provides scheduling room without dropping source frames or changing their
duration. Press/release and resize retain their existing path.

Raster preparation runs on one background queue, with at most two pending jobs.
The main thread registers and selects the resulting immutable resources. Short
loops need no per-frame deadline; long loops wake at strip boundaries. A cold,
late, failed or unsupported preparation keeps the paired-frame fallback instead
of replaying an expired strip. Role clocks and native resource ownership remain
independent. Previously selected strips retain compact recovery fingerprints
so a foreground app reselecting an older strip does not acknowledge a new one.

The 1.0.3.10 preview uses cached paired-frame playback for idle clips longer
than 24 frames. A foreground app can restart a native strip without exposing
its phase, making a segmented idle loop unsafe to hand over by source time
alone. This fallback preserves the source order but brings back frame wakes
for long idle clips; its energy cost must be compared on the desktop.
Recognition now checks every frame of a bounded strip rather than only its
first, middle and last frames. A regression fixture demonstrates that those
three samples could otherwise accept a strip with an incorrect middle order.
Fingerprints are prepared on the worker and observations shared by frame count
within each probe. The existing cache-entry limits remain, but full-strip
signatures use more memory than the former three-sample signatures. This is
a correctness tradeoff, not a claim of an additional energy saving.

The additional strip cache is bounded to 16 entries and 48 MiB of raster bytes,
with at most 64 compact recovery records. This is separate from the active-frame
cache above and is not a total process/WindowServer memory bound. Preparation
can cause a brief CPU/memory increase; it is not an unconditional energy saving.

Review segment seams, phase-preserving reentry, foreground cursor reselection,
early mouse-up, quick repeated clicks, Dock, Mission Control, Spaces and text
tracking in third-party apps. Private native registration behavior may differ
across macOS versions. The isolated preview has an optimization toggle for
comparison after stopping the theme. No energy-saving percentage is assumed.

## Verification

`bash Scripts/check.sh` covers geometry compatibility, cache budget bounds,
confirmation backoff and urgent-input behavior alongside existing checks.

`bash Scripts/energy-check.sh` compiles only library targets and a standalone
test executable. It does not build or package Gallery.app. Its graphics checks
allocate unselected connection-local slots, never global or visible cursors.
It checks a 240-frame loop over repeated passes, active-cache protection,
cross-role resource sharing without shared release indices/ownership, geometry,
backing-resolution and smoothing isolation, and movement coalescing with
immediate button/role-change handling in an unregistered runtime.

These checks do not measure whole-system battery energy or physical click-to-
display latency. Desktop comparison of CPU, wakeups, WindowServer and click
response remains separate from these controlled checks.

`bash Scripts/native-loop-check.sh` allocates only unselected connection-local
resources. It checks background-job/cache bounds, short-loop stability over
1,000 observations, long-loop frame order and wrap, independent role clocks,
stale-strip ownership/recovery, late fallback and stop-time invalidation.
Arrow, IBeam and Wait resources must remain equal before and after. This is
not a substitute for the user's visible animation review.

## Click preparation and window metadata (2026-11-18 preview)

Mouse-down no longer synchronously asks WindowServer for an uncached window's
owner to identify Dock clicks. Existing pointer events warm a bounded 64-window,
two-second cache on the scene worker (at most two pending window lookups). A
late Dock result only corrects the same live gesture; it cannot restart another
role's interaction. Button rendering starts before this asynchronous lookup.

For the current role, a serial worker prepares missing Press/Release rasters and
fingerprints, interleaving their frame indices. Already prepared head frames
remain available immediately. Prewarming adds no polling and stops on role,
geometry, renderer configuration or stop-time invalidation. It schedules at most
28 MiB of missing data per focus, inserts only within the existing cache budget
and does not evict active frames to make room. Cold fallback remains available.
No animation frames, timing or source files change.

The extended energy check verifies all 64 synthetic interaction frames are warm,
subsequent lookups perform zero main-thread raster builds, memory remains
bounded, and stopped workers cannot repopulate the cache. This is a preparation
test, not a measurement of physical click-to-display latency or battery life.

## Wait overlay and status display (2026-11-17, historical)

The forthcoming native-Wait preview bypasses this overlay and its busy observer;
it needs no software pointer-position updates or busy-detection timer. The
overlay remains an injected fallback for regression checks and earlier local
packages. Native-Wait testing and approximate restoration are documented in
WAIT-OVERLAY.md. The following measurements describe the earlier overlay only.

The system Wait role now has a separate, narrowly scoped overlay fallback;
see [WAIT-OVERLAY.md](WAIT-OVERLAY.md). This is separate from the native
idle/hold-loop experiment above. The ordinary cursor path does not acquire an
always-on follow window or another periodic timer. Only an active busy overlay
has a 250 ms recovery watchdog. Existing mouse events move its owned window
at the current display cadence, up to 120 times per second, with an immediate
leading update and one coalesced trailing update. Core Animation plays decoded
source frames. The samples below describe the earlier 60 Hz implementation.

An isolated 32-point, 72-frame/60-fps PRTS experiment used four-second samples
on this Mac. Approximate one-core CPU utilization:

| Test process stage | CPU |
| --- | ---: |
| Armed, no overlay | 0.04% |
| Synthetic 120 Hz input without an overlay | 0.45% |
| Animated overlay, stationary | 0.11% |
| Animated overlay moving via AppKit, including synthetic input | 9.17% |
| Animated overlay moving via the owned WindowServer window, including synthetic input | 2.37% |

Both movement paths were checked against the actual WindowServer window
coordinates. Initial placement and resize/reentry synchronize AppKit's cached
frame to prevent a later layout commit from undoing a direct move. Unavailable
private movement APIs use AppKit instead. No system cursor resources are
rewritten for these moves.

These short samples compare the overlay implementation, not Gallery's full
runtime or whole-system energy. They exclude WindowServer/GPU energy and do
not establish a battery-life improvement. The synthetic input generator's
cost is included in both moving samples.

Runtime status text remains available through its own publisher. A test of
1,000 distinct status changes produced 1,000 label notifications and zero
runtime root notifications; repeated identical text produced no update. This
removes editor/gallery invalidations from role and button-phase text changes
without adding a polling mechanism.
