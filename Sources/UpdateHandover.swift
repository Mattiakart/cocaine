// The hand-over point between the in-app updater and the crash-recovery lease.
//
// Contract (for whoever owns the lease): the updater calls `prepareForUpdateHandover()` on the main thread right after the
// new app has been swapped into place and verified, and right before it starts the relaunch helper and quits with
// NSApp.terminate. The lease must SURVIVE this: the quit that follows is not a crash and not a user "turn off for good",
// and the new version, launched by the helper within seconds, must find and honour the lease (so whatever the lease
// protects is restored or kept, never lost or applied twice). It must return quickly (no UI, no network) and never throw.
// If the swap is rolled back before this point, it is not called.

import Foundation

func prepareForUpdateHandover() {
    // Intentionally empty: implemented by the crash-recovery work.
}
